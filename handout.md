# LazyHub AutoTrade — Project Handout

Reference doc for the Adopt Me auto-trade system. Hand this to an AI (or a
human) so they have full context before touching any script. If a change is
proposed, it must respect the **contracts** and **known constraints** below —
most "trade unexpectedly failed" regressions come from breaking one of them.

---

## 1. What this project is

An **automated trade-acceptance system** for a fleet of Adopt Me bot accounts.
Purpose: move pets between accounts owned by the operator (self-trading /
consolidation), not open-market trading.

Each bot account runs a Lua script under the **Delta executor** (mobile /
Android, often on cloud phones like Redfinger). The account auto-accepts
incoming trade requests, clicks through Accept → Confirm to completion, then
signals an external agent (**WinterHub**) to hop it to the next server.

**Pieces:**

| Component | Runs where | Job |
|---|---|---|
| `adm_autotrade.lua` | Delta, in-game | Accept + drive trades to completion; write status file; Discord webhook on completion |
| **WinterHub agent** | outside the game (host app) | Reads each account's status file; hops/rejoins the account between servers |
| `adm_blackbox.lua` | Delta, in-game (alongside autotrade) | Diagnostic "flight recorder"; captures why an account got **disconnected/kicked** (267) |
| `adm_tradelog.lua` | Delta, in-game (alongside autotrade) | Diagnostic; captures why a trade **failed while still in-game** ("trade unexpectedly failed") |

The autotrade script and WinterHub communicate **only through a JSON status
file** — they never call each other. Keep that boundary.

---

## 2. Hard-won game internals (do not re-derive, do not "fix")

These came from decompiled-module analysis. They are correct and load-bearing.

- Adopt Me uses an `Fsys` module system: `local Fsys = require(ReplicatedStorage.Fsys)`, then `Fsys.load("ModuleName")`.
- The Promise module is `Fsys.load("package:Promise")` — **not** `"Promise"`.
- **UI apps** live at `UIManager.apps` (e.g. `apps.DialogApp`, `apps.TradeApp`).
- **Trade-request dialogs**: the real method is `DialogApp.dialog(self, opts)`. It lives on the **class** (via metatable `__index`), not the instance, and it **returns a Promise**, not a string. For `opts.handle == "trade_request"`, resolving the promise with `"Accept"` accepts the request.
- A dialog already on screen when the script starts is detected via `ticket_count > completed_ticket` (the property `is_dialog_open` is unreliable — reads false while a request is visible). The in-flight ticket is `completed_ticket + 1`; push an answer via `DialogApp.force_response_signal:Fire(ticket, table.pack("Accept"))`.
- **Trade state machine**: `TradeApp:_get_local_trade_state()` returns state or nil. `state.current_stage` is `"negotiation"` then `"confirmation"`. nil state = trade window closed/finished.
  - Advance with `app:_on_accept_pressed()` (negotiation) and `app:_on_confirm_pressed()` (confirmation).
  - Offers: `app:_get_my_offer()` / `app:_get_partner_offer()` → each has `.confirmed` (bool) and `.items` (array).
  - A **real completion** = last stage was `confirmation` AND both offers `.confirmed` before the state went nil. (A cancel also drops to nil, so you must have cached `confirmed` beforehand.)
- **Items**: each item has `.kind` and `.properties`. Display name = `Fsys.load("KindDB")[kind].name`. Properties: `.neon`, `.mega_neon`, `.rideable` (R), `.flyable` (F).
- **Settings**: `SettingsHelper.set_setting_client({ setting_id, value })`. Choices come from `SettingsDB.by_id[id].element_options.choices`; find the index of `"Everyone"`. Relevant ids: `"trade_requests"` and `"give_item_requests"`. StarPets/other logins reset these to "Friends", which **blocks bots from sending** — so the script force-sets them to Everyone on startup.
- **Trade-flow popups to neutralize** (all are `self:method()` calls, so instance overrides shadow the class): `_confirm_player_if_suspicious`, `_evaluate_trade_fairness`, `_show_scam_perpetrator_warning`, `_show_scam_victim_warning`, `_show_experimental_warning`, `show_scam_warning`, `_confirm_clear_colored_pets`. Also `MinigameForcedState.can_receive_invites` → true and `TradeExcluder.is_player_excluded` → false so join doesn't auto-decline.

---

## 3. `adm_autotrade.lua` structure

Single file. **Only the CONFIG block is meant to be edited.** Sections:

