/* Pure helpers for the inbox. No network, no secrets. */
(function (root) {
  var MONTHS = {jan:1,feb:2,mar:3,apr:4,may:5,jun:6,jul:7,aug:8,sep:9,oct:10,nov:11,dec:12};
  var CLOCK = /(\d{1,2}):(\d{2})\s*([AP]M),\s*(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+(\d{1,2})/gi;

  function splitDraft(body) {
    var src = String(body || '');
    var notes = [];
    var text = '';
    var depth = 0;
    var buf = '';
    var started = false;
    var inline = false;
    for (var i = 0; i < src.length; i++) {
      var ch = src.charAt(i);
      if (ch === '[') {
        if (depth > 0) buf += ch;
        depth++;
        continue;
      }
      if (ch === ']' && depth) {
        depth--;
        if (depth === 0) {
          var note = buf.trim();
          if (note) notes.push(note);
          if (started) inline = true;
          buf = '';
        } else buf += ch;
        continue;
      }
      if (depth) buf += ch;
      else {
        if (ch.trim()) started = true;
        text += ch;
      }
    }
    if (depth && buf.trim()) {
      notes.push(buf.trim());
      if (started) inline = true;
    }
    text = text.replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').replace(/[ \t]{2,}/g, ' ').trim();
    return {text: text, notes: notes, gaps: inline};
  }

  function zoneOffset(timeZone, utcMs) {
    var fmt = new Intl.DateTimeFormat('en-US', {
      timeZone: timeZone, hour12: false,
      year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', second: '2-digit'
    });
    var parts = fmt.formatToParts(new Date(utcMs));
    var map = {};
    parts.forEach(function (p) { map[p.type] = p.value; });
    var hour = map.hour === '24' ? 0 : +map.hour;
    var asUtc = Date.UTC(+map.year, +map.month - 1, +map.day, hour, +map.minute, +map.second);
    return asUtc - utcMs;
  }

  function zonedTime(y, mo, d, h, mi, timeZone) {
    var guess = Date.UTC(y, mo - 1, d, h, mi, 0);
    var off = zoneOffset(timeZone, guess);
    var instant = guess - off;
    var off2 = zoneOffset(timeZone, instant);
    if (off2 !== off) instant = guess - off2;
    return new Date(instant);
  }

  function clockToDate(m, sentAt, timeZone) {
    var hh = +m[1];
    var ampm = String(m[3] || '').toUpperCase();
    if (ampm === 'AM') { if (hh === 12) hh = 0; }
    else if (hh < 12) hh += 12;
    var year = sentAt.getUTCFullYear();
    var dt = zonedTime(year, MONTHS[String(m[4]).toLowerCase().slice(0, 3)], +m[5], hh, +m[2], timeZone);
    if (dt.getTime() > sentAt.getTime() + 2 * 86400000) {
      dt = zonedTime(year - 1, MONTHS[String(m[4]).toLowerCase().slice(0, 3)], +m[5], hh, +m[2], timeZone);
    }
    return dt;
  }

  function tiktokZone(origin) {
    if (origin === 'tiktok_us') return 'America/Los_Angeles';
    if (origin === 'tiktok_eu') return 'Europe/Berlin';
    return 'Europe/London';
  }

  // Latest "h:mmAM, Mon D" clock in a TikTok notification, as an ISO string.
  // Returns null when the raw text has no customer clock. Never returns the import time.
  function tiktokCustomerAt(raw, sentAtIso, origin) {
    if (!raw || !sentAtIso) return null;
    var sent = new Date(sentAtIso);
    if (isNaN(sent.getTime())) return null;
    var zone = tiktokZone(origin);
    var best = null;
    var re = new RegExp(CLOCK.source, 'gi');
    var m;
    while ((m = re.exec(String(raw)))) {
      var dt = clockToDate(m, sent, zone);
      if (isNaN(dt.getTime())) continue;
      if (dt.getTime() > sent.getTime() + 90 * 60000) continue;
      if (!best || dt > best) best = dt;
    }
    return best ? best.toISOString() : null;
  }

  function previewLine(body) {
    var t = String(body || '').replace(/\r/g, '').trim();
    if (!t || /^\[Summary by Eggsy/.test(t)) return '';
    var lines = t.split(/\n+/).map(function (s) { return s.trim(); }).filter(Boolean);
    var line = lines.length ? lines[lines.length - 1] : '';
    return line.replace(/\s+/g, ' ').slice(0, 160);
  }

  function tidy(s) { return String(s || '').replace(/\s+/g, ' ').trim(); }

  function tiktokOrder(raw) {
    var out = {orderId: '', game: '', status: ''};
    if (!raw) return out;
    var text = String(raw).replace(/\u00a0/g, ' ');
    var id = text.match(/Order ID\s+(\d{8,})/i);
    if (id) out.orderId = id[1];
    var st = text.match(/Status\s+([A-Za-z][A-Za-z ]{1,40})/);
    if (st) out.status = tidy(st[1]).replace(/\s+(Order|Reply|You).*$/i, '');
    var before = text.split(/Order ID/i)[0] || '';
    var lines = before.split(/\n/).map(function (s) { return tidy(s); }).filter(function (s) {
      return s.length > 24 && !/^https?:/i.test(s) && !/snapshot data|you received|reply in chat|notification/i.test(s);
    });
    if (lines.length) out.game = lines[lines.length - 1].slice(0, 180);
    return out;
  }

  function amazonOrder(raw, extras) {
    extras = extras || {};
    var out = {
      orderId: tidy(extras.orderNumber),
      marketplace: tidy(extras.marketplace),
      game: '',
      shipped: '',
      fulfilment: ''
    };
    var text = String(raw || '');
    if (!out.orderId) {
      var id = text.match(/#\s*(\d{3}-\d{7}-\d{7})/);
      if (id) out.orderId = id[1];
    }
    var game = text.match(/\d+\s*\/\s*(.+?)\s*\[ASIN:\s*([A-Z0-9]{8,})\]/i);
    if (game) out.game = tidy(game[1]).slice(0, 180);
    if (/\bfulfilled by amazon\b/i.test(text) || /\bFBA\b/.test(text)) out.fulfilment = 'FBA';
    else if (/\bmerchant fulfilled\b/i.test(text) || /\bFBM\b/.test(text)) out.fulfilment = 'FBM';
    var shipped = text.match(/\b(?:shipped|dispatched|versandt|versendet)\s+(?:on\s+|am\s+)?(\d{1,2}[\/.\-]\d{1,2}[\/.\-]\d{2,4}|\d{1,2}\s+[A-Za-zä]{3,12}\s+\d{4})/i);
    if (shipped) out.shipped = tidy(shipped[1]);
    return out;
  }

  function looksNonEnglish(text, lang) {
    var code = String(lang || '').toLowerCase().slice(0, 2);
    if (code && code !== 'en') return true;
    if (code === 'en') return false;
    var t = String(text || '');
    if (!t.trim()) return false;
    if (/[äöüÄÖÜßàâçéèêëïîôùûœìíóúñ¿¡]/.test(t)) return true;
    var hits = t.toLowerCase().match(/\b(und|ich|nicht|bitte|danke|vielen|hallo|sie|ihre|bonjour|merci|vous|hola|gracias|buongiorno|grazie|bedankt|dank|bestellung|commande|pedido)\b/g);
    return !!(hits && hits.length >= 2);
  }

  function deadlineLeft(at, windowHours, warnHours) {
    if (!at) return null;
    var ms = new Date(at).getTime() + windowHours * 3600000 - Date.now();
    if (isNaN(ms)) return null;
    var hot = ms <= (warnHours == null ? 4 : warnHours) * 3600000;
    if (ms < 0) {
      var late = Math.max(1, Math.round(-ms / 3600000));
      return {text: late < 48 ? late + 'h over' : 'Overdue', hot: true, overdue: true};
    }
    if (ms < 3600000) return {text: Math.max(1, Math.ceil(ms / 60000)) + 'm left', hot: true};
    return {text: Math.floor(ms / 3600000) + 'h left', hot: hot};
  }

  var SIGNOFF = {
    en: 'Best regards,\nThe Lucky Egg Team',
    de: 'Mit freundlichen Grüßen,\nIhr Lucky Egg Team',
    fr: 'Cordialement,\nL\'équipe Lucky Egg',
    es: 'Saludos cordiales,\nEl equipo de Lucky Egg',
    it: 'Cordiali saluti,\nIl team di Lucky Egg',
    nl: 'Met vriendelijke groet,\nHet Lucky Egg-team'
  };

  function hi(lang, name) {
    var n = tidy(name);
    if (lang === 'de') return n ? 'Hallo ' + n + ',' : 'Hallo,';
    if (lang === 'fr') return n ? 'Bonjour ' + n + ',' : 'Bonjour,';
    if (lang === 'es') return n ? 'Hola ' + n + ',' : 'Hola,';
    if (lang === 'it') return n ? 'Ciao ' + n + ',' : 'Ciao,';
    if (lang === 'nl') return n ? 'Hallo ' + n + ',' : 'Hallo,';
    return n ? 'Hi ' + n + ',' : 'Hi,';
  }

  function orderBit(lang, order) {
    var o = tidy(order);
    if (!o) {
      return {en: 'your order', de: 'Ihre Bestellung', fr: 'votre commande', es: 'su pedido', it: 'il suo ordine', nl: 'uw bestelling'}[lang] || 'your order';
    }
    return o;
  }

  // Plain-text Amazon replies. No emoji, links, marketing or review requests.
  // Wording follows the shipping, faulty/damaged and returns articles, including Amazon template A1.
  function amazonTemplates(lang, name, order) {
    var L = SIGNOFF[lang] ? lang : 'en';
    var greet = hi(L, name);
    var ref = orderBit(L, order);
    var sign = SIGNOFF[L];
    var bodies = {
      en: {
        wismo: greet + '\n\nThank you for getting in touch about ' + (order ? 'order ' + ref : ref) + '.\n\nWe usually pick and ship orders within 72 hours. Delivery times are estimates only, and they can take longer in busy periods.\n\nYou can follow the parcel from Your Orders in your Amazon account, then Track package. If the tracking has not moved for a long time, reply here and we will look into a replacement or a refund, whichever you prefer.\n\n' + sign,
        damaged: greet + '\n\nThank you for telling us about the problem with ' + (order ? 'order ' + ref : ref) + '. We are sorry it was damaged, faulty or not what you ordered.\n\nIf you have not already sent one, please reply with a photo of the item and the packaging. We can send a replacement, or a refund if you would rather have that. Tell us which you would like.\n\nIf Amazon asks for a reason, please choose damaged, faulty or not as described, so you are not charged return postage.\n\n' + sign,
        ret: greet + '\n\nThank you for getting in touch about ' + (order ? 'order ' + ref : ref) + '.\n\nAs the order was placed through Amazon, the return is organised on Amazon. Sign in to your Amazon account, open Your Orders, and follow the steps to request a return or a replacement.\n\nReply here if you would like us to walk you through those steps.\n\n' + sign
      },
      de: {
        wismo: greet + '\n\nvielen Dank für Ihre Nachricht zu ' + (order ? 'Bestellung ' + ref : ref) + '.\n\nWir packen und versenden Bestellungen in der Regel innerhalb von 72 Stunden. Lieferzeiten sind nur Schätzungen und können in geschäftigen Zeiten länger sein.\n\nDen Versand sehen Sie in Ihrem Amazon-Konto unter Meine Bestellungen und dann Lieferung verfolgen. Wenn sich am Tracking lange nichts ändert, antworten Sie hier. Wir schauen es uns an und bieten Ihnen einen Ersatz oder eine Erstattung an, je nachdem, was Sie möchten.\n\n' + sign,
        damaged: greet + '\n\nvielen Dank, dass Sie uns das Problem mit ' + (order ? 'Bestellung ' + ref : ref) + ' mitgeteilt haben. Es tut uns leid, dass der Artikel beschädigt, fehlerhaft oder nicht wie bestellt angekommen ist.\n\nWenn Sie noch kein Foto geschickt haben, antworten Sie bitte mit einem Foto vom Artikel und der Verpackung. Wir können einen Ersatz schicken oder erstatten, wenn Ihnen das lieber ist. Schreiben Sie uns, was Sie möchten.\n\nWenn Amazon nach einem Grund fragt, wählen Sie bitte beschädigt, fehlerhaft oder nicht wie beschrieben, damit Ihnen keine Rücksendekosten berechnet werden.\n\n' + sign,
        ret: greet + '\n\nvielen Dank für Ihre Nachricht zu ' + (order ? 'Bestellung ' + ref : ref) + '.\n\nDa die Bestellung über Amazon aufgegeben wurde, läuft die Rücksendung über Amazon. Melden Sie sich in Ihrem Amazon-Konto an, öffnen Sie Meine Bestellungen und folgen Sie den Schritten für eine Rücksendung oder einen Ersatz.\n\nAntworten Sie hier, wenn wir Sie durch diese Schritte führen sollen.\n\n' + sign
      },
      fr: {
        wismo: greet + '\n\nmerci pour votre message au sujet de ' + (order ? 'la commande ' + ref : ref) + '.\n\nNous préparons et expédions en général les commandes sous 72 heures. Les délais de livraison sont des estimations et peuvent être plus longs en période chargée.\n\nVous pouvez suivre le colis depuis Vos commandes sur votre compte Amazon, puis Suivre le colis. Si le suivi ne bouge plus depuis longtemps, répondez ici et nous verrons un remplacement ou un remboursement, selon ce que vous préférez.\n\n' + sign,
        damaged: greet + '\n\nmerci de nous avoir signalé le problème avec ' + (order ? 'la commande ' + ref : ref) + '. Nous sommes désolés que l\'article soit arrivé abîmé, défectueux ou différent de votre commande.\n\nSi vous ne l\'avez pas déjà fait, répondez avec une photo de l\'article et de l\'emballage. Nous pouvons envoyer un remplacement, ou un remboursement si vous le préférez. Dites-nous ce que vous souhaitez.\n\nSi Amazon demande un motif, choisissez abîmé, défectueux ou non conforme, afin de ne pas payer les frais de retour.\n\n' + sign,
        ret: greet + '\n\nmerci pour votre message au sujet de ' + (order ? 'la commande ' + ref : ref) + '.\n\nComme la commande a été passée sur Amazon, le retour se fait sur Amazon. Connectez-vous à votre compte Amazon, ouvrez Vos commandes, puis suivez les étapes pour demander un retour ou un remplacement.\n\nRépondez ici si vous voulez que nous vous guidions.\n\n' + sign
      },
      es: {
        wismo: greet + '\n\ngracias por escribirnos sobre ' + (order ? 'el pedido ' + ref : ref) + '.\n\nNormalmente preparamos y enviamos los pedidos en 72 horas. Los plazos de entrega son estimaciones y pueden alargarse en épocas de mucho trabajo.\n\nPuede seguir el paquete desde Sus pedidos en su cuenta de Amazon y luego Seguimiento. Si el seguimiento no se mueve durante mucho tiempo, responda aquí y miraremos un reemplazo o un reembolso, lo que prefiera.\n\n' + sign,
        damaged: greet + '\n\ngracias por contarnos el problema con ' + (order ? 'el pedido ' + ref : ref) + '. Sentimos que el artículo llegara dañado, defectuoso o distinto de lo que pidió.\n\nSi aún no lo ha enviado, responda con una foto del artículo y del embalaje. Podemos enviar un reemplazo, o un reembolso si lo prefiere. Díganos qué quiere.\n\nSi Amazon pide un motivo, elija dañado, defectuoso o no es como se describía, para que no le cobren el envío de la devolución.\n\n' + sign,
        ret: greet + '\n\ngracias por escribirnos sobre ' + (order ? 'el pedido ' + ref : ref) + '.\n\nComo el pedido se hizo en Amazon, la devolución se gestiona en Amazon. Entre en su cuenta de Amazon, abra Sus pedidos y siga los pasos para pedir una devolución o un reemplazo.\n\nResponda aquí si quiere que le guiemos.\n\n' + sign
      },
      it: {
        wismo: greet + '\n\ngrazie per averci scritto riguardo ' + (order ? 'all\'ordine ' + ref : ref) + '.\n\nDi solito prepariamo e spediamo gli ordini entro 72 ore. I tempi di consegna sono stime e possono allungarsi nei periodi di lavoro intenso.\n\nPuò seguire il pacco da I miei ordini nel suo account Amazon e poi Traccia pacco. Se il tracking non si aggiorna da molto, risponda qui e valuteremo una sostituzione o un rimborso, come preferisce.\n\n' + sign,
        damaged: greet + '\n\ngrazie per averci segnalato il problema con ' + (order ? 'l\'ordine ' + ref : ref) + '. Ci dispiace che l\'articolo sia arrivato danneggiato, difettoso o diverso da quello ordinato.\n\nSe non l\'ha già fatto, risponda con una foto dell\'articolo e dell\'imballo. Possiamo inviare una sostituzione, oppure un rimborso se lo preferisce. Ci dica cosa desidera.\n\nSe Amazon chiede un motivo, scelga danneggiato, difettoso o non conforme, così non le vengono addebitate le spese di reso.\n\n' + sign,
        ret: greet + '\n\ngrazie per averci scritto riguardo ' + (order ? 'all\'ordine ' + ref : ref) + '.\n\nPoiché l\'ordine è stato fatto su Amazon, il reso si gestisce su Amazon. Acceda al suo account Amazon, apra I miei ordini e segua i passaggi per richiedere un reso o una sostituzione.\n\nRisponda qui se vuole che la guidiamo.\n\n' + sign
      },
      nl: {
        wismo: greet + '\n\nbedankt voor uw bericht over ' + (order ? 'bestelling ' + ref : ref) + '.\n\nWe pakken en versturen bestellingen meestal binnen 72 uur. Levertijden zijn schattingen en kunnen langer zijn in drukke periodes.\n\nU volgt het pakket via Uw bestellingen in uw Amazon-account en dan Volg pakket. Als de tracking lang niet beweegt, antwoord dan hier. We kijken naar een vervanging of een terugbetaling, wat u het liefst wilt.\n\n' + sign,
        damaged: greet + '\n\nbedankt dat u ons het probleem met ' + (order ? 'bestelling ' + ref : ref) + ' hebt laten weten. Het spijt ons dat het artikel beschadigd, defect of anders dan besteld is aangekomen.\n\nAls u nog geen foto hebt gestuurd, antwoord dan met een foto van het artikel en de verpakking. We kunnen een vervanging sturen, of terugbetalen als u dat liever wilt. Laat ons weten wat u wilt.\n\nAls Amazon om een reden vraagt, kies dan beschadigd, defect of niet zoals beschreven, zodat u geen retourkosten betaalt.\n\n' + sign,
        ret: greet + '\n\nbedankt voor uw bericht over ' + (order ? 'bestelling ' + ref : ref) + '.\n\nOmdat de bestelling via Amazon is geplaatst, loopt de retour via Amazon. Log in op uw Amazon-account, open Uw bestellingen en volg de stappen voor een retour of een vervanging.\n\nAntwoord hier als u wilt dat we u erdoorheen leiden.\n\n' + sign
      }
    };
    var pack = bodies[L];
    return [
      {id: 'wismo', label: "Where's my order", body: pack.wismo},
      {id: 'damaged', label: 'Damaged item', body: pack.damaged},
      {id: 'return', label: 'Return', body: pack.ret}
    ];
  }

  function replyLang(origin, language, body) {
    var code = String(language || '').toLowerCase().slice(0, 2);
    if (code === 'en') return 'en';
    if (code && SIGNOFF[code]) return code;
    if (body && !looksNonEnglish(body, language)) return 'en';
    var byOrigin = {
      amazon_de: 'de', amazon_fr: 'fr', amazon_it: 'it', amazon_es: 'es', amazon_nl: 'nl',
      tiktok_eu: 'de'
    };
    return byOrigin[origin] || 'en';
  }

  // How a stored message, draft or queued reply should be shown.
  // mode 'english': leave the text as it is.
  // mode 'translated': body_en is already cached.
  // mode 'needs': foreign, and body_en still has to be fetched and stored.
  function englishView(record) {
    record = record || {};
    var dir = String(record.direction || '');
    if (dir === 'note') return {mode: 'english'};
    var lang = String(record.language || '').toLowerCase().slice(0, 2);
    var en = String(record.body_en || '').trim();
    if (lang === 'en') return {mode: 'english'};
    if (en && (lang || looksNonEnglish(record.body, ''))) return {mode: 'translated', language: lang, english: en};
    if (looksNonEnglish(record.body, record.language) || (lang && lang !== 'en')) return {mode: 'needs', language: lang};
    return {mode: 'english'};
  }

  // First line, matching cx_latest_inbound. Empty for Eggsy summary stubs.
  function previewFirstLine(body) {
    var t = String(body || '').replace(/\r/g, '').trim();
    if (!t || /^\[Summary by Eggsy/.test(t)) return '';
    return (t.split('\n')[0] || '').replace(/\s+/g, ' ').trim().slice(0, 160);
  }

  // English twin of a canned Amazon reply, when the text is still that template.
  function englishForTemplate(lang, name, order, body) {
    var L = String(lang || '').toLowerCase().slice(0, 2);
    if (!L || L === 'en' || !SIGNOFF[L]) return '';
    var foreign = amazonTemplates(L, name, order);
    var english = amazonTemplates('en', name, order);
    var target = tidy(body);
    if (!target) return '';
    for (var i = 0; i < foreign.length; i++) {
      if (tidy(foreign[i].body) === target) return english[i].body;
    }
    return '';
  }

  root.EggsyDisplay = {
    splitDraft: splitDraft,
    tiktokCustomerAt: tiktokCustomerAt,
    previewLine: previewLine,
    previewFirstLine: previewFirstLine,
    tiktokOrder: tiktokOrder,
    amazonOrder: amazonOrder,
    looksNonEnglish: looksNonEnglish,
    deadlineLeft: deadlineLeft,
    amazonTemplates: amazonTemplates,
    replyLang: replyLang,
    englishView: englishView,
    englishForTemplate: englishForTemplate
  };
})(typeof window !== 'undefined' ? window : globalThis);
if (typeof module !== 'undefined' && module.exports) module.exports = globalThis.EggsyDisplay;
