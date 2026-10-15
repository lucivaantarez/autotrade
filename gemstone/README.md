# Gemstone daily-login subsystem

This directory contains the safe, adapter-driven Gemstone workflow. It is isolated from the existing trade scripts and does not invoke Adopt Me remotes, executor hooks, simulated input, or account rotation.

## Modules

- `model.lua` — state/status constants and conservative value parsing.
- `startup_controller.lua` — bounded startup/onboarding state machine using an injected adapter.
- `reward_inspector.lua` — read-only account/reward normalization.
- `claim_verifier.lua` — before/after verification for an authorized claim adapter; prevents duplicate claims per adapter lifecycle.
- `reporter.lua` — writes `gemstone_result.txt` and `gemstone_result.json` through an injected file adapter.
- `winterhub_adapter.lua` — writes `<username>_winterswap.json` only for a verified completed result.
- `workflow.lua` — orchestrates the modules and refuses completion when required statistics are unavailable.

## Adapter boundary

A live integration must explicitly provide these methods:

- `is_available()`
- `is_game_ready()`
- `is_in_game()`
- `initialize_location()`
- `get_onboarding_screen()`
- `handle_play()`, `handle_home()`, `handle_favorite_color()`
- `read_reward_state()`
- `claim_reward()`

The repository does not currently contain a verified Gemstone runtime adapter or V6–V16 recording files. Therefore live startup and claim integration remain UNVERIFIED/BLOCKED. The modules are tested with deterministic simulated services.

## Test

From the repository root:

```bash
node test_gemstone_simulation.mjs
for f in gemstone/*.lua; do npx --yes luaparse "$f" >/dev/null || exit 1; done
```

The simulation covers already-claimed, unclaimed, slow startup, unexpected dialogs, delayed updates, failed verification, partial statistics, and duplicate execution. Purchase remains disabled.
