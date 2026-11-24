const assert = require('assert');
const { bucket, inScope, channelCount } = require('../site/inbox-counts.js');
const fs = require('fs');
const path = require('path');

const tiktok = (o) => String(o || '').startsWith('tiktok');
const any = () => true;
const email = (o) => o === 'email_hey';

function row(id, extra) {
  return Object.assign({ id: id, origin: 'tiktok_us', is_mmc: false, status: 'open', merged_into: null }, extra);
}

const convs = [
  row('needs'),
  row('replied', { status: 'awaiting_customer' }),
  row('closed', { status: 'resolved' }),
  row('merged', { merged_into: 'needs', status: 'open' }),
  row('uk', { origin: 'tiktok_uk' }),
  row('eu', { origin: 'tiktok_eu' }),
  row('mail', { origin: 'email_hey' }),
  row('mmc', { origin: 'email_hey', is_mmc: true })
];
const state = {
  needs: { bucket: 'inbox' },
  replied: { bucket: 'waiting' },
  closed: { bucket: 'resolved' },
  uk: { bucket: 'inbox' },
  eu: { bucket: 'inbox' },
  mail: { bucket: 'inbox' },
  mmc: { bucket: 'inbox' }
};

assert.strictEqual(bucket(convs[3], null), 'merged');
assert.strictEqual(inScope(convs[3], null, 'inbox', 'needs'), false);
assert.strictEqual(bucket({ status: 'open' }, null), 'inbox');
assert.strictEqual(bucket({ status: 'resolved' }, { bucket: 'inbox' }), 'inbox');

assert.strictEqual(channelCount(convs, state, 'tiktok', 'inbox', 'needs', tiktok), 3);
assert.strictEqual(channelCount(convs, state, 'tiktok', 'inbox', 'replied', tiktok), 1);
assert.strictEqual(channelCount(convs, state, 'tiktok', 'waiting', 'needs', tiktok), 1);
assert.strictEqual(channelCount(convs, state, 'all', 'inbox', 'needs', any), 4);
assert.strictEqual(channelCount(convs, state, 'mmc', 'inbox', 'needs', any), 1);
assert.strictEqual(channelCount(convs, state, 'email', 'inbox', 'needs', email), 1);

const pages = ['inbox', 'waiting', 'resolved', 'junk'];
for (const page of pages) {
  const html = fs.readFileSync(path.join(__dirname, '../site', page, 'index.html'), 'utf8');
  assert.ok(html.includes('/inbox-counts.js'), page + ' loads the shared counter');
  assert.ok(html.includes('EggsyCounts.channelCount'), page + ' sidebar uses the shared counter');
  assert.ok(html.includes('EggsyCounts.inScope'), page + ' list uses the shared filter');
  assert.ok(!html.includes("bucketOf(c)==='inbox'&&(k==='mmc'"), page + ' sidebar does not keep a separate inbox count');
}

console.log('inbox-counts.test.js ok');
