#!/usr/bin/env python3
"""TrackStat receipt API and dashboard server.

Standard-library only: Python 3.11+, sqlite3, http.server.

Device reports use Authorization: Bearer <device token>.
Dashboard login uses TRACKSTAT_DASHBOARD_TOKEN and an in-memory HttpOnly session.
No Roblox credentials are accepted or stored.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import threading
from contextlib import contextmanager
from datetime import datetime, timezone
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent
STATIC = ROOT / "static"
DB_PATH = Path(os.environ.get("TRACKSTAT_DB", str(ROOT / "trackstat.sqlite3")))
HOST = os.environ.get("TRACKSTAT_HOST", "127.0.0.1")
PORT = int(os.environ.get("TRACKSTAT_PORT", "8787"))
STALE_SECONDS = int(os.environ.get("TRACKSTAT_STALE_SECONDS", "60"))
OFFLINE_SECONDS = int(os.environ.get("TRACKSTAT_OFFLINE_SECONDS", "180"))
MAX_BODY = 16 * 1024

DEVICE_TOKEN = os.environ.get("TRACKSTAT_DEVICE_TOKEN", "")
DASHBOARD_TOKEN = os.environ.get("TRACKSTAT_DASHBOARD_TOKEN", "")
DASHBOARD_TOKEN_HASH = os.environ.get("TRACKSTAT_DASHBOARD_TOKEN_SHA256", "")
DEVICE_TOKEN_HASH = os.environ.get("TRACKSTAT_DEVICE_TOKEN_SHA256", "")

DB_LOCK = threading.Lock()
SESSIONS: dict[str, float] = {}

ALLOWED_FIELDS = {
    "version", "username", "account_id", "observed_at", "observed_unix",
    "status", "source", "stars", "daily_streak", "longest_streak",
    "claimed", "daily", "current_goal", "egg_price", "stars_remaining",
    "next_claim_timestamp", "next_claim_in_seconds", "progress_kind",
}
FORBIDDEN_FIELD_NAMES = {
    "password", "passwd", "cookie", "cookies", "auth", "authorization",
    "session", "session_token", "executor_key", "webhook", "refresh_token",
}


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso_now() -> str:
    return utc_now().isoformat(timespec="seconds").replace("+00:00", "Z")


def token_digest(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def valid_device_token(token: str) -> bool:
    if not token:
        return False
    supplied = token_digest(token)
    expected = DEVICE_TOKEN_HASH or token_digest(DEVICE_TOKEN)
    return bool(expected) and hmac.compare_digest(supplied, expected)


def valid_dashboard_token(token: str) -> bool:
    if not token:
        return False
    if DASHBOARD_TOKEN_HASH:
        return hmac.compare_digest(token_digest(token), DASHBOARD_TOKEN_HASH)
    return bool(DASHBOARD_TOKEN) and hmac.compare_digest(token, DASHBOARD_TOKEN)


@contextmanager
def db_connect():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    try:
        yield conn
    finally:
        conn.close()


def init_db() -> None:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    with db_connect() as conn:
        conn.execute(
            """CREATE TABLE IF NOT EXISTS accounts (
                account_key TEXT PRIMARY KEY,
                username TEXT,
                account_id TEXT,
                version TEXT NOT NULL,
                status TEXT NOT NULL,
                source TEXT NOT NULL,
                stars INTEGER,
                egg_price INTEGER,
                stars_remaining INTEGER,
                daily_streak INTEGER,
                longest_streak INTEGER,
                claimed INTEGER,
                daily TEXT,
                current_goal TEXT,
                next_claim_timestamp REAL,
                next_claim_in_seconds REAL,
                progress_kind TEXT,
                observed_at TEXT,
                observed_unix INTEGER NOT NULL,
                last_sync_at TEXT NOT NULL,
                last_seen_at TEXT NOT NULL,
                report_hash TEXT NOT NULL
            )"""
        )
        conn.execute("CREATE INDEX IF NOT EXISTS idx_accounts_last_seen ON accounts(last_seen_at)")
        conn.commit()


def json_response(handler: BaseHTTPRequestHandler, status: int, payload: Any, extra_headers: dict[str, str] | None = None) -> None:
    raw = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(raw)))
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("Access-Control-Allow-Origin", "*")
    if extra_headers:
        for key, value in extra_headers.items():
            handler.send_header(key, value)
    handler.end_headers()
    handler.wfile.write(raw)


def reject_forbidden(value: Any, key: str = "") -> bool:
    if key.lower() in FORBIDDEN_FIELD_NAMES:
        return True
    if isinstance(value, dict):
        return any(reject_forbidden(v, k) for k, v in value.items())
    if isinstance(value, list):
        return any(reject_forbidden(v, key) for v in value)
    return False


def normalize_report(payload: dict[str, Any]) -> tuple[dict[str, Any] | None, str | None]:
    if reject_forbidden(payload):
        return None, "forbidden credential-like field"
    unknown = set(payload) - ALLOWED_FIELDS
    if unknown:
        return None, "unsupported fields: " + ",".join(sorted(unknown))

    username = payload.get("username")
    account_id = payload.get("account_id")
    if username is not None and (not isinstance(username, str) or not username or len(username) > 80):
        return None, "invalid username"
    if account_id is not None and (not isinstance(account_id, str) or len(account_id) > 80):
        return None, "invalid account_id"
    account_key = account_id or username
    if not account_key:
        return None, "account_id or username is required"

    observed_unix = payload.get("observed_unix")
    if isinstance(observed_unix, bool) or not isinstance(observed_unix, (int, float)):
        return None, "observed_unix is required"
    observed_unix = int(observed_unix)
    now = int(utc_now().timestamp())
    if observed_unix > now + 300:
        return None, "observed_unix is too far in the future"

    version = payload.get("version", "unknown")
    status = payload.get("status", "PARTIAL")
    source = payload.get("source", "unknown")
    if not isinstance(version, str) or len(version) > 32:
        return None, "invalid version"
    if status not in {"READY", "PARTIAL"}:
        return None, "invalid status"
    if source != "ClientData":
        return None, "source must be ClientData"

    ints = {"stars", "egg_price", "stars_remaining", "daily_streak", "longest_streak"}
    for field in ints:
        value = payload.get(field)
        if value is not None and (isinstance(value, bool) or not isinstance(value, int)):
            return None, f"invalid {field}"
    for field in {"next_claim_timestamp", "next_claim_in_seconds"}:
        value = payload.get(field)
        if value is not None and (isinstance(value, bool) or not isinstance(value, (int, float))):
            return None, f"invalid {field}"

    normalized = {field: payload.get(field) for field in ALLOWED_FIELDS}
    normalized.update({"account_key": str(account_key), "observed_unix": observed_unix})
    return normalized, None


def report_hash(report: dict[str, Any]) -> str:
    body = json.dumps(report, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


def parse_iso_epoch(value: str) -> float:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def derived_status(row: sqlite3.Row, now: float | None = None) -> str:
    now = now or utc_now().timestamp()
    seen_age = max(0, now - parse_iso_epoch(row["last_seen_at"]))
    sync_age = max(0, now - parse_iso_epoch(row["last_sync_at"]))
    if seen_age <= 30 and sync_age > STALE_SECONDS:
        return "RECONNECTING"
    if seen_age <= STALE_SECONDS:
        return row["status"]
    if seen_age <= OFFLINE_SECONDS:
        return "STALE"
    return "OFFLINE"


def ingest(report: dict[str, Any]) -> tuple[int, dict[str, Any]]:
    now = iso_now()
    digest = report_hash(report)
    with DB_LOCK, db_connect() as conn:
        old = conn.execute("SELECT * FROM accounts WHERE account_key = ?", (report["account_key"],)).fetchone()
        if old:
            if report["observed_unix"] < old["observed_unix"]:
                conn.execute("UPDATE accounts SET last_seen_at = ? WHERE account_key = ?", (now, report["account_key"]))
                conn.commit()
                return HTTPStatus.OK, {"accepted": False, "duplicate": False, "outdated": True, "account_key": report["account_key"]}
            if report["observed_unix"] == old["observed_unix"] and digest == old["report_hash"]:
                conn.execute("UPDATE accounts SET last_seen_at = ? WHERE account_key = ?", (now, report["account_key"]))
                conn.commit()
                return HTTPStatus.OK, {"accepted": False, "duplicate": True, "outdated": False, "account_key": report["account_key"]}

        values = [
            report.get("account_key"), report.get("username"), report.get("account_id"),
            report.get("version", "unknown"), report.get("status", "PARTIAL"), report.get("source", "ClientData"),
            report.get("stars"), report.get("egg_price"), report.get("stars_remaining"),
            report.get("daily_streak"), report.get("longest_streak"),
            None if report.get("claimed") is None else int(report["claimed"]), report.get("daily"),
            report.get("current_goal"), report.get("next_claim_timestamp"), report.get("next_claim_in_seconds"),
            report.get("progress_kind"), report.get("observed_at"), report["observed_unix"], now, now, digest,
        ]
        conn.execute(
            """INSERT INTO accounts (
                account_key, username, account_id, version, status, source, stars, egg_price,
                stars_remaining, daily_streak, longest_streak, claimed, daily, current_goal,
                next_claim_timestamp, next_claim_in_seconds, progress_kind, observed_at,
                observed_unix, last_sync_at, last_seen_at, report_hash
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(account_key) DO UPDATE SET
                username=excluded.username, account_id=excluded.account_id, version=excluded.version,
                status=excluded.status, source=excluded.source, stars=excluded.stars,
                egg_price=excluded.egg_price, stars_remaining=excluded.stars_remaining,
                daily_streak=excluded.daily_streak, longest_streak=excluded.longest_streak,
                claimed=excluded.claimed, daily=excluded.daily, current_goal=excluded.current_goal,
                next_claim_timestamp=excluded.next_claim_timestamp,
                next_claim_in_seconds=excluded.next_claim_in_seconds, progress_kind=excluded.progress_kind,
                observed_at=excluded.observed_at, observed_unix=excluded.observed_unix,
                last_sync_at=excluded.last_sync_at, last_seen_at=excluded.last_seen_at,
                report_hash=excluded.report_hash""",
            values,
        )
        conn.commit()
        return HTTPStatus.ACCEPTED, {"accepted": True, "duplicate": False, "outdated": False, "account_key": report["account_key"], "last_sync_at": now}


def row_json(row: sqlite3.Row) -> dict[str, Any]:
    result = dict(row)
    result["claimed"] = None if result["claimed"] is None else bool(result["claimed"])
    result["derived_status"] = derived_status(row)
    return result


def list_accounts() -> list[dict[str, Any]]:
    with DB_LOCK, db_connect() as conn:
        rows = conn.execute("SELECT * FROM accounts ORDER BY username COLLATE NOCASE, account_key").fetchall()
    return [row_json(row) for row in rows]


def cookie_session(handler: BaseHTTPRequestHandler) -> bool:
    cookie = SimpleCookie()
    cookie.load(handler.headers.get("Cookie", ""))
    token = cookie.get("trackstat_session")
    return bool(token and token.value in SESSIONS and SESSIONS[token.value] > utc_now().timestamp())


class Handler(BaseHTTPRequestHandler):
    server_version = "TrackStat/1.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        # Never log Authorization headers or report bodies.
        print("[trackstat-vps] " + (fmt % args))

    def do_OPTIONS(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()

    def do_GET(self) -> None:
        if self.path == "/healthz":
            json_response(self, HTTPStatus.OK, {"ok": True, "service": "trackstat", "time": iso_now()})
            return
        if self.path in {"/", "/index.html"}:
            self.serve_static("index.html")
            return
        if self.path == "/api/v1/accounts":
            if not cookie_session(self) and not self.dashboard_authorized():
                json_response(self, HTTPStatus.UNAUTHORIZED, {"error": "dashboard authentication required"})
                return
            json_response(self, HTTPStatus.OK, {"accounts": list_accounts(), "server_now": iso_now(), "stale_seconds": STALE_SECONDS, "offline_seconds": OFFLINE_SECONDS})
            return
        self.send_error(HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:
        if self.path == "/api/v1/dashboard/login":
            body = self.read_json()
            if not body or not valid_dashboard_token(str(body.get("token", ""))):
                json_response(self, HTTPStatus.UNAUTHORIZED, {"error": "invalid dashboard token"})
                return
            session = secrets.token_urlsafe(32)
            SESSIONS[session] = utc_now().timestamp() + 8 * 3600
            json_response(self, HTTPStatus.OK, {"ok": True}, {"Set-Cookie": f"trackstat_session={session}; HttpOnly; SameSite=Strict; Path=/; Max-Age=28800"})
            return
        if self.path == "/api/v1/trackstat":
            if not self.device_authorized():
                json_response(self, HTTPStatus.UNAUTHORIZED, {"error": "invalid device authorization"})
                return
            body = self.read_json()
            if body is None or not isinstance(body, dict):
                json_response(self, HTTPStatus.BAD_REQUEST, {"error": "JSON object required"})
                return
            normalized, error = normalize_report(body)
            if error:
                json_response(self, HTTPStatus.UNPROCESSABLE_ENTITY, {"error": error})
                return
            status, response = ingest(normalized)
            json_response(self, status, response)
            return
        self.send_error(HTTPStatus.NOT_FOUND)

    def dashboard_authorized(self) -> bool:
        auth = self.headers.get("Authorization", "")
        return auth.startswith("Bearer ") and valid_dashboard_token(auth[7:])

    def device_authorized(self) -> bool:
        auth = self.headers.get("Authorization", "")
        return auth.startswith("Bearer ") and valid_device_token(auth[7:])

    def read_json(self) -> Any:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return None
        if length <= 0 or length > MAX_BODY:
            return None
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None

    def serve_static(self, name: str) -> None:
        path = (STATIC / name).resolve()
        if STATIC.resolve() not in path.parents or not path.is_file():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        body = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main() -> None:
    init_db()
    if not DEVICE_TOKEN and not DEVICE_TOKEN_HASH:
        print("[trackstat-vps] warning: TRACKSTAT_DEVICE_TOKEN(_SHA256) is not configured")
    if not DASHBOARD_TOKEN and not DASHBOARD_TOKEN_HASH:
        print("[trackstat-vps] warning: TRACKSTAT_DASHBOARD_TOKEN(_SHA256) is not configured")
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"[trackstat-vps] listening on http://{HOST}:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
