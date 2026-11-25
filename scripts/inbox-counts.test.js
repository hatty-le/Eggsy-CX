const assert = require('assert');
const { listed, count, regionOf } = require('../site/inbox-counts.js');
const fs = require('fs');
const path = require('path');

function row(id, extra) {
  return Object.assign({ id: id, origin: 'tiktok_us', shop: 'TikTok US', is_mmc: false, status: 'open', merged_into: null }, extra);
}
const convs = [
  row('us1'),
  row('us2', { shop: 'Lucky Egg US' }),
  row('uk1', { origin: 'tiktok_uk', shop: 'TikTok UK' }),
  row('eu-de', { origin: 'tiktok_eu', shop: 'TikTok EU (DE)' }),
  row('shop-only', { origin: 'tiktok', shop: 'TikTok EU (FR)' }),
  row('merged', { origin: 'tiktok_uk', shop: 'TikTok UK', merged_into: 'uk1', status: 'open' }),
  row('mail', { origin: 'email_hey', shop: 'hey@' }),
  row('replied', { origin: 'tiktok_us', status: 'awaiting_customer' })
];
const state = {
  us1: { bucket: 'inbox' },
  us2: { bucket: 'inbox' },
  uk1: { bucket: 'inbox' },
  'eu-de': { bucket: 'inbox' },
  'shop-only': { bucket: 'inbox' },
  mail: { bucket: 'inbox' },
  replied: { bucket: 'waiting' }
};

assert.strictEqual(regionOf(convs[0]), 'tiktok_us');
assert.strictEqual(regionOf(convs[3]), 'tiktok_eu');
assert.strictEqual(regionOf(convs[4]), 'tiktok_eu');
assert.strictEqual(listed(convs[5], null, 'inbox', 'needs', 'tiktok', ''), false);

const opts = ['inbox', 'needs', 'tiktok'];
const all = count(convs, state, opts[0], opts[1], opts[2], '');
const uk = count(convs, state, opts[0], opts[1], opts[2], 'tiktok_uk');
const us = count(convs, state, opts[0], opts[1], opts[2], 'tiktok_us');
const eu = count(convs, state, opts[0], opts[1], opts[2], 'tiktok_eu');
assert.strictEqual(all, 5);
assert.strictEqual(uk + us + eu, all);
assert.strictEqual(us, 2);
assert.strictEqual(uk, 1);
assert.strictEqual(eu, 2);

const list = convs.filter(c => listed(c, state[c.id], 'inbox', 'needs', 'tiktok', ''));
assert.strictEqual(list.length, all);
assert.ok(list.every(c => ['tiktok_uk', 'tiktok_us', 'tiktok_eu'].indexOf(regionOf(c)) >= 0));

const pages = ['inbox', 'waiting', 'resolved', 'junk'];
for (const page of pages) {
  const html = fs.readFileSync(path.join(__dirname, '../site', page, 'index.html'), 'utf8');
  assert.ok(html.includes('EggsyCounts.listed'), page + ' list uses the shared filter');
  assert.ok(html.includes('EggsyCounts.count'), page + ' badge uses the shared count');
}

console.log('inbox-counts.test.js ok');
