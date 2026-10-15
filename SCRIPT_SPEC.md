# SCRIPT_SPEC.md

Concise behavior contract for the Lua scripts. Default AI context; read `handout.md` only when changing game internals or unclear runtime contracts.

## `adm_autotrade.lua`

Purpose: standalone Delta runtime for self-owned Adopt Me bot accounts.

Responsibilities:

- Force trade/give settings to `Everyone` when enabled.
- Install and repair the `DialogApp.dialog` trade-request hook.
- Force-answer an already-open startup trade dialog.
- Neutralize known trade warning/scam/fairness popups that block flow.
- Drive `TradeApp` from `negotiation` to `confirmation` with delays and live state revalidation.
- Count only real completions: last stage was `confirmation` and both offers were confirmed before state became nil.
- Snapshot received/given item tables before async webhook reporting.
- Write `<username>_winteraddons.json` heartbeat/status for WinterHub.

Important guards:

- Per-account singleton key: `__adm_autotrade_<UserId>`.
- `UIManager`, settings DB/helper, and `KindDB` can be unavailable during startup and must be retried.
- `DialogApp`/`TradeApp` can be replaced by the game; hooks and app patches must be repairable.
- Confirmation intentionally fires once per confirmation stage to reduce server-state rejection / Error 267 risk.
- Missing `TradeApp` is treated as transient for a bounded grace period, then stale lifecycle state is cleared.

Webhook fields currently include trade number, runtime, account, partner, item totals, net items, report mode, grouped item lines, footer account, and timestamp.

## `zekehub_winterhub.lua`

Purpose: wrapper around ZekeHub Utility that keeps WinterHub-compatible status output.

Responsibilities:

- Require a local ZekeHub `scriptkey` before loading Utility.
- Set ZekeHub Utility defaults for AutoTrade while disabling ZekeHub-owned auto-leave/account rotation.
- Force trade/give settings when configured.
- Watch trade state and update `<username>_winteraddons.json` with `status`, `ts`, `count`, and `items`.
- Send ZekeHub-style trade-completion webhook when configured.

Boundary: WinterHub owns hopping/account flow; the wrapper reports status only.

## `adm_blackbox.lua`

Purpose: diagnose account exits/kicks, especially Error Code 267.

Responsibilities:

- Record recent outgoing remotes and console messages.
- Detect disconnect/kick prompt text in CoreGui.
- Write rolling `<username>_blackbox.log`.
- Write `<username>_crash.json` on detected kick.
- Send pending crash report on next launch if webhook is configured.

It should not alter trade state or attempt recovery inside the dying VM.

## `adm_tradelog.lua`

Purpose: diagnose trades that fail while the account remains in-game.

Responsibilities:

- Poll `TradeApp` read-only.
- Snapshot stage, offers, confirmed flags, recent trade remotes, and visible/logged failure text.
- Write rolling `<username>_tradefails.log` and debug log.
- Optionally send one webhook per failure/cancel based on config.

It should remain safe to run alongside `adm_autotrade.lua` and should not press buttons or mutate trade state.

## WinterHub status contract

File: `<username>_winteraddons.json`

Fields:

- `status`: `active`, `completed`, `error`, or compatible value.
- `ts`: current `os.time()` heartbeat.
- `count`: completed trade count this session.
- `items`: summarized items from the latest completed trade.

Rules:

- Never emit `completed` mid-trade.
- Keep refreshing `ts`; stale files cause external relaunch behavior.
- Failed writes must remain retryable.
- In-game scripts report status; external WinterHub tooling decides hops/rejoins.

## Gemstone subsystem contract

The `gemstone/` modules are adapter-driven and game-agnostic. They may consume verified state from a live adapter, but they do not define or invoke undocumented Adopt Me remotes, simulated input, executor hooks, or account rotation.

- Startup uses explicit states and bounded retries; every action requires a post-action state check.
- Reward inspection preserves unavailable values instead of inventing defaults.
- Claim verification compares pre-claim and post-claim account state. A dismissed GUI is not success.
- Reports are written as `gemstone_result.txt` and `gemstone_result.json` through an injected file adapter.
- Failures include a classified `error_info.code` where possible; retry behavior is bounded and adapter-owned.
- `<username>_winterswap.json` is written only when the result is `COMPLETED`, game readiness and claim verification are true, required statistics are present, and reporting succeeded.
- Gemstone purchasing is not implemented and remains disabled.
- Current repository evidence does not include a verified Gemstone live adapter or V6–V16 recordings; live integration is therefore BLOCKED/UNVERIFIED while deterministic mock behavior is covered by `test_gemstone_simulation.mjs`.
