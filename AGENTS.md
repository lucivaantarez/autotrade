# AGENTS.md

AI operating guide for LazyHub AutoTrade.

## Default AI Startup Workflow

1. Read `AGENTS.md` first.
2. Read `IDEA.md` and `SCRIPT_SPEC.md` next.
3. For file relationships or architecture questions, use Graphify before broad repo scans.
4. Inspect only task-relevant files/ranges; use `search_files` to locate symbols before reading.
5. Avoid duplicated context: do not reread docs that only repeat `SCRIPT_SPEC.md`.
6. Before changing files, state the planned files and why.

Read selectively:

- `handout.md` only for Adopt Me internals, trade-state logic, WinterHub contracts, or unclear runtime behavior.
- `SECURITY.md` only for webhook/token/log/network changes.
- `README.md` only for human quick-start/public-facing edits.
- Ignore `graphify-out/` and `adm_autotrade_vX.XX.XXX.lua` release snapshots unless the task specifically needs generated graph data or release/version comparison.

## Change rules

- Do not move, rename, obfuscate, or rewrite Lua scripts without first explaining the plan and risk.
- Treat non-`CONFIG` code in the Lua scripts as load-bearing unless the task explicitly asks for runtime changes.
- Preserve the boundary: in-game scripts write local status files; WinterHub/host tooling handles hopping. Do not add in-game server hopping to `adm_autotrade.lua`.
- Keep diagnostics side-effect-light: `adm_tradelog.lua` should remain read-only against the trade state; `adm_blackbox.lua` should record and report without changing trade behavior.
- Protect user secrets. Do not print, commit, or move live webhook URLs, bearer tokens, ZekeHub keys, or generated crash/trade logs.
- When changing behavior, update `handout.md` and `SCRIPT_SPEC.md` if the documented contracts changed.
- Canonical source: `adm_autotrade.lua`. Versioned `adm_autotrade_vX.XX.XXX.lua` files are release artifacts.

## Verification

Run the focused local checks before claiming completion:

```bash
git diff --check
node test_autotrade_driver.mjs
node test_tradelog_detection.mjs
node test_zekehub_winterhub.mjs
npx --yes --package fengari-node-cli fengari test_autotrade_empty_trade.lua
npx --yes --package fengari-node-cli fengari test_autotrade_winterhub_v2.lua
npx --yes --package fengari-node-cli fengari test_autotrade_webhook_v2.lua
npx --yes --package fengari-node-cli fengari test_autotrade_scheduling.lua
npx --yes luaparse adm_autotrade.lua >/dev/null
npx --yes luaparse adm_blackbox.lua >/dev/null
npx --yes luaparse adm_tradelog.lua >/dev/null
npx --yes luaparse zekehub_winterhub.lua >/dev/null
```

Local checks are necessary but not sufficient. Final confidence for runtime behavior still requires an in-game Delta/Adopt Me run because local Node tests only assert source structure and small simulations.

## Graphify notes

Use Graphify before broad architecture scans. Code-only mode works without an API key; exclude `graphify-out/` and release copies unless the task needs them. Current hubs: `log()`, `install_accept_hook()`, `send_trade_webhook()`, `ensure_deps()`, `force_everyone()`, `get_trade_app()`, `mark_activity()`, `patch_trade_app()`, `step_trade()`.