1. **CONFIG** — on/off switches: `MASTER_ENABLED`, `FORCE_SETTINGS`, `AUTO_ACCEPT` (`poll`, `refire_every`), `WINTERHUB` (`idle_hop_seconds`, `heartbeat`), `WEBHOOK` (`url`, `report`), `DEBUG`.
2. **SETUP** — anti-AFK (VirtualUser on `Idled`); **per-account singleton guard** keyed on `getgenv()["__adm_autotrade_" .. UserId]` (two Delta clones share one env, so a plain global would abort clone 2 — keying on UserId lets each account run but blocks a true double-execute on the same account). Loads `UIManager` eagerly; loads `SettingsHelper`/`SettingsDB`/`KindDB` lazily *after* the hook is in (getting the accept hook in fast prevents the first-request race).
3. **FORCE SETTINGS** — trade/give → Everyone.
4. **AUTO-ACCEPT** — installs the `DialogApp.dialog` hook (short-circuits `trade_request` with a resolved `"Accept"` promise) + patches TradeApp popups. `clear_open_request()` handles a dialog already waiting at startup.
5. **TRADE DRIVER** (`step_trade`) — reads state, caches offers at confirmation, fires accept/confirm no more often than `refire_every`, detects real completion, bumps `trade_count`, triggers webhook + updates `last_items`.
6. **WINTERHUB** (`write_winterhub`) — writes the status file on a heartbeat (see contract below).
7. **MAIN LOOP** — spin-waits to install the hook the instant `apps` exist; re-verifies the hook each poll (re-installs on DialogApp instance swap); forces settings once hook confirmed; runs `step_trade` + `write_winterhub` under pcall so it never crashes out.
8. **WEBHOOK** — Discord embed on completion; dedup by signature within a ~6s window (a real second trade can't complete that fast due to lock timers).

---

## 4. WinterHub status-file contract (GAME-AGNOSTIC — keep it that way)

The autotrade script's **only** job toward WinterHub is to write status
truthfully. WinterHub does the hopping. The script must never try to hop
itself.

**File:** `<username>_winteraddons.json`, rewritten every `heartbeat` (~5s).

```json
{
  "status": "active",          // see below
  "ts": 1723471200,            // os.time() (Unix sec). File older than ~40s = dead → agent relaunches
  "count": 12,                 // completed trades this session (dashboard progress)
  "items": [                   // last completed trade's items, for the dashboard
    { "name": "Frost Dragon", "qty": 1 },
    { "name": "Shadow Dragon", "qty": 2 }
  ]
}
```

**`status` values:**

| Value | Meaning → agent action |
|---|---|
| `completed` | no trade received for `idle_hop_seconds` AND no trade currently open → **agent hops to next server** |
| `disconnected` / `error` | → **agent rejoins the SAME server** |
| `active` (or anything else) | keep going; just a heartbeat |

**Rules the writer must obey:**
- Never emit `completed` mid-trade (`in_trade` guards this). Hop only after the idle window with no open trade.
- `ts` must keep refreshing even when idle — a background heartbeat, or the agent thinks the account froze and relaunches it.
- This contract replaced the older Cloudflare-Worker mailbox + `IDLE_WATCHDOG` kick/rehop mechanism. Don't reintroduce those.

**Separate Swap contract** (full account rotation, distinct from trade/hop):
`<username>_winterswap.json`. **Open design question:** does each account do a
fixed batch of trades then hop, or trade once then rotate out? Decide before
building swap logic.

---

## 5. `adm_blackbox.lua` (diagnostic, run alongside)

Because a **267 kick tears down the Lua VM instantly**, you can't diagnose
after the fact from inside the kicked session. Blackbox is a flight recorder.

- **Records continuously:** every outgoing `FireServer`/`InvokeServer` (with args) via a pcall-guarded `__namecall` hook; console output via `LogService.MessageOut`; trade context read from the WinterHub file.
- **Kick detector:** a CoreGui text scan that keys on the on-screen "Error Code / bug was detected / Disconnected" prompt. This is the discriminator between a real kick and a normal WinterHub hop (a clean hop shows the teleport loader, not an error prompt). Also treats `NetworkClient` child-removed as a drop.
- **On kick:** snapshots last ~25 remotes + console → `<username>_crash.json`. Because the VM dies, the report is **auto-sent to Discord on the next launch** when WinterHub rejoins.
- **Always-readable:** rolling `<username>_blackbox.log` (last ~200 events), flushed every few seconds — open it any time.
- Config: set `CONFIG.WEBHOOK.url`; `LOG_REMOTES`/`LOG_CONSOLE`/`BUFFER`/`FLUSH`.

**Reading a dump:** if the last remote before the kick is `TradeApp` accept/
confirm traffic → the trade logic is tripping the server's state check (fixable
in-script). If the last remotes are ordinary/idle and the reason is generic →
more likely blanket executor detection (needs executor update, not script
changes).

---

## 5b. `adm_tradelog.lua` (diagnostic, run alongside)

For the OTHER failure mode: the account **stays in-game** but a trade dies
("trade unexpectedly failed"). That's not a disconnect, so blackbox won't catch
it. Tradelog watches the trade state machine read-only and logs every trade
that closes **without both sides confirmed**.

