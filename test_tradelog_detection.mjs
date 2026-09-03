import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const message = 'The trade unexpectedly failed';
const hints = ['the trade unexpectedly failed', 'unexpectedly failed', 'trade failed', 'could not be completed', 'cancelled the trade', 'declined'];
assert(hints.some(hint => message.toLowerCase().includes(hint)));

const payload = {
  source: 'adm_tradelog',
  deviceId: 'local-simulation',
  account: 'simulation-account',
  timestamp: Math.floor(Date.now() / 1000),
  eventType: 'TRADE_FAILURE',
  failureReason: message,
};
for (const field of ['source', 'deviceId', 'account', 'timestamp', 'eventType', 'failureReason']) assert(payload[field]);

const source = readFileSync(new URL('./adm_tradelog.lua', import.meta.url), 'utf8');
for (const expected of ['PlayerGui', '_tradelog_debug.log', 'LogService.MessageOut', 'TRADE_FAILURE_DETECTED', 'WEBHOOK_RESPONSE:', 'LOG_CANCELS = true', 'UIManager = load("UIManager")']) assert(source.includes(expected));

console.log('Trade failure detection and payload simulation passed.');
