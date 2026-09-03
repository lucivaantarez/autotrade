# LazyHub AutoTrade

Automated Adopt Me trade-acceptance system for a self-owned bot fleet.
Runs under the **Delta** executor; hopping between servers is handled by the
external **WinterHub** agent.

> **AI / new contributor: read [`handout.md`](./handout.md) first.**
> It documents the game internals, the WinterHub status-file contract, and the
> known constraints. Changes that ignore it cause "trade unexpectedly failed"
> and Error Code 267 regressions.

## Files

| File | Purpose |
|---|---|
| [`handout.md`](./handout.md) | Full project reference — architecture, contracts, known issues, queued fixes. **Start here.** |
| `adm_autotrade.lua` | Accepts + drives trades to completion, writes the WinterHub status file, Discord webhook on completion. |
| `adm_blackbox.lua` | Diagnostic flight recorder — run alongside autotrade to capture why an account got **kicked/disconnected** (Error Code 267). |
| `adm_tradelog.lua` | Diagnostic — run alongside autotrade to capture why a trade **failed while still in-game** ("trade unexpectedly failed"). |

## Quick start

1. Set the CONFIG block at the top of `adm_autotrade.lua` (webhook URL, toggles).
2. Set `CONFIG.WEBHOOK.url` in the diagnostic scripts you run (blank by default).
3. Load in Delta on each bot account (autotrade is required; the two diagnostics are optional, add whichever failure you're chasing):
   ```lua
   loadstring(game:HttpGet("https://raw.githubusercontent.com/lucivaantarez/<repo>/main/adm_autotrade.lua"))()
   loadstring(game:HttpGet("https://raw.githubusercontent.com/lucivaantarez/<repo>/main/adm_blackbox.lua"))()   -- if accounts get KICKED (267)
   loadstring(game:HttpGet("https://raw.githubusercontent.com/lucivaantarez/<repo>/main/adm_tradelog.lua"))()   -- if trades FAIL in-game
   ```
4. WinterHub reads each account's `<username>_winteraddons.json` and handles hopping.

### Which diagnostic?

| Symptom | Tool |
|---|---|
| Account **leaves the server** — "Disconnected / Error Code 267" prompt | `adm_blackbox.lua` |
| Account **stays in-game**, trade dies — "trade unexpectedly failed" | `adm_tradelog.lua` |

You only ever edit the CONFIG blocks. Everything else is documented in the handout.

## ⚠️ Before pushing

`adm_autotrade.lua` contains a Discord **webhook URL in plaintext**. Either keep
this repo **private**, or blank the URL in the committed copy and keep the real
one in an untracked config file. Never commit a live secret to a public repo —
if it's already been pushed, regenerate the webhook in Discord.