- **Independent state watcher:** polls `TradeApp:_get_local_trade_state()` itself (re-fetches the app each tick, so it's immune to the `app_cache` stale-swap bug), snapshotting offers + `confirmed` flags + stage every tick a trade is open.
- **On close without completion:** writes a report — partner, **stage it died at**, **`me`/`partner` confirmed flags**, **your offer + partner offer** (labeled pets), **last trade remotes fired** (filtered `__namecall` hook), and **the in-game failure text** if the game printed one.
- **Fail vs cancel:** only tags `FAILED` if an error message appeared near the close; a clean close with no error is `CANCELLED` (off by default via `LOG_CANCELS = false`).
- Output: rolling `<username>_tradefails.log` + one Discord embed per fail. Config: `CONFIG.WEBHOOK.url`, `LOG_CANCELS`, `LOG_REMOTES`, `BUFFER`, `POLL`.

**Reading a report (maps to §6 causes):**
- Died at `confirmation`, `me=true partner=false`, error text present → server rejected on confirm (usually an item you no longer own, or confirm fired too fast).
- Died at `negotiation` → never reached confirm (unneutralized warning popup, or partner never accepted).
- Last remote is a confirm right before the error → confirm-into-wrong-stage; the state-reverify guard (§7.2) fixes it.

**Known limitation:** it logs the pets/UIDs you *offered* but does not hard-assert
ownership (Adopt Me's live-inventory API isn't pinned down here). If reports show
you offering a pet the server rejects and that pet is already gone, wire in a
real inventory check.

---

## 6. Known issues, latent bugs, and "trade unexpectedly failed"

> Diagnose this failure with **`adm_tradelog.lua`** (§5b). The report's stage +
> confirmed-flags + error text point straight at which cause below it is.

### "Trade unexpectedly failed" (in-game client error)
Adopt Me shows this when the trade handshake is rejected server-side. Most
common causes in this system:
- **Offering an item you no longer own** (already traded/aged/gifted away). Re-verify live inventory ownership before offering a UID.
- **Firing an offer/confirm into the wrong stage** or a stale/closed dialog (state mismatch). Always re-read `_get_local_trade_state()` immediately before acting; don't act on cached state.
- **Out-of-order confirm** — confirming before both sides are in `confirmation` and offers are settled.
- **Too-fast action sequences** — back-to-back remote fires with no human-ish delay trip the server's sanity check.

### Error Code 267 (`err_id_02`, "a bug was detected")
Server-side anti-cheat/moderation kick. Either executor detection (blanket) or
an invalid/impossible trade action sequence. Use blackbox to tell which.

### Latent code bugs (present but usually sidestepped by the spin-wait/settings-login flow — fix if refactoring the driver)
- **`app_cache` never re-fetches on a TradeApp instance swap.** If the UI replaces the TradeApp app object, `get_trade_app()` keeps returning the stale one. Should invalidate on swap (same class of bug as the DialogApp re-hook the main loop already does).
- **`pending_partner` via `and/or` ternary** — the `(cond and a) or b` fallback pattern can pick the wrong branch when `a` is falsy. Prefer an explicit `if`.

### Security
- The Discord **webhook URL is in plaintext** in `CONFIG.WEBHOOK.url`. If the repo is public, **regenerate it** and keep it out of version control (untracked config file, or proxy through the existing Cloudflare Worker).

---

## 7. Fixes queued (not yet wired in)

Behavior changes to reduce 267s / "unexpectedly failed", in priority order:
1. **Jittered delays** between every remote fire (`task.wait(math.random(35,90)/100)` between adds; longer before confirm).
2. **Re-verify live state** before every action (kills stale-dialog fires; also fixes the `app_cache` issue).
3. **Ownership gate** before offering a UID.
4. **One action in flight** at a time (serialize the state machine with a lock).
5. **Exponential back-off on kick** (15s → 30s → 60s rejoin) instead of instant rehammer.
6. **Randomize anti-AFK** movement if kicks happen while idle.

---

## 8. Environment / conventions

- **Executor:** Delta (mobile). Executor funcs used: `writefile`/`readfile`/`isfile`/`delfile`, `request`/`http_request`, `hookmetamethod`, `getnamecallmethod`, `newcclosure`, `getgenv`.
- **Hosts:** Android / cloud phones (Redfinger). Shell commands for Redfinger must be **single-line, semicolon-separated** (it pastes one line at a time).
- **Scripts pulled via** `loadstring(game:HttpGet(...))()` from GitHub (`lucivaantarez`). Public repo + optional obfuscation considered for casual-leech protection (not real security).
- **Style:** CONFIG-block-only editing; heavy plain-language comment headers; never break the main loop (everything under pcall).
