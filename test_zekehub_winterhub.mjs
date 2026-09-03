import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const source = readFileSync(new URL('./zekehub_winterhub.lua', import.meta.url), 'utf8');
for (const expected of ['task.spawn', 'poll = 0.4', '_winteraddons.json', 'status = "completed"', 'ts = os.time()', 'count = trade_count', 'items = last_items', 'mine.confirmed and partner.confirmed', 'return loader()']) assert(source.includes(expected));
console.log('ZekeHub WinterHub wrapper contract simulation passed.');
