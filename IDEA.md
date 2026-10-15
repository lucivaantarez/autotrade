# IDEA.md

## Product idea

LazyHub AutoTrade automates safe, repeatable Adopt Me pet consolidation across self-owned bot accounts. The in-game scripts handle only trade acceptance, completion tracking, diagnostics, and local status output; external tooling such as WinterHub handles server hopping/account flow.

## Current goal

Make bot accounts reliably accept incoming trades, finish valid trades, record what happened, and expose enough status for WinterHub or a human operator to decide the next action.

## Core user workflow

1. Configure the `CONFIG` block in the Lua script being used.
2. Run `adm_autotrade.lua` in Delta on each bot account.
3. Optionally run diagnostics:
   - `adm_blackbox.lua` when accounts are kicked/disconnected.
   - `adm_tradelog.lua` when trades fail while the account stays in-game.
4. WinterHub reads `<username>_winteraddons.json` and hops only when status becomes `completed`.
5. Discord/webhook endpoints receive trade or failure reports when enabled.

## Non-goals

- Open-market trading or partner discovery.
- In-game server hopping from `adm_autotrade.lua`.
- Storing secrets in committed source.
- Replacing WinterHub/ZekeHub behavior inside the standalone script.
- Heavy refactors unless diagnostics prove the simpler runtime cannot be fixed surgically.

## Open decisions

- `winterswap` account rotation is not fully designed: decide whether an account rotates after one trade or after a batch before building it.
- Ownership validation before offering item UIDs is still queued if diagnostics show server rejects caused by already-moved pets.
- If this repo becomes public, webhook/key injection should move fully to local config or runtime globals instead of inline URLs.

## Gemstone daily-login subsystem

The isolated `gemstone/` directory contains an adapter-driven daily-login workflow with bounded startup state handling, read-only reward inspection, before/after claim verification, TrackStat TXT/JSON reporting, and a guarded WinterHub swap adapter. It does not modify the existing trade scripts or invoke undocumented game remotes.

Current evidence status:

- Existing repository: trade automation only; no verified Gemstone implementation or V6–V16 recordings were present.
- Startup/onboarding live adapter: BLOCKED pending verified runtime evidence.
- Reward-state live adapter: BLOCKED pending verified runtime evidence.
- Claim transaction: UNVERIFIED; only the before/after interface is implemented.
- Statistics/reporting/swap contracts: VERIFIED by deterministic mock tests and Lua syntax checks.
- Gemstone purchase: DISABLED.

See `gemstone/README.md` and `test_gemstone_simulation.mjs`.
