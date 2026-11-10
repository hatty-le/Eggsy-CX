/* Prefill helpers for the replacement forms. No logging. */
(function (root) {
  var COUNTRY = {
    'united kingdom': 'GB', uk: 'GB', 'great britain': 'GB', england: 'GB', scotland: 'GB', wales: 'GB', 'northern ireland': 'GB',
    'united states': 'US', 'united states of america': 'US', usa: 'US', 'u.s.a': 'US', 'u.s': 'US',
    canada: 'CA', australia: 'AU',
    germany: 'DE', deutschland: 'DE', france: 'FR', italy: 'IT', italia: 'IT', spain: 'ES', netherlands: 'NL', holland: 'NL',
    belgium: 'BE', sweden: 'SE', poland: 'PL', ireland: 'IE', austria: 'AT'
  };
  var US_STATE = {AL:1,AK:1,AZ:1,AR:1,CA:1,CO:1,CT:1,DE:1,DC:1,FL:1,GA:1,HI:1,ID:1,IL:1,IN:1,IA:1,KS:1,KY:1,LA:1,ME:1,MD:1,MA:1,MI:1,MN:1,MS:1,MO:1,MT:1,NE:1,NV:1,NH:1,NJ:1,NM:1,NY:1,NC:1,ND:1,OH:1,OK:1,OR:1,PA:1,RI:1,SC:1,SD:1,TN:1,TX:1,UT:1,VT:1,VA:1,WA:1,WV:1,WI:1,WY:1};
  var ORIGIN_COUNTRY = {
    amazon_uk: 'GB', tiktok_uk: 'GB', amazon_us: 'US', tiktok_us: 'US', walmart: 'US',
    amazon_de: 'DE', amazon_fr: 'FR', amazon_it: 'IT', amazon_es: 'ES', amazon_nl: 'NL',
    amazon_se: 'SE', amazon_pl: 'PL', amazon_be: 'BE'
  };
  var COUNTRY_MARKET = {US:'US',CA:'CA',AU:'AU',GB:'UK',UK:'UK',DE:'DE',AT:'DE',FR:'FR',IT:'IT',ES:'ES',NL:'NL',BE:'BE',SE:'SE',PL:'PL',IE:'UK'};
  var ORIGIN_MARKET = {
    amazon_us:'US', tiktok_us:'US', walmart:'US', amazon_uk:'UK', tiktok_uk:'UK',
    amazon_de:'DE', amazon_fr:'FR', amazon_it:'IT', amazon_es:'ES', amazon_nl:'NL',
    amazon_se:'SE', amazon_pl:'PL', amazon_be:'BE'
  };

  function normCountry(v) {
    var s = String(v || '').trim().toLowerCase().replace(/\./g, '');
    if (!s) return '';
    if (COUNTRY[s]) return COUNTRY[s];
    if (/^[a-z]{2}$/.test(s)) return s.toUpperCase();
    return '';
  }
  function splitName(full) {
    var s = String(full || '').replace(/\s+/g, ' ').trim();
    if (!s || /@/.test(s) || /^https?:/i.test(s) || /\d/.test(s)) return {firstName:'', lastName:''};
    if (s.indexOf(',') > 0) {
      var bits = s.split(',');
      var last = bits[0].trim(), first = bits.slice(1).join(' ').trim();
      if (first && last && last.indexOf(' ') < 0) return {firstName: first.split(' ')[0], lastName: last};
    }
    var parts = s.split(' ').filter(function (p) { return !/^(mr|mrs|ms|miss|mx|dr)\.?$/i.test(p); });
    if (!parts.length) return {firstName:'', lastName:''};
    if (parts.length === 1) return {firstName: parts[0], lastName:''};
    return {firstName: parts[0], lastName: parts.slice(1).join(' ')};
  }
  function countryFromOrigin(origin) { return ORIGIN_COUNTRY[origin] || ''; }
  function marketFor(origin, countryCode) {
    var cc = normCountry(countryCode) || String(countryCode || '').toUpperCase();
    if (ORIGIN_MARKET[origin]) return ORIGIN_MARKET[origin];
    if (COUNTRY_MARKET[cc]) return COUNTRY_MARKET[cc];
    return 'UK';
  }
  function chatter(line) {
    var l = line.toLowerCase();
    if (line.length > 80 || /\?/.test(line)) return true;
    if (/^(hi|hello|hey|thanks|thank you|please|dear|kind regards|regards|cheers|order|i |i'm|im |we |my |the |this |that |can |could |would |just |sorry|sent from)\b/.test(l)) return true;
    if ((line.match(/\s/g) || []).length > 8) return true;
    return false;
  }
  function looksName(line) {
    return /^[A-Z][\p{L}'-]+(?:\s+[A-Z][\p{L}'-]+){1,3}$/u.test(line) && !/\d/.test(line);
  }
  function findCode(text, hint) {
    var uk = text.match(/\b([A-Z]{1,2}\d[A-Z\d]?)\s*(\d[A-Z]{2})\b/i);
    if (uk) return {zip: (uk[1] + ' ' + uk[2]).toUpperCase().replace(/\s+/, ' '), country: 'GB', raw: uk[0], index: uk.index};
    var ca = text.match(/\b([A-Z]\d[A-Z])\s*(\d[A-Z]\d)\b/i);
    if (ca) return {zip: (ca[1] + ' ' + ca[2]).toUpperCase(), country: 'CA', raw: ca[0], index: ca.index};
    var us = text.match(/\b([A-Z]{2})\s+(\d{5})(?:-\d{4})?\b/);
    if (us && US_STATE[us[1]] && hint !== 'DE') return {zip: us[2], province: us[1], country: 'US', raw: us[0], index: us.index};
    var word = '';
    Object.keys(COUNTRY).forEach(function (name) {
      var re = new RegExp('\\b' + name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\b', 'i');
      if (re.test(text)) word = COUNTRY[name];
    });
    var cc = word || hint || '';
    if (cc === 'DE' || cc === 'FR' || cc === 'IT' || cc === 'ES' || cc === 'SE' || cc === 'PL' || cc === 'AT') {
      var five = text.match(/(^|[^\d])(\d{5})(?!\d)/);
      if (five) return {zip: five[2], country: cc, raw: five[2], index: five.index + five[1].length};
    }
    if (cc === 'AU') {
      var four = text.match(/(^|[^\d])(\d{4})(?!\d)/);
      if (four) return {zip: four[2], country: 'AU', raw: four[2], index: four.index + four[1].length};
    }
    if (cc === 'NL') {
      var nl = text.match(/\b(\d{4})\s*([A-Z]{2})\b/);
      if (nl) return {zip: nl[1] + ' ' + nl[2].toUpperCase(), country: 'NL', raw: nl[0], index: nl.index};
    }
    if (cc === 'US') {
      var zip = text.match(/(^|[^\d-])(\d{5})(?:-\d{4})?(?!\d)/);
      if (zip) return {zip: zip[2], country: 'US', raw: zip[2], index: zip.index + zip[1].length};
    }
    return null;
  }
  function phoneNear(text) {
    var m = text.match(/(?:\+44\s?7\d{3}|\(?07\d{3}\)?)[\s-]?\d{3}[\s-]?\d{3}/) ||
      text.match(/(?:\+1[\s.-]?)?(?:\(\d{3}\)|\d{3})[\s.-]\d{3}[\s.-]\d{4}/);
    return m ? m[0].replace(/\s+/g, ' ').trim() : '';
  }
  function parseAddress(text, hintCountry) {
    if (!text) return null;
    var raw = String(text).replace(/\r/g, '').replace(/[ \t]+/g, ' ');
    var hint = normCountry(hintCountry);
    var code = findCode(raw, hint);
    if (!code) return null;
    var lines = raw.split('\n').map(function (l) { return l.trim(); }).filter(Boolean);
    var idx = -1;
    for (var i = 0; i < lines.length; i++) if (lines[i].indexOf(code.raw) >= 0 || lines[i].toUpperCase().indexOf(code.zip) >= 0) idx = i;
    if (idx < 0) idx = lines.length - 1;
    var above = [];
    for (var j = idx - 1; j >= 0 && above.length < 5; j--) {
      if (!lines[j] || chatter(lines[j])) break;
      above.unshift(lines[j]);
    }
    var postLine = lines[idx].replace(code.raw, '').replace(code.zip, '').replace(/[, ]+$/g, '').replace(/^[, ]+/g, '').trim();
    var out = {zip: code.zip, countryCode: code.country, province: code.province || ''};
    var city = '';
    if (postLine && !/^\d/.test(postLine)) {
      var cityBits = postLine.split(',');
      city = cityBits[0].trim();
      if (!out.province && cityBits[1] && /^[A-Z]{2}$/.test(cityBits[1].trim()) && US_STATE[cityBits[1].trim()]) out.province = cityBits[1].trim();
    }
    function isUnit(line) { return /^(apt|apartment|flat|unit|suite|ste|#)\b/i.test(line); }
    var numbered = above.filter(function (l) { return /\d/.test(l) && /[A-Za-z]/.test(l); });
    var plain = above.filter(function (l) { return numbered.indexOf(l) < 0 && !normCountry(l); });
    if (numbered.length) {
      var units = numbered.filter(isUnit);
      var streets = numbered.filter(function (l) { return !isUnit(l); });
      out.address1 = streets.length ? streets[streets.length - 1] : numbered[numbered.length - 1];
      if (units.length) out.address2 = units.join(', ');
      else if (streets.length > 1) out.address2 = streets.slice(0, -1).join(', ');
    }
    if (!city && plain.length) city = plain[plain.length - 1];
    if (city && (normCountry(city) || chatter(city) || /\d/.test(city))) city = '';
    if (!out.address1 && /,/.test(lines[idx])) {
      var cleaned = lines[idx].replace(/^.*\b(address is|send (it |this )?to|deliver to|ship to):?\s*/i, '').replace(code.raw, '').replace(code.zip, '');
      var parts = cleaned.split(',').map(function (s) { return s.trim(); }).filter(Boolean);
      var street = parts.filter(function (p) { return /\d/.test(p) && /[A-Za-z]/.test(p); });
      var cities = parts.filter(function (p) { return !/\d/.test(p) && !normCountry(p) && !chatter(p); });
      if (street.length) out.address1 = street[0];
      if (!city && cities.length) city = cities[cities.length - 1];
    }
    if (city) out.city = city.replace(/,/g, '').trim();
    var nameLine = plain.filter(looksName)[0] || above.filter(looksName)[0];
    if (nameLine) {
      var nm = splitName(nameLine);
      out.firstName = nm.firstName; out.lastName = nm.lastName;
    }
    var ph = phoneNear(raw);
    if (ph) out.phone = ph;
    if (out.countryCode === 'US' && !out.province) {
      var st = raw.match(/\b([A-Z]{2})\s+\d{5}\b/);
      if (st && US_STATE[st[1]]) out.province = st[1];
    }
    return out;
  }
  function orderIdFromText(text) {
    var amz = String(text || '').match(/\b\d{3}-\d{7}-\d{7}\b/);
    if (amz) return amz[0];
    var hash = String(text || '').match(/#(\d{3,8})\b/);
    if (hash) return '#' + hash[1];
    return '';
  }
  function put(out, key, value, source, intoAddress) {
    if (value == null || value === '') return;
    var bag = intoAddress ? out.address : out;
    var srcKey = intoAddress ? key : key;
    if (bag[key]) return;
    bag[key] = value;
    out.sources[srcKey] = source;
  }
  function prefill(conv, messages) {
    conv = conv || {};
    var out = {address: {}, sources: {}, shipping_speed: 'Standard', plain_packaging: true};
    var shopCountry = countryFromOrigin(conv.origin);
    if (conv.order_number) { out.original_order_id = String(conv.order_number).trim(); out.sources.original_order_id = 'from the ticket'; }
    var name = splitName(conv.customer_name);
    if (name.firstName) { out.address.firstName = name.firstName; out.sources.firstName = 'from the ticket'; }
    if (name.lastName) { out.address.lastName = name.lastName; out.sources.lastName = 'from the ticket'; }
    if (shopCountry) { out.address.countryCode = shopCountry; out.sources.countryCode = 'from the ticket'; }
    out.marketplace = marketFor(conv.origin, out.address.countryCode);
    out.sources.marketplace = 'from the ticket';
    var inbound = (messages || []).filter(function (m) {
      return m && m.direction === 'inbound' && m.body && !/^\[Summary by Eggsy/.test(m.body);
    }).slice().sort(function (a, b) { return new Date(b.sent_at) - new Date(a.sent_at); });
    var parsed = null;
    for (var i = 0; i < inbound.length && !parsed; i++) {
      var primary = parseAddress(inbound[i].body, shopCountry);
      var secondary = inbound[i].body_en && inbound[i].body_en !== inbound[i].body ? parseAddress(inbound[i].body_en, shopCountry) : null;
      parsed = (primary && primary.zip) ? primary : secondary;
    }
    if (parsed) {
      ['firstName','lastName','address1','address2','city','province','zip','countryCode','phone'].forEach(function (k) {
        if (!parsed[k]) return;
        out.address[k] = parsed[k];
        out.sources[k] = 'from conversation';
      });
    }
    if (!out.original_order_id) {
      for (var j = 0; j < inbound.length; j++) {
        var id = orderIdFromText(inbound[j].body) || orderIdFromText(inbound[j].body_en);
        if (id) { out.original_order_id = id; out.sources.original_order_id = 'from conversation'; break; }
      }
    }
    if (!out.marketplace) out.marketplace = marketFor(conv.origin, out.address.countryCode);
    return out;
  }
  function applyAction(out, action) {
    var d = (action && action.details) || {};
    var a = d.address || {};
    ['firstName','lastName','address1','address2','city','province','zip','countryCode','phone'].forEach(function (k) {
      var v = a[k] || (k === 'countryCode' ? normCountry(a.country || a.countryCodeV2) : '');
      if (!v) return;
      out.address[k] = v;
      out.sources[k] = 'from an earlier action';
    });
    if (d.original_order_id) { out.original_order_id = d.original_order_id; out.sources.original_order_id = 'from an earlier action'; }
    if (d.marketplace) { out.marketplace = d.marketplace; out.sources.marketplace = 'from an earlier action'; }
    if (d.shipping_speed) out.shipping_speed = d.shipping_speed;
    if (d.plain_packaging === false) out.plain_packaging = false;
    if ((d.items || []).length) out.items = d.items;
    return out;
  }
  root.EggsyPrefill = {
    splitName: splitName,
    countryFromOrigin: countryFromOrigin,
    marketFor: marketFor,
    parseAddress: parseAddress,
    orderIdFromText: orderIdFromText,
    prefill: prefill,
    applyAction: applyAction,
    normCountry: normCountry
  };
})(typeof window !== 'undefined' ? window : globalThis);
if (typeof module !== 'undefined' && module.exports) module.exports = globalThis.EggsyPrefill;
