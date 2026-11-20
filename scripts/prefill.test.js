/* Replacement prefill checks. Synthetic addresses only — no customer data. */
const assert = require('assert');
const P = require('../site/prefill.js');

function addr(text, hint) {
  const a = P.parseAddress(text, hint);
  assert.ok(a, 'expected an address parse');
  return a;
}

const mixed = addr('Alex\n1 Test Road\nSampletown\nFl 99999\n', 'US');
assert.strictEqual(mixed.province, 'FL');
assert.strictEqual(mixed.zip, '99999');
assert.strictEqual(mixed.countryCode, 'US');
assert.strictEqual(mixed.city, 'Sampletown');
assert.strictEqual(mixed.lastName || '', '');

const lower = addr('1 Test Road\nSampletown\ntx 75001', 'US');
assert.strictEqual(lower.province, 'TX');

const upper = addr('1 Test Road\nSampletown\nTX 75001', 'US');
assert.strictEqual(upper.province, 'TX');

const full = addr('1 Test Road\nSampletown, Florida 99999', 'US');
assert.strictEqual(full.province, 'FL');
assert.strictEqual(full.city, 'Sampletown');

const ny = addr('1 Test Road\nNew York 10001', 'US');
assert.strictEqual(ny.province, 'NY');
assert.strictEqual(ny.zip, '10001');

const sentence = addr('Please send it in 99999', 'US');
assert.strictEqual(sentence.province || '', '');
assert.strictEqual(sentence.zip, '99999');

const uk = addr('1 Test Road\nLondon\nSW1A 1AA', 'GB');
assert.strictEqual(uk.countryCode, 'GB');
assert.strictEqual(uk.zip, 'SW1A 1AA');
assert.strictEqual(uk.province || '', '');

const de = addr('Teststrasse 1\nBerlin 10115', 'DE');
assert.strictEqual(de.countryCode, 'DE');
assert.strictEqual(de.zip, '10115');
assert.strictEqual(de.province || '', '');

const line = '1 / Sketchy Suspects Party Game - Sketch Wacky Criminals Based On Restricted Descriptions! Board Games for Adults & Family - Ages 18+ [ASIN: B0H6XJFHWR]';
const items = P.amazonItems(line);
assert.strictEqual(items.length, 1);
assert.strictEqual(items[0].title, 'Sketchy Suspects');
assert.strictEqual(items[0].asin, 'B0H6XJFHWR');
assert.strictEqual(items[0].seller_sku, '');
assert.strictEqual(items[0].quantity, 1);
assert.strictEqual(items[0].source, 'from conversation');

const pre = P.prefill(
  {origin: 'amazon_us', order_number: '111-0000000-0000000', customer_name: 'Alex'},
  [{direction: 'inbound', body: '1 Test Road\nSampletown\nFl 99999', body_raw: line}]
);
assert.strictEqual(pre.address.province, 'FL');
assert.strictEqual(pre.address.firstName, 'Alex');
assert.strictEqual(pre.address.lastName || '', '');
assert.strictEqual(pre.items[0].title, 'Sketchy Suspects');
assert.strictEqual(pre.items[0].asin, 'B0H6XJFHWR');
assert.strictEqual(pre.items[0].seller_sku, '');

const fromOrder = P.replacementItems([], [{cx_order_items: [{title: 'Sketchy Suspects Party Game', sku: 'B0H6XJFHWR', qty: 1}]}], 'amazon_us');
assert.strictEqual(fromOrder[0].title, 'Sketchy Suspects');
assert.strictEqual(fromOrder[0].asin, 'B0H6XJFHWR');
assert.strictEqual(fromOrder[0].seller_sku, '');

const realSku = P.replacementItems([], [{cx_order_items: [{title: 'Grab The Mic', sku: 'GTM-UK', qty: 2}]}], 'tiktok_uk');
assert.strictEqual(realSku[0].seller_sku, 'GTM-UK');
assert.strictEqual(realSku[0].asin, '');
assert.strictEqual(realSku[0].quantity, 2);

const emailWins = P.replacementItems(
  [{direction: 'inbound', body_raw: line}],
  [{cx_order_items: [{title: 'Grab The Mic', sku: 'GTM-UK', qty: 1}]}],
  'amazon_us'
);
assert.strictEqual(emailWins[0].asin, 'B0H6XJFHWR');
assert.strictEqual(emailWins[0].seller_sku, '');

const shop = P.shopifyItems(
  [{title: 'Sketchy Suspects', sku: 'SS-1', quantity: 1, variant: {id: 'gid://shopify/ProductVariant/1'}}],
  [{title: 'Sketchy Suspects', asin: 'B0H6XJFHWR', seller_sku: '', sources: {asin: 'from conversation'}}],
  'shopify'
);
assert.strictEqual(shop[0].seller_sku, 'SS-1');
assert.strictEqual(shop[0].asin, 'B0H6XJFHWR');
assert.strictEqual(shop[0].variantId, 'gid://shopify/ProductVariant/1');
assert.strictEqual(shop[0].sources.seller_sku, 'from Shopify order');

const mcf = P.shopifyItems(
  [{title: 'Sketchy Suspects', sku: 'SS-1', quantity: 1, variant: {id: 'gid://shopify/ProductVariant/1'}}],
  [{title: 'Sketchy Suspects', asin: 'B0H6XJFHWR', seller_sku: '', sources: {asin: 'from conversation'}}],
  'mcf'
);
assert.strictEqual(mcf[0].seller_sku, '');
assert.strictEqual(mcf[0].asin, 'B0H6XJFHWR');
assert.strictEqual(mcf[0].title, 'Sketchy Suspects');

const asinSku = P.classifySku('b0h6xjfhwr');
assert.strictEqual(asinSku.seller_sku, '');
assert.strictEqual(asinSku.asin, 'B0H6XJFHWR');

const kept = ['Snort Funny', 'Grab The Mic Battle', 'Grab The Mic'].map(P.shortGameTitle);
assert.deepStrictEqual(kept, ['Snort Funny', 'Grab The Mic Battle', 'Grab The Mic']);

console.log('prefill tests passed');
