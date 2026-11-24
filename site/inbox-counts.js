/* Channel badges, shop chips and the conversation list share this filter.
   Needs-reply is the Inbox bucket. "We've replied" is the Waiting bucket.
   Merged tickets are not a bucket: they stay on the ticket they were merged into. */
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

  // mode: inbox | waiting | resolved | junk
  // scope (inbox page only): needs | replied | all
  function inScope(conv, state, mode, scope) {
    if (!conv || conv.merged_into) return false;
    var b = bucket(conv, state);
    if (mode === 'inbox') {
      if (scope === 'replied') return b === 'waiting';
      if (scope === 'all') return b === 'inbox' || b === 'waiting' || b === 'resolved';
      return b === 'inbox';
    }
    return b === mode;
  }

  function channelCount(convs, stateById, key, mode, scope, matchesOrigin) {
    var rows = convs || [];
    var n = 0;
    for (var i = 0; i < rows.length; i++) {
      var c = rows[i];
      var state = stateById ? stateById[c.id] : null;
      if (!inScope(c, state, mode, scope)) continue;
      if (key === 'mmc') {
        if (c.is_mmc) n++;
      } else if (!c.is_mmc && matchesOrigin(c.origin)) n++;
    }
    return n;
  }

  return { bucket: bucket, inScope: inScope, channelCount: channelCount };
});
