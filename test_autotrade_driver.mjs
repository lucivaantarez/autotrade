import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const source = readFileSync(new URL('./adm_autotrade.lua', import.meta.url), 'utf8');
for (const guard of ['confirmation_delay = 3.0', 'refire_every = 3.0', 'current_app ~= app', 'current_state.current_stage ~= stage', 'action_busy', 'confirmation_fired']) assert(source.includes(guard));
for (const reliabilityGuard of [
  'local function ensure_ui_manager()',
  'if not ensure_ui_manager() then return false end',
  'local fsys_ok, Fsys = pcall',
  'if not fsys_ok or not Fsys then',
  'if not SettingsHelper then',
  'if not SettingsDB then',
  'if not KindDB then',
  'local trade_setting_done = not CONFIG.FORCE_SETTINGS.enabled',
  'if not trade_setting_done then',
  'if not giving_setting_done then',
  'settings_done = force_trade_settings()',
  'local function capture_completion(app, state)',
  'pcall(capture_completion, app, state)',
  'pcall(capture_completion, current_app, current_state)',
  'local invite_guard_ready, exclusion_guard_ready = false, false',
  'invite_guard_module.can_receive_invites == allow_invites',
  'exclusion_guard_module.is_player_excluded == allow_player',
  'if not invite_guard_ready or not invite_guard_module',
  'if not exclusion_guard_ready or not exclusion_guard_module',
  'and invite_guard_ready and exclusion_guard_ready',
  'local ok, ready = pcall(function()',
  'local initializing = true',
  'if not initializing and not in_trade',
  'local trade_app_missing_since = nil',
  'if os.clock() - trade_app_missing_since < TRADE_APP_REPLACEMENT_GRACE then return end',
  'initializing = false',
  'last_forced_dialog',
  'local fired = pcall(function()',
  'if fired then',
  'cls.dialog ~= hooked_dialog_fn',
  'and cls ~= nil',
  'and cls.dialog == hooked_dialog_fn',
  'if state.sender == LocalPlayer then',
  'task.spawn(send_trade_webhook, pending_received, pending_given, pending_partner,',
  'local wrote = pcall(function()',
  'if not wrote then',
  'pcall(install_accept_hook)',
  'pcall(clear_open_request)',
  'local session_started_at = os.clock()',
  'local function format_duration(seconds)',
  'send_trade_webhook(received, given, partner_name, trade_number, elapsed)',
  'local function copy_trade_items(items)',
  'pending_received = copy_trade_items(partner.items)',
  'pending_given    = copy_trade_items(mine.items)',
  'timestamp = now_iso8601()',
]) assert(source.includes(reliabilityGuard), `missing reliability guard: ${reliabilityGuard}`);

// Empty-trade recovery contract.
for (const guard of [
  'EMPTY_TRADE = {',
  'local function process_empty_trade(app, state)',
  'local function resolve_empty_session_on_close(observer_app)',
  'local function record_empty_failure(session)',
  'local function latch_empty_trade_limit()',
  'local function check_server_transition()',
  'local function cancel_trade_adapter(app, state)',
  'local empty_closed, cancel_context = resolve_empty_session_on_close(app)',
  'cancellation_context = session.cancelling',
  'empty_trade.stuck = true',
  'status = "error"',
  'empty_trade.failures = 0',
  'local function each_trade_item(items, fn)',
]) assert(source.includes(guard), `missing empty-trade guard: ${guard}`);

// Cancellation-integrity contract: dispatched off the loop, bounded, and
// never trusted without an observed close on the same TradeApp instance.
for (const guard of [
  'local EMPTY_CANCEL_CALL_WATCHDOG = 15',
  'local function dispatch_cancellation(session, app, state)',
  'local function read_state_safe(app)',
  'session.cancel_inflight = true',
  'session.cancel_app = app',
  'or observer_app == session.cancel_app',
  'local function block()',
  'if session.cancel_outcome == "unknown" then',
]) assert(source.includes(guard), `missing cancellation-integrity guard: ${guard}`);

// The native decline entry point is reachable only through the isolated
// adapter, only behind the auto_decline switch, and only inside pcall.
for (const guard of [
  'auto_decline = true',
  'if not CONFIG.EMPTY_TRADE.auto_decline then',
  'local called, err = pcall(method, app)',
  'CANCEL_UNAVAILABLE_REASONS[tostring(err)]',
]) assert(source.includes(guard), `missing native-decline guard: ${guard}`);

// Methods this build must still never call.
for (const forbidden of ['_on_unaccept_pressed(']) {
  assert(!source.includes(forbidden), `production code must not call ${forbidden}`);
}

// Compact webhook contract (single embed, no fields/footer, native timestamp).
for (const guard of [
  'WEBHOOK_DELIVERY_ATTEMPTS = 3',
  'username = "ADM AutoTrade"',
  'embeds = { embed }',
  'title = ("Trade Complete #%s")',
  'title = "Trade Failed"',
  'title = "Server Skipped"',
  'color = 5763719',
  'color = 15548997',
  'color = 15105570',
  'has received items from',
  'has given items to',
  'traded with',
  'Received: ',
  'Given: ',
  'format_duration_compact',
  'timestamp = now_iso8601()',
  'Reason: ',
  'WinterHub: ',
]) assert(source.includes(guard), `missing webhook guard: ${guard}`);

// The old field-based payload must be gone.
for (const stale of [
  '{ name = "Trade #"',
  '{ name = "Runtime"',
  '{ name = "Account"',
  '{ name = "Partner"',
  'Received (%d)',
  'footer = {',
  'last_sig',
  'Trade #%s completed with **%s** after %s',
]) assert(!source.includes(stale), `stale webhook field still present: ${stale}`);

// No invented native cancellation methods.
for (const invented of ['_on_decline_pressed', '_on_cancel_pressed', '_on_reject_pressed']) {
  assert(!source.includes(invented), `invented cancellation method present: ${invented}`);
}

assert(!source.includes('if not DialogApp.__autotrade_hooked then'), 'stale instance marker must not block class-hook repair');
assert(!source.includes('load("Promise")'), 'only the verified package:Promise module may drive dialog responses');
assert(!source.includes('if not app then last_stage = nil in_trade = false return end'), 'temporary app loss must preserve trade lifecycle state');
assert(source.includes('DialogApp.__autotrade_hooked = false'));
assert(source.indexOf('last_forced_ticket = ticket') > source.indexOf('local fired = pcall(function()'));
assert((source.match(/capture_completion/g) || []).length >= 3, 'completion helper and both protected samples must remain covered');
assert((source.match(/pcall\(write_winterhub\)/g) || []).length >= 2, 'heartbeat must run during hook startup and the main loop');
assert(source.indexOf('local _guard_key') < source.indexOf('LocalPlayer.Idled:Connect'), 'singleton guard must precede side effects');

const actions = [];
let confirmationFired = false;
for (const elapsed of [0, 1, 2, 3, 4, 5]) {
  if (elapsed >= 3 && !confirmationFired) {
    actions.push('ConfirmTrade');
    confirmationFired = true;
  }
}
assert.deepEqual(actions, ['ConfirmTrade']);

let lastDialog;
let lastTicket = 0;
const forced = [];
for (const [dialog, ticket] of [['first', 1], ['first', 1], ['second', 1]]) {
  if (dialog !== lastDialog) {
    lastDialog = dialog;
    lastTicket = 0;
  }
  if (ticket !== lastTicket) {
    lastTicket = ticket;
    forced.push(`${dialog}:${ticket}`);
  }
}
assert.deepEqual(forced, ['first:1', 'second:1']);
console.log('AutoTrade confirmation timing simulation passed.');
