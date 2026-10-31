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

1. **CONFIG** — on/off switches: `MASTER_ENABLED`, `FORCE_SETTINGS`, `AUTO_ACCEPT` (`poll`, `refire_every`), `EMPTY_TRADE` (`timeout_seconds`, `max_consecutive_failures`), `WINTERHUB` (`idle_hop_seconds`, `heartbeat`), `WEBHOOK` (`url`, `report`), `DEBUG`.
2. **SETUP** — anti-AFK (VirtualUser on `Idled`); **per-account singleton guard** keyed on `getgenv()["__adm_autotrade_" .. UserId]` (two Delta clones share one env, so a plain global would abort clone 2 — keying on UserId lets each account run but blocks a true double-execute on the same account). A failed `Fsys` bootstrap releases that guard so the script can be retried. Loads `UIManager` eagerly and retries it if startup was too early; loads `SettingsHelper`/`SettingsDB`/`KindDB` lazily and independently *after* the hook is in, retrying any dependency that was unavailable during partial startup (getting the accept hook in fast prevents the first-request race).
3. **FORCE SETTINGS** — trade/give → Everyone.
4. **AUTO-ACCEPT** — installs the `DialogApp.dialog` hook (short-circuits `trade_request` with a resolved `"Accept"` promise) + patches TradeApp popups. `clear_open_request()` handles a dialog already waiting at startup.
5. **TRADE DRIVER** (`step_trade`) — reads state, caches offers at confirmation, delays and revalidates each action, retries negotiation conservatively, confirms once per confirmation stage, samples completion both before and immediately after confirm, bumps `trade_count`, triggers webhook + updates `last_items`. A transient TradeApp replacement preserves the lifecycle for a short grace period; if the app never returns, stale state is cleared so WinterHub cannot remain active forever. Empty-partner-offer recovery runs first: one 15s deadline per session, UNKNOWN ≠ EMPTY, a fresh read at the boundary, and at most one failure record per session.
6. **WINTERHUB** (`write_winterhub`) — writes the status file on a heartbeat (see contract below); failed writes remain immediately retryable. Three consecutive empty-offer failures latch `completed` until the server changes. If cancellation is unavailable, a stuck empty trade reports `error` (rejoin same server) rather than freezing or faking completion.
7. **MAIN LOOP** — spin-waits to install the hook the instant `apps` exist while continuing an `active` WinterHub heartbeat; re-verifies the dialog class/method and invite guards each poll; retries settings after the hook attempt without suppressing them forever if the hook is unavailable; protects hook repair, startup-dialog recovery, trade stepping, and heartbeat writes so one transient error cannot kill the loop.
8. **WEBHOOK** — one compact Discord embed per event: `Trade Complete #N` (green), `Trade Failed` (red), `Server Skipped` (amber). No fields, no footer, native timestamp, short multiline description. `CONFIG.WEBHOOK.report` selects received/given/both item lines; item names and quantities are preserved. Delivery validates 2xx, retries 429/5xx/missing-status up to three times, never retries other 4xx, and dedupes by stable event id. Trade success, HTTP delivery, and WinterHub status writing are separate outcomes.

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
- Exception: after three consecutive confirmed empty-offer failures, `completed` is latched (`empty_trade_limit`) until the server changes. Do not revert it to `active` on later heartbeats; keep `count` and `items` truthful.
- `error` is also used when an empty trade cannot be cancelled because no verified native cancellation API is available. That means "rejoin this server", never "trade completed".
- `ts` must keep refreshing even during hook startup and when idle — a background heartbeat, or the agent thinks the account froze and relaunches it. Do not advance the local heartbeat timer unless the status write succeeded.
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
- **Fail vs cancel:** only tags `FAILED` if an error message appeared near the close; a clean close with no error is `CANCELLED` (currently enabled via `LOG_CANCELS = true` so incomplete closes are preserved).
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

### Reliability guards already enforced
- **TradeApp instance swaps:** `get_trade_app()` re-fetches `UIManager.apps.TradeApp` and patches each replacement instead of retaining a stale object.
- **DialogApp instance swaps:** startup-ticket deduplication is scoped to the current DialogApp instance, and the class hook is not wrapped repeatedly when only the instance changes. Invite/exclusion overrides are identity-checked and restored if another script replaces them.
- **Startup-dialog recovery:** a failed forced response remains retryable, and a successful response marks activity before WinterHub can consider hopping.
- **Partial dependency startup:** `SettingsHelper`, `SettingsDB`, and `KindDB` load independently and missing modules are retried; settings are not marked complete until both configured updates succeed, while an already-successful setting is not sent repeatedly.
- **Bootstrap recovery:** an initial `UIManager` miss is retried, and an `Fsys` load failure clears the per-account singleton guard before reporting the error.
- **Partner selection:** completion tracking uses an explicit sender/recipient branch rather than an `and/or` pseudo-ternary.
- **Heartbeat isolation:** completion webhooks run asynchronously so a slow endpoint cannot block WinterHub status refreshes.
- **Heartbeat delivery:** startup emits `active`, continues heartbeat writes during the hook spin, and retries failed file writes without waiting a full heartbeat interval.
- **Completion sampling:** offer confirmation is captured before and immediately after the confirm handler, reducing missed accounting when the trade closes between polls.

