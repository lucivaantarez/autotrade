# Project State

Updated: 2026-10-16
Repository: `C:\Users\Administrator\Project\roblox-script`
Branch: `main`
Remote: `https://github.com/lucivaantarez/autotrade.git`

## Current scope

The active development state is the TrackStat correction project. TrackStat is a separate, read-only statistics scanner for the Adopt Me runtime. It is not merged into the trade automation scripts.

## Completed and verified

### Evidence review

- Retrieved and inspected `gemstone/evidence/trackstat_vps_handoff_2026-10-16.zip` from the published repository.
- Read `README_START_HERE.md` first, as required.
- Confirmed `source/trackstat_v21.lua` is the working baseline.
- Confirmed V21 reads `Fsys -> ClientData` and selects only `ClientData.get_data()[Players.LocalPlayer.Name]`.
- Confirmed the supplied V21 result was a successful `READY` observation with stars, daily streak, claim state, current goal, and egg price.
- Preserved the distinction that stars versus egg price is purchasing power, not lifetime gemstone progress.

### Lua scanner

- Replaced the earlier GUI-scraping implementation in `trackstat.lua` with the V21 ClientData implementation.
- Preserved targeted LocalPlayer-only reading.
- Preserved 2-second continuous scanning.
- Preserved startup retry behavior for missing `Fsys`, `ClientData`, or local player data.
- Preserved timestamped change-only console logging and 60-second heartbeat logging.
- Preserved local `trackstat_result.txt` and `trackstat_result.json` output.
- Added runtime-only optional VPS upload configuration through `getgenv().__TRACKSTAT_CONFIG`.
- Added asynchronous bounded upload retries and a 60-second upload heartbeat.
- Added a runtime account name and LocalPlayer UserId identifier to reports.
- Kept the scanner read-only: no GUI activation, purchases, claims, game remotes, hooks, or swap signals.
- Added `trackstat_v21.lua` as the repository copy of the corrected evidence baseline.

### VPS backend and dashboard

- Added `trackstat_vps/server.py` using Python standard library HTTP handling and SQLite persistence.
- Added authenticated device ingestion at `POST /api/v1/trackstat`.
- Added dashboard authentication and account readback endpoints.
- Stores client `observed_unix` separately from server-generated `last_sync_at` and `last_seen_at`.
- Rejects credential-like fields including passwords, cookies, authorization values, executor keys, and webhook values.
- Requires `source=ClientData` and validates the report schema and value types.
- Prevents outdated reports from overwriting newer reports.
- Deduplicates identical reports while still recording authenticated device presence through `last_seen_at`.
- Derives `READY`, `PARTIAL`, `RECONNECTING`, `STALE`, and `OFFLINE` states from server receipt age.
- Added `trackstat_vps/static/index.html` showing Last Sync, Last Seen, observation time, account data, and status in the browser's local timezone.
- Added hashed-token environment variable support for production configuration.

### Deployment support

- Added `trackstat_vps/deploy/trackstat.service` for systemd.
- Added `trackstat_vps/deploy/Caddyfile.example` for HTTPS reverse proxying.
- Added `trackstat_vps/deploy/README.md` with installation, secret, service, proxy, and verification instructions.
- The Python service remains intended for localhost behind Caddy or Nginx; it is not intended to be directly exposed.

## Verification completed

- TrackStat backend tests: 6 passed.
- Backend persistence/reinitialization test: passed.
- Duplicate report handling: passed.
- Outdated report protection: passed.
- Credential-field rejection: passed.
- Reconnecting status derivation: passed.
- Lua syntax checks for `trackstat.lua`: passed with `luaparse`.
- Lua syntax checks for `trackstat_v21.lua`: passed with `luaparse`.
- Local HTTP integration previously verified:
  - `/healthz` returned HTTP 200.
  - Authenticated report ingestion returned HTTP 202.
  - Credential-bearing report returned HTTP 422.
  - Dashboard login and account readback returned HTTP 200.
- GitHub remote was verified to contain the TrackStat scanner, backend, dashboard, and deployment artifacts.

## Pending tasks

- Deploy `trackstat_vps/server.py` to the actual VPS.
- Configure a real device token and dashboard token outside the repository.
- Put the backend behind the actual HTTPS domain/reverse proxy.
- Perform one live Delta/Redfinger upload test using a non-production test account.
- Confirm server-generated Last Sync and Last Seen on the real dashboard.
- Test stop/reconnect behavior against the real device.
- Test delayed and duplicate packets against the deployed service.
- Add the TrackStat dashboard to the real website only after its source repository or deployment access is provided.

## Blockers and limitations

- The current environment has no VPS credentials or deployment channel.
- `ts.saturnity.site` is not represented in the current repository and did not resolve from this environment during inspection.
- The real website source, database, hosting configuration, and dashboard route are unavailable here.
- Live executor HTTP behavior and the production HTTPS reverse proxy have not been exercised from this environment.
- The scanner's live ClientData behavior is evidence-backed, but concurrent operation with the external Zeke automation has not been independently verified.
- The server is locally tested; production deployment and operational monitoring remain unverified.

## Next actions when access is available

1. Deploy the service using `trackstat_vps/deploy/README.md`.
2. Verify `/healthz` through the HTTPS domain.
3. Configure one test device with runtime-only `__TRACKSTAT_CONFIG`.
4. Confirm one accepted report in the dashboard.
5. Stop the test device and verify STALE/OFFLINE transitions.
6. Restart the backend and verify SQLite persistence.
7. Send an older report and verify it cannot overwrite the newer report.
8. Integrate the dashboard into the real website only after the website source/deployment boundary is identified.

## Repository safety notes

- Do not add Roblox passwords, cookies, executor keys, device tokens, dashboard tokens, or private account lists to source control.
- Do not replace the ClientData scanner with GUI scraping or guessed game APIs.
- Do not add claim, purchase, account-rotation, swap, or remote-invocation behavior to TrackStat.
- Existing unrelated working-tree changes were intentionally left untouched when this state was saved.
