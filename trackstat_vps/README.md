# TrackStat VPS integration

This folder contains the receipt API and dashboard for the evidence-based TrackStat V21 scanner.

## Run

Set secrets outside the repository. For production, prefer the SHA-256 environment variables so plaintext tokens are never stored in the service environment:

```bash
export TRACKSTAT_DEVICE_TOKEN_SHA256='sha256-of-device-token'
export TRACKSTAT_DASHBOARD_TOKEN_SHA256='sha256-of-dashboard-token'
# Plain TRACKSTAT_DEVICE_TOKEN / TRACKSTAT_DASHBOARD_TOKEN are supported for local testing only.
python3 trackstat_vps/server.py
```

The Python service is intentionally HTTP on localhost; expose it through the VPS's HTTPS reverse proxy (Caddy/Nginx) and point the Lua endpoint at the HTTPS URL. Do not expose the development listener directly to the public internet.

Endpoints:

- `GET /healthz` — unauthenticated health check.
- `POST /api/v1/trackstat` — device reports; requires `Authorization: Bearer <device token>`.
- `POST /api/v1/dashboard/login` — creates an HttpOnly dashboard session.
- `GET /api/v1/accounts` — dashboard data; requires the session or dashboard bearer token.

The backend stores `observed_unix` from the device separately from server-generated `last_sync_at` and `last_seen_at`.
Outdated reports do not replace newer account data. Duplicate reports update `last_seen_at` but not the stored statistics.

Dashboard status:

- `READY` or `PARTIAL` while the last seen report is fresh.
- `RECONNECTING` when the device is contacting the server but the last accepted statistics are stale.
- `STALE` after the freshness threshold.
- `OFFLINE` after the offline threshold.

Do not put Roblox passwords, cookies, executor keys, or dashboard/device tokens in the Lua file or repository. Configure the Lua uploader at runtime:

```lua
getgenv().__TRACKSTAT_CONFIG = {
    endpoint = "https://your-host.example/api/v1/trackstat",
    device_token = "device-token-from-your-secret-store",
}
loadstring(game:HttpGet("https://raw.githubusercontent.com/lucivaantarez/autotrade/main/trackstat.lua"))()
```

The scanner remains read-only and targets only `ClientData.get_data()[Players.LocalPlayer.Name]`.
