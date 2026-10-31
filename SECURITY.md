# SECURITY.md

## Sensitive values

This project can contain live operational secrets in Lua config blocks or runtime globals:

- Discord/Saturnity webhook URLs in `CONFIG.WEBHOOK.url`.
- `SATURNITY_TRADELOG_TOKEN` via `getgenv()` in `adm_tradelog.lua`.
- ZekeHub `scriptkey` in `zekehub_winterhub.lua` local copies.
- Optional `WINTERHUB_WEBHOOK_URL` runtime global.

Do not print, commit, or paste real values into issue reports, summaries, or generated docs. If a live webhook URL or key was pushed to a public repo, rotate it.

## Files that must stay uncommitted

The `.gitignore` already excludes runtime output and local config patterns:

- `*_winteraddons.json`
- `*_winterswap.json`
- `*_blackbox.log`
- `*_crash.json`
- `*_tradefails.log`
- `*_tradelog_debug.log`
- `secrets.lua`
- `*.local`

Treat generated Graphify outputs, local archives, and executor workspace logs as review artifacts unless explicitly needed.

## Network behavior

- `adm_autotrade.lua` sends trade-completion webhook payloads when enabled.
- `adm_blackbox.lua` sends crash reports on the next launch after a detected kick when enabled.
- `adm_tradelog.lua` can send trade-failure reports when enabled.
- `zekehub_winterhub.lua` loads ZekeHub Utility from `https://zekehub.com/scripts/AdoptMe/Utility.lua` and may send a WinterHub webhook if configured.

Webhook sending must remain pcall/asynchronous where applicable so failed or slow HTTP does not break the trade loop or WinterHub heartbeat.

## Safe development rules

- Prefer runtime globals or untracked local config for secrets.
- Keep committed examples blank or clearly dummy.
- Do not add logging that dumps full HTTP headers, tokens, remote payloads, or private account identifiers unless it is local-only diagnostic output and explicitly needed.
- Do not change webhook endpoints or auth behavior without calling it out in the final report.
