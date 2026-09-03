import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const source = readFileSync(new URL('./zekehub_winterhub.lua', import.meta.url), 'utf8');
for (const expected of ['getgenv().scriptkey = getgenv().scriptkey or ""', 'PASTE YOUR ZEKEHUB KEY', 'WINTERHUB_WEBHOOK_URL', 'send_trade_webhook(last_items)', 'AutoAcceptTrades = true', 'AutoLeaveAfterTrades = false', 'AccountManager = {', 'task.spawn', 'Poll = 0.4', 'utility.WinterHub', 'ForceSettings', 'force_everyone("trade_requests")', 'force_everyone("give_item_requests")', '_winteraddons.json', 'status = "completed"', 'ts = os.time()', 'count = trade_count', 'items = last_items', 'mine.confirmed and partner.confirmed', 'return loader()']) assert(source.includes(expected));
console.log('ZekeHub WinterHub wrapper contract simulation passed.');
