import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const root = new URL('./gemstone/', import.meta.url);
const files = readdirSync(root).filter((name) => name.endsWith('.lua'));
assert.equal(files.length, 7, 'all gemstone modules should exist');
for (const file of files) {
  const source = readFileSync(new URL(file, root), 'utf8');
  assert.ok(source.includes('return'), `${file} must be a Lua module`);
  for (const forbidden of ['VirtualInputManager', 'hookmetamethod', 'FireServer', 'InvokeServer', 'getgenv']) {
    assert.equal(source.includes(forbidden), false, `${file} must not perform live exploit operations`);
  }
}

class MockAccount {
  constructor({ claimed = false, slow = false, unexpected = false, delayed = false, partial = false, missingReward = false, verifyFail = false } = {}) {
    this.ready = !slow;
    this.claimed = claimed;
    this.slow = slow;
    this.unexpected = unexpected;
    this.delayed = delayed;
    this.partial = partial;
    this.missingReward = missingReward;
    this.verifyFail = verifyFail;
    this.screen = 'play';
    this.inGame = false;
    this.steps = 0;
    this.claims = 0;
    this.writes = new Map();
    this.state = { username: 'mock_account', stars: 26, gemstone_progress: '26/28', gemstone_price: 28, daily_streak: 4, claim_eligible: !claimed };
  }
  tick() { this.steps++; if (this.slow && this.steps >= 3) this.ready = true; }
  startup() {
    if (!this.ready) return false;
    if (this.unexpected) throw new Error('unexpected_dialog');
    this.screen = 'none'; this.inGame = true; return true;
  }
  claim() {
    if (this.claimed || this.claims) return false;
    this.claims++;
    if (!this.verifyFail) {
      if (this.delayed) this.statePending = true;
      else this.applyClaim();
    }
    return true;
  }
  applyClaim() {
    this.state.gemstone_progress = this.partial ? undefined : '27/28';
    this.state.stars = this.partial ? undefined : 27;
    this.state.claim_eligible = false;
    this.claimed = true;
  }
  read() {
    if (this.missingReward) return null;
    if (this.statePending) { this.applyClaim(); this.statePending = false; }
    return { ...this.state };
  }
}

function inspect(account) {
  const raw = account.read();
  if (!raw || !raw.username) return { status: 'UNAVAILABLE' };
  const [progress, target] = String(raw.gemstone_progress ?? '').split('/').map(Number);
  return { status: 'VERIFIED', raw, progress, target, stars: raw.stars, price: raw.gemstone_price };
}
function verify(before, after) {
  const changed = (after.progress > before.progress) || (before.raw.claim_eligible === true && after.raw.claim_eligible === false) || (after.stars > before.stars);
  return { verified: changed, status: changed ? 'VERIFIED' : 'FAILED' };
}
function run(account) {
  const result = { username: 'mock_account', startup_state: 'BOOTING', game_ready: false, daily_claim: { status: 'UNKNOWN', attempted: false, verified: false }, statistics_saved: false, swap: { eligible: false, signal_written: false } };
  try {
    if (account.inGame) result.game_ready = true;
    for (let i = 0; i < 8 && !account.inGame; i++) {
      account.tick();
      if (account.startup()) result.game_ready = true;
    }
  } catch (error) {
    result.status = 'FAILED'; result.error = error.message; return result;
  }
  result.startup_state = result.game_ready ? 'IN_GAME' : 'FAILED';
  if (!result.game_ready) { result.status = 'FAILED'; return result; }
  const before = inspect(account);
  if (before.status !== 'VERIFIED') { result.status = 'FAILED'; return result; }
  if (before.raw.claim_eligible === false) {
    result.daily_claim = { status: 'VERIFIED', attempted: false, verified: true, reason: 'already claimed' };
  } else {
    const attempted = account.claim();
    const after = inspect(account);
    const verification = verify(before, after);
    result.daily_claim = { ...verification, attempted };
  }
  const final = inspect(account);
  result.stars = final.stars;
  result.gemstone = { progress: final.progress, target: final.target, price: final.price, purchased: false };
  result.statistics_saved = true;
  const statsComplete = [result.stars, result.gemstone.progress, result.gemstone.target, result.gemstone.price].every((value) => Number.isFinite(value));
  result.status = result.daily_claim.verified && statsComplete ? 'COMPLETED' : 'FAILED';
  result.verification_status = result.daily_claim.verified && statsComplete ? 'VERIFIED' : (result.daily_claim.verified ? 'BLOCKED' : 'FAILED');
  if (result.status === 'COMPLETED' && result.statistics_saved) {
    result.swap = { eligible: true, signal_written: true };
    account.writes.set('mock_account_winterswap.json', { group: 'finished', ts: Math.floor(Date.now() / 1000) });
  }
  return result;
}

const cases = [
  ['already claimed', new MockAccount({ claimed: true }), 'COMPLETED'],
  ['unclaimed', new MockAccount(), 'COMPLETED'],
  ['slow startup', new MockAccount({ slow: true }), 'COMPLETED'],
  ['unexpected dialog', new MockAccount({ unexpected: true }), 'FAILED'],
  ['missing reward GUI', new MockAccount({ missingReward: true }), 'FAILED'],
  ['delayed update', new MockAccount({ delayed: true }), 'COMPLETED'],
  ['failed verification', new MockAccount({ verifyFail: true }), 'FAILED'],
  ['partial data', new MockAccount({ partial: true }), 'FAILED'],
];
for (const [name, account, expected] of cases) {
  const result = run(account);
  assert.equal(result.status, expected, name);
  if (expected === 'COMPLETED') {
    assert.equal(result.swap.signal_written, true, `${name}: swap signal`);
    assert.equal(account.claims <= 1, true, `${name}: duplicate claim prevention`);
  } else {
    assert.equal(result.swap.signal_written, false, `${name}: no premature swap`);
  }
}

const duplicate = new MockAccount();
const first = run(duplicate);
const second = run(duplicate);
assert.equal(first.status, 'COMPLETED');
assert.equal(second.status, 'COMPLETED');
assert.equal(duplicate.claims, 1, 're-running must not claim twice');

console.log(`Gemstone deterministic simulation passed (${cases.length + 1} scenarios).`);
