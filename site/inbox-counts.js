/* One filter for the channel badge, the region chips, and the conversation list.
   A ticket the badge counts is in the All list, and in exactly one region chip. */
(function (root, factory) {
  var api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.EggsyCounts = api;
})(typeof window !== 'undefined' ? window : globalThis, function () {
  function bucket(conv, state) {
    if (conv && conv.merged_into) return 'merged';
    if (state && state.bucket) return state.bucket;
    var status = conv && conv.status;
    if (status === 'ignored') return 'junk';
    if (status === 'resolved') return 'resolved';
    if (status === 'awaiting_customer') return 'waiting';
    return 'inbox';
  }

  // TikTok region from the origin code, then from the shop name.
  // "TikTok EU (DE)" is EU. A bare tiktok origin still lands on a region.
  function regionOf(conv) {
    var o = String((conv && conv.origin) || '');
    if (o === 'tiktok_uk' || o === 'tiktok_us' || o === 'tiktok_eu') return o;
    var shop = String((conv && conv.shop) || '');
    var blob = (o + ' ' + shop).toLowerCase();
    if (blob.indexOf('tiktok') < 0) return o;
    if (/\buk\b|united kingdom/.test(blob)) return 'tiktok_uk';
    if (/\busa\b|\bus\b|united states/.test(blob)) return 'tiktok_us';
    if (/\beu\b|germany|\bde\b|france|\bfr\b|italy|\bit\b|spain|\bes\b/.test(blob)) return 'tiktok_eu';
    if (o.indexOf('tiktok') === 0) return 'tiktok_uk';
    return o;
  }

  function inGroup(conv, group) {
    if (!conv) return false;
    if (group === 'mmc') return !!conv.is_mmc;
    if (conv.is_mmc) return false;
    var o = String(conv.origin || '');
    if (!group || group === 'all') return true;
    if (group === 'email') return o === 'email_hey';
    if (group === 'forms') return o === 'shopify_form' || o === 'wix_mmc_form';
    if (group === 'amazon') return o.indexOf('amazon') === 0;
    if (group === 'walmart') return o === 'walmart';
    if (group === 'meta') return o === 'facebook' || o === 'instagram';
    if (group === 'tiktok') return o.indexOf('tiktok') === 0 || String(regionOf(conv)).indexOf('tiktok_') === 0;
    return true;
  }

  function inBucket(conv, state, mode, scope) {
    if (!conv || conv.merged_into) return false;
    var b = bucket(conv, state);
    if (mode === 'inbox') {
      if (scope === 'replied') return b === 'waiting';
      if (scope === 'all') return b === 'inbox' || b === 'waiting' || b === 'resolved';
      return b === 'inbox';
    }
    return b === mode;
  }

  // region '' is All. Otherwise the ticket must map to that region.
  function listed(conv, state, mode, scope, group, region) {
    if (!inBucket(conv, state, mode, scope)) return false;
    if (!inGroup(conv, group)) return false;
    if (region && regionOf(conv) !== region) return false;
    return true;
  }

  function count(convs, stateById, mode, scope, group, region) {
    var rows = convs || [];
    var n = 0;
    for (var i = 0; i < rows.length; i++) {
      var c = rows[i];
      if (listed(c, stateById ? stateById[c.id] : null, mode, scope, group, region || '')) n++;
    }
    return n;
  }

  // Kept so older call sites still compile. Region chips pass the origin code as key.
  function channelCount(convs, stateById, key, mode, scope, matchesOrigin) {
    if (key === 'tiktok_uk' || key === 'tiktok_us' || key === 'tiktok_eu') {
      return count(convs, stateById, mode, scope, 'tiktok', key);
    }
    return count(convs, stateById, mode, scope, key, '');
  }

  return {
    bucket: bucket,
    regionOf: regionOf,
    inGroup: inGroup,
    inBucket: inBucket,
    listed: listed,
    count: count,
    channelCount: channelCount,
    inScope: function (conv, state, mode, scope) { return inBucket(conv, state, mode, scope); }
  };
});
