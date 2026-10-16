import json
import tempfile
import unittest
from datetime import datetime, timezone, timedelta
from pathlib import Path

import server


class TrackStatBackendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        server.DB_PATH = Path(self.temp.name) / "trackstat.sqlite3"
        server.DEVICE_TOKEN = "device-secret"
        server.DEVICE_TOKEN_HASH = ""
        server.DASHBOARD_TOKEN = "dashboard-secret"
        server.init_db()

    def tearDown(self):
        self.temp.cleanup()

    def report(self, observed_unix=1000, stars=3):
        return {
            "version": "21.0",
            "username": "GraysoonCruz5",
            "account_id": "123",
            "observed_at": "2026-10-16 07:40:16",
            "observed_unix": observed_unix,
            "status": "READY",
            "source": "ClientData",
            "stars": stars,
            "egg_price": 28,
            "stars_remaining": 25,
            "daily_streak": 1,
            "longest_streak": 2,
            "claimed": True,
            "daily": "CLAIMED",
            "current_goal": "star_egg",
            "next_claim_timestamp": 1792135961.67,
            "next_claim_in_seconds": 82445.6,
            "progress_kind": "balance_vs_price",
        }

    def test_ready_report_is_stored_and_deduplicated(self):
        normalized, error = server.normalize_report(self.report())
        self.assertIsNone(error)
        status, result = server.ingest(normalized)
        self.assertEqual(status, 202)
        self.assertTrue(result["accepted"])

        status, result = server.ingest(normalized)
        self.assertEqual(status, 200)
        self.assertTrue(result["duplicate"])

        rows = server.list_accounts()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["stars"], 3)
        self.assertEqual(rows[0]["username"], "GraysoonCruz5")

    def test_outdated_report_does_not_replace_newer_values(self):
        first, error = server.normalize_report(self.report(observed_unix=2000, stars=9))
        self.assertIsNone(error)
        server.ingest(first)
        old, error = server.normalize_report(self.report(observed_unix=1000, stars=1))
        self.assertIsNone(error)
        status, result = server.ingest(old)
        self.assertEqual(status, 200)
        self.assertTrue(result["outdated"])
        self.assertEqual(server.list_accounts()[0]["stars"], 9)

    def test_credentials_are_rejected(self):
        payload = self.report()
        payload["cookie"] = "must-not-be-accepted"
        normalized, error = server.normalize_report(payload)
        self.assertIsNone(normalized)
        self.assertIn("credential", error)

    def test_missing_source_and_identity_are_rejected(self):
        payload = self.report()
        payload.pop("account_id")
        payload.pop("username")
        normalized, error = server.normalize_report(payload)
        self.assertIsNone(normalized)
        self.assertIn("account_id or username", error)

        payload = self.report()
        payload["source"] = "GUI"
        normalized, error = server.normalize_report(payload)
        self.assertIsNone(normalized)
        self.assertIn("ClientData", error)

    def test_status_categories_are_age_based(self):
        normalized, error = server.normalize_report(self.report())
        self.assertIsNone(error)
        server.ingest(normalized)
        with server.db_connect() as conn:
            conn.execute("UPDATE accounts SET last_seen_at = ?, last_sync_at = ?", (
                (datetime.now(timezone.utc) - timedelta(seconds=10)).isoformat().replace("+00:00", "Z"),
                (datetime.now(timezone.utc) - timedelta(seconds=120)).isoformat().replace("+00:00", "Z"),
            ))
            conn.commit()
        self.assertEqual(server.list_accounts()[0]["derived_status"], "RECONNECTING")


if __name__ == "__main__":
    unittest.main()
