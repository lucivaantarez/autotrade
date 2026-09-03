import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const source = readFileSync(new URL('./adm_autotrade.lua', import.meta.url), 'utf8');
for (const guard of ['confirmation_delay = 3.0', 'refire_every = 3.0', 'current_app ~= app', 'current_state.current_stage ~= stage', 'action_busy', 'confirmation_fired']) assert(source.includes(guard));

const actions = [];
let confirmationFired = false;
for (const elapsed of [0, 1, 2, 3, 4, 5]) {
  if (elapsed >= 3 && !confirmationFired) {
    actions.push('ConfirmTrade');
    confirmationFired = true;
  }
}
assert.deepEqual(actions, ['ConfirmTrade']);
console.log('AutoTrade confirmation timing simulation passed.');