### Empty-offer recovery (V2)
- One 15s deadline per trade session. It starts when the session is first observed and never restarts on a 0.4s poll. It is not a maximum trade duration.
- Partner offers are counted with `pairs`, so both sequential arrays and UID-keyed dictionaries work. **Every present entry counts as an item**, whatever its shape: the live diagnostic counted the real offer as 0 → 1 → 2 while the old predicate required `kind`/`id`/`uid`, which could read a populated offer as zero and cancel it. A nil/unreadable offer is `UNKNOWN`, never `EMPTY`.
- Once any partner item is observed, the empty countdown is permanently satisfied for that session. Inserting then removing an item must not cancel or fake a success.
- At the deadline the script re-reads the app, state, and offer. It never cancels from stale poll data, and a throwing state getter is `UNKNOWN`, not a close.
- The cancellation adapter is dispatched in a spawned task. A yielding or never-returning call cannot suspend the trade loop or the WinterHub heartbeat; a per-session in-flight flag prevents overlapping calls, and a 15s watchdog converts an unsettled call into outcome `unknown`.
- Outcome states are `requested`, `unavailable`, `failed`, and `unknown`. None means "cancelled". A failure is recorded only after the window is observed closed by the **same** TradeApp instance within the 5s window; a replacement instance, a missing app, or a failed read is never proof of closure.
- While the outcome is unresolved, accept/confirm is blocked and cached completions are dropped — an `UNKNOWN` offer read is not permission to act.
- If the partner's offer becomes readable and populated, the session's cancellation bookkeeping is dropped and normal trading resumes, so a genuine later completion is still counted and reported. The counter increments at most once per session; a successful trade resets it; server JobId change resets it. TradeApp disappearance does not reset it.
- Three consecutive failures latch WinterHub `completed`, stop new accepts, and dispatch one Server Skipped event after a successful status write. The dispatch is asynchronous; local suppression is not server-enforced exactly-once delivery.
- **Native cancellation (wired, contract unverified):** `TradeApp._decline_trade` is observed to exist in the live client. With `CONFIG.EMPTY_TRADE.auto_decline = true` the adapter calls it with no extra arguments once the 15s deadline passes on a readable-empty offer, because its parameter list is unknown and a guessed argument is worse than a call that simply does nothing. Its return value is ignored: the call is a request, and only an observed close on the same TradeApp instance records a failure. If it throws, is missing, or the window stays open, nothing is counted and WinterHub receives `error` (same-server rejoin). Do not invent `_on_cancel_pressed` or arbitrary remotes. Set `auto_decline = false` to restore the previous no-call behaviour.

### Security
- The Discord **webhook URL is in plaintext** in `CONFIG.WEBHOOK.url`. If the repo is public, **regenerate it** and keep it out of version control (untracked config file, or proxy through the existing Cloudflare Worker).

---

## 7. Failure-prevention fixes

Behavior changes to reduce 267s / "unexpectedly failed":
1. **Delayed actions** after stage transitions, with a longer settling delay before confirm.
2. **Re-verify live state** before every action and refresh swapped `TradeApp` instances.
3. **One action in flight** at a time; confirmation fires once per confirmation stage.

Still queued if diagnostics show they are needed:
4. **Verified native cancellation API** for empty trades (the adapter is intentionally blocked until one is confirmed).
5. **Ownership gate** before offering a UID.
6. **Exponential back-off on kick** (15s → 30s → 60s rejoin) instead of instant rehammer.
7. **Randomize anti-AFK** movement if kicks happen while idle.

---

## 8. Environment / conventions

- **Executor:** Delta (mobile). Executor funcs used: `writefile`/`readfile`/`isfile`/`delfile`, `request`/`http_request`, `hookmetamethod`, `getnamecallmethod`, `newcclosure`, `getgenv`.
- **Hosts:** Android / cloud phones (Redfinger). Shell commands for Redfinger must be **single-line, semicolon-separated** (it pastes one line at a time).
- **Scripts pulled via** `loadstring(game:HttpGet(...))()` from GitHub (`lucivaantarez`). Public repo + optional obfuscation considered for casual-leech protection (not real security).
- **Style:** CONFIG-block-only editing; heavy plain-language comment headers; never break the main loop (everything under pcall).
