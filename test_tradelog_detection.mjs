import assert from 'node:assert/strict';

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

console.log('Trade failure detection and payload simulation passed.');
