import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { handleForwardModes, maybeAutoForward, FUNCTION_VERSION } from "./colleague-forward.ts";
import { isCreativeCollaboration, namedPersonSalutation } from "./mail-rules.ts";

const TOPIC_NAME = "projects/eggsy-cx-513616/topics/gmail-hey-inbox";
const HEY = "hey@luckyegg.co";
const GMAIL_PREFIX = "gmail:";
const WATCH_RENEW_MS = 36 * 60 * 60 * 1000;

const AMAZON_MARKETS: Array<[string, string, string]> = [
  ["marketplace.amazon.com.be", "amazon_be", "Amazon BE"],
  ["marketplace.amazon.co.uk", "amazon_uk", "Amazon UK"],
  ["marketplace.amazon.com", "amazon_us", "Amazon US"],
  ["marketplace.amazon.de", "amazon_de", "Amazon DE"],
  ["marketplace.amazon.fr", "amazon_fr", "Amazon FR"],
  ["marketplace.amazon.it", "amazon_it", "Amazon IT"],
  ["marketplace.amazon.es", "amazon_es", "Amazon ES"],
  ["marketplace.amazon.nl", "amazon_nl", "Amazon NL"],
  ["marketplace.amazon.se", "amazon_se", "Amazon SE"],
  ["marketplace.amazon.pl", "amazon_pl", "Amazon PL"],
  ["marketplace.amazon.ca", "amazon_other", "Amazon CA"],
];

const SKIP_FROM_EXACT = new Set([
  "no-reply@tenevo.co.uk",
  "no-reply@walmart.com",
  "do-not-reply@walmart.com",
  "suppliercom@walmart.com",
  "no-reply@shop.tiktok.com",
  "sellersupport@shop.tiktok.com",
  "uksellersupport@shop.tiktok.com",
  "register@account.tiktok.com",
  "support-us@tiktok.com",
  "no-reply@shopify.com",
  "email@email.shopify.com",
  "support@judge.me",
  "noreply@discord.com",
  "noreply@wise.com",
  "team@sellerboard.com",
  "maccount@microsoft.com",
  "system@thefirstmile.co.uk",
  "operationsteam@eburypartners.com",
  "accounts@vrdistribution.com.au",
  "email@emails.asda.com",
  "wholesale@info.faire.com",
  "noreply@info.faire.com",
  "noreply@email.openai.com",
  "noreply@openai.com",
  "marketing@hello.klaviyo.com",
  "noreply@info.pinterest.com",
  "noreply@account.pinterest.com",
  "seller-coaching@amazon.com",
  "seller.service05@amazon.com",
  "transparency@brandprotection.amazon.com",
  "no-reply@notifications.tiktok.com",
  "noreply-tt4b@notifications.tiktok.com",
  "noreply@netlify.com",
]);

const SKIP_FROM_SUFFIX = [
  "@t.shopifyemail.com",
  "@transglobalexpress.co.uk",
  "@info.faire.com",
  "@mail.instagram.com",
  "@stripe.com",
  "@email.apple.com",
  "@notifications.google.com",
  "@email.openai.com",
  "@openai.com",
  "@hello.klaviyo.com",
  "@info.pinterest.com",
  "@account.pinterest.com",
  "@notifications.tiktok.com",
  "@email.shopify.com",
  "@offers.tbaglobal.com",
  "@xsell.co",
  "@momschoicemedia.com",
  "@netlify.com",
  "@facebookmail.com",
  "@business.facebook.com",
  "@meta.com",
  "@support.facebook.com",
];

const SKIP_FROM_INCLUDES = [
  "mailer-daemon@",
  "postmaster@",
  "no-reply@klaviyo.com",
  "donotreply@amazon.",
  "merch.service05@amazon.",
  "seller.service05@amazon.",
  "seller-coaching@amazon.",
  "seller-coaching-m@amazon.",
  "order-update@amazon.",
  "seller-notification@amazon.",
  "fba-noreply@amazon.",
  "shipment-tracking@amazon.",
  "sas-enforcement-advisory@amazon.",
  "uk-sfp-performance@amazon.",
  "uk-childrens-sleepwear-safety-mv@amazon.",
  "no-reply@amazon.",
  "transparency@brandprotection.amazon.",
  "e-commerce.ipnotice@mail.byteintl.com",
  "fbt@mail.byteintl.com",
  "no-reply@ads-service.tiktok.com",
  "noreply@business-updates.facebook.com",
  "saferconsumerproducts@",
  "cbsa-asfc@",
  "idg.vendor.compliance@",
  "testflight_no_reply@",
  "noreply@email.openai.",
  "ticket-external-",
  "toys-safety-mv@amazon.",
  "notice-dispute@amazon.",
  "notice-outreach@amazon.",
  "@brandregistry.amazon.",
  "@brand-registry.amazon.",
  "@brandprotection.amazon.",
];

const SKIP_SUBJECT = [
  /verification code/i,
  /delivery status notification/i,
  /undelivered mail/i,
  /delivery incomplete/i,
  /your documentation for order/i,
  /chargeback evidence/i,
  /product blocked/i,
  /tiktok shop account new user login/i,
  /you have \d+ chats? to reply/i,
  /return\/refund request received/i,
  /invalid shipping address/i,
  /order #\d+ \(#\d+\) placed/i,
  /amazon hat ihre\(n\) verkauften artikel versandt/i,
  /return authorisation notification/i,
  /verkauft, jetzt liefern/i,
  /^your email to /i,
  /^deine e-mail an /i,
  /instagram recap/i,
  /testflight invitation/i,
  /wise statement/i,
  /\[lucky egg\] order #\d+/i,
  /luxury watches?/i,
  /iconic luxury watch/i,
  /carrier contract rates/i,
  /fcl shipments? from china/i,
  /stand design proposal/i,
  /booth displays?/i,
  /test a new card version/i,
  /card games for lucky egg/i,
  /amazon account management/i,
  /digital support partner/i,
  /complimentary b2b networking/i,
  /mom.?s choice awards/i,
  /little black book/i,
  /please tell us your experience/i,
  /\[paid research\]/i,
  /reimbursement details for transaction/i,
  /missing\/invalid tracking id/i,
  /misrouted shipments/i,
  /your brand is eligible for transparency/i,
  /marty capabilities in supplier one/i,
  /pinterest account security alert/i,
  /distribute products as a merchant on pinterest/i,
  /edesk.? cancellation request/i,
  /walking away from huge savings/i,
  /apprenticeships? funding webinar/i,
  /careers fair/i,
  /stand bonus for spielwarenmesse/i,
  /outreach made simple/i,
  /review credited payment/i,
  /unpublished restricted items/i,
  /if you can prompt it, you can build it/i,
  /make it a team effort with netlify/i,
  /has received your payment/i,
  /application for graphic designer/i,
  /your performance report for/i,
  /ps - appeal/i,
  /statement of account for/i,
  /new referral order on uppromote/i,
  /a reel idea for/i,
  /i have a very small request/i,
  /your a\/b test is complete/i,
  /new message in mailbox/i,
  /bill for lucky egg/i,
  /invoice no\\. .* awaiting payment/i,
  /mom knows best/i,
  /amazon customer insights report/i,
  /stripe is updating its terms/i,
  /housing now open for toy fair/i,
  /critical amazon issue/i,
  /gift for you, reply for more details/i,
  /we added an extra .+ to your cart/i,
  /a reel idea for/i,
  /vat from .\d+/i,
];

type Header = { name: string; value: string };
type GmailPayload = {
  mimeType?: string;
  body?: { data?: string };
  parts?: GmailPayload[];
  headers?: Header[];
};
type GmailMessage = {
  id: string;
  threadId: string;
  internalDate?: string;
  labelIds?: string[];
  snippet?: string;
  payload?: GmailPayload;
};

let cachedToken = "";
let cachedTokenExp = 0;

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function addrOf(raw: string): string {
  const m = raw.match(/<([^>]+)>/);
  return (m?.[1] || raw).trim().toLowerCase();
}

function nameOf(raw: string): string {
  const m = raw.match(/^\s*"?([^"<]+?)"?\s*<[^>]+>/);
  const name = (m?.[1] || "").trim();
  if (name) return name.replace(/\s+/g, " ");
  const addr = addrOf(raw);
  return addr.includes("@") ? addr.split("@")[0] : raw.trim();
}

function headerValue(headers: Header[] | undefined, name: string): string {
  const n = name.toLowerCase();
  return headers?.find((h) => h.name.toLowerCase() === n)?.value || "";
}

function decodeB64Url(data: string): string {
  try {
    const pad = data.replace(/-/g, "+").replace(/_/g, "/");
    const raw = atob(pad);
    return new TextDecoder().decode(Uint8Array.from(raw, (c) => c.charCodeAt(0)));
  } catch {
    return "";
  }
}

function htmlToText(html: string): string {
  return html
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/p>/gi, "\n\n")
    .replace(/<a\b[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi, (_m, href, label) => `${label} (${href}) `)
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .replace(/[ \t]{2,}/g, " ")
    .trim();
}


/** Prefer shop_region / seller host from raw HTML or text; gmail HTML links are authoritative. */
function extractTikTokShopRegion(raw: string): "tiktok_uk" | "tiktok_eu" | "tiktok_us" | null {
  const text = raw || "";
  const region = text.match(/shop_region=([A-Z]{2})/i)?.[1]?.toUpperCase();
  if (region === "GB" || region === "UK") return "tiktok_uk";
  if (region === "US") return "tiktok_us";
  if (region && ["DE","FR","IT","ES","IE","NL","BE","AT","PL","SE","PT","IE"].includes(region)) return "tiktok_eu";
  if (/seller-uk\.tiktok\.com|oec_seller_id=7495000478933682401/i.test(text)) return "tiktok_uk";
  if (/seller-us\.tiktok\.com/i.test(text)) return "tiktok_us";
  if (/seller-(?:eu|de|fr|it|es)\.tiktok\.com/i.test(text)) return "tiktok_eu";
  return null;
}

function extractBody(payload?: GmailPayload): string {
  if (!payload) return "";
  if (payload.body?.data) {
    const decoded = decodeB64Url(payload.body.data);
    return payload.mimeType === "text/html" ? htmlToText(decoded) : decoded;
  }
  const parts = payload.parts || [];
  const plain = parts.find((p) => p.mimeType === "text/plain" && p.body?.data);
  if (plain?.body?.data) return decodeB64Url(plain.body.data);
  const html = parts.find((p) => p.mimeType === "text/html" && p.body?.data);
  if (html?.body?.data) return htmlToText(decodeB64Url(html.body.data));
  for (const part of parts) {
    const inner = extractBody(part);
    if (inner) return inner;
  }
  return "";
}

function parseShopifyForm(body: string, replyTo: string) {
  const name = body.match(/^\s*Name:\s*(.+)$/im)?.[1]?.trim() || "";
  const emailRaw = body.match(/^\s*E-?mail:\s*(.+)$/im)?.[1]?.trim() || replyTo;
  const commentMatch = body.match(/^\s*(?:Comment|Message|Body):\s*([\s\S]+)/im);
  let comment = commentMatch?.[1] || body;
  comment = comment
    .replace(/\nYou received this[\s\S]*$/i, "")
    .replace(/\n--+\s*[\s\S]*$/, "")
    .trim();
  return { name, email: addrOf(emailRaw), comment: comment || body };
}

function shopifyShop(subject: string, body: string): string {
  const text = `${subject}\n${body}`.toLowerCase();
  if (/murder mystery|murdermysterycases/.test(text)) return "Murder Mystery Cases (GB)";
  const shopName = subject.match(/^New customer message on\s+(.+)$/i)?.[1] || "";
  if (/ireland|\(ie\)|\bie\b/i.test(shopName) || /luckyegg \(ie\)|lucky egg \(ie\)/.test(text)) {
    return "Lucky Egg (IE)";
  }
  if (/united states|\(us\)|\bus\b/i.test(shopName) || /luckyegg \(us\)|lucky egg \(us\)/.test(text)) {
    return "Lucky Egg (US)";
  }
  return "Lucky Egg (GB)";
}

function emailShop(subject: string, body: string): string {
  if (/murder mystery|murdermysterycases|death at area|death of an influencer|dublin castle|buckingham palace|eiffel tower/i.test(`${subject}\n${body}`)) {
    return "Murder Mystery Cases";
  }
  return "Lucky Egg";
}

function matchAmazon(text: string) {
  const lower = text.toLowerCase();
  for (const [host, origin, shop] of AMAZON_MARKETS) {
    if (lower.includes(host)) return { origin, shop };
  }
  return null;
}

function extractOrderNumber(subject: string, body: string): string | null {
  const amazon = `${subject}\n${body}`.match(/\b(\d{3}-\d{7}-\d{7})\b/);
  if (amazon) return amazon[1];
  const shopify = `${subject}\n${body}`.match(/\b(?:order(?:\s+number)?\s*[:#]?\s*|#)(\d{4,7})\b/i);
  if (shopify) return shopify[1];
  const tiktok = `${subject}\n${body}`.match(/\b(57\d{16,})\b/);
  if (tiktok) return tiktok[1];
  return null;
}

function isAutomated(fromA: string, subject: string): boolean {
  if (SKIP_FROM_EXACT.has(fromA)) return true;
  if (SKIP_FROM_SUFFIX.some((s) => fromA.endsWith(s))) return true;
  if (SKIP_FROM_INCLUDES.some((s) => fromA.includes(s))) return true;
  if (fromA.endsWith("@s.urbnvendor.com") || fromA.includes("urbnvendorrelations@")) return true;
  if (/^trms[-.].*@amazon\./.test(fromA)) return true;
  return SKIP_SUBJECT.some((re) => re.test(subject));
}


/** Job applications, CVs, hiring enquiries, and messages to Marcus about roles. */
function isJobOrRecruitment(subject: string, body: string): boolean {
  const hay = `${subject}\n${body}`.toLowerCase();
  if (/graphic designer position/.test(hay) && /application|resume|cv\b/.test(hay)) return true;
  if (/\b(?:job application|applying for|application for (?:the )?(?:position|role|vacancy))\b/.test(hay)) return true;
  if (/\b(?:are you hiring|any (?:open )?(?:roles|positions|vacancies)|looking for (?:a )?job)\b/.test(hay)) return true;
  if (/\b(?:curriculum vitae|resume|cv)\b/.test(hay) && /\b(?:appl(?:y|ying|ication)|position|hiring|role|vacancy|candidate|job)\b/.test(hay)) return true;
  if (/\b(?:my|attached|enclos(?:ed|ing)|please find)\b.{0,40}\b(?:curriculum vitae|resume|cv)\b/.test(hay)) return true;
  if (/\bmarcus\b/.test(hay) && /\b(?:role|position|hiring|job|chief of staff|cos\b|application|cv\b|resume|recruit)/.test(hay)) return true;
  if (/\b(?:chief of staff|recruitment|job vacancy|cover letter)\b/.test(hay)) return true;
  return false;
}

/** Amazon/Brand Registry IP notices: infringement complaints, takedowns, report acknowledgements. */
function isIpInfringementNotice(subject: string, body: string): boolean {
  const hay = `${subject}\n${body}`.toLowerCase();
  if (/\breport of rights infringement\b/.test(hay)) return true;
  if (/\binfringement complaint\b/.test(hay)) return true;
  if (/\bbrand registry\b/.test(hay)) return true;
  if (/\b(?:takedown|take-down)\b/.test(hay) && /\b(?:acknowledg|received|notice|request|report)\b/.test(hay)) return true;
  if (/\bnotice[- ]dispute\b/.test(hay)) return true;
  if (/\breport id\b/.test(hay) && /\b(?:infringement|brand registry|takedown)\b/.test(hay)) return true;
  return false;
}

/** Obvious non-customer noise for email_hey. When unsure, return false (keep). */
function isJunkPitch(fromA: string, subject: string, body: string): boolean {
  const hay = `${subject}\n${body}`.toLowerCase();
  if (/redeem your gift of|gift of\s+[\d.]+\s*m\b/.test(hay)) return true;
  if (/luxury watch|rolex replica|watches? from\s*\$\d+/.test(hay) && /shop\s*deal|upgrade your style/.test(hay)) return true;
  if (/\b(oem|odm)\b/.test(hay) && /\bmoq\b/.test(hay) && /card|board game|sampling/.test(hay)) return true;
  if (/gifting collaboration|creator (?:collab|collaboration)|i run the .{0,80}tiktok account/.test(hay) && /followers/.test(hay)) return true;
  if (/contributing a game that students|student union campaign/.test(hay)) return true;
  if (/sourcing from china|expanding product offerings/.test(hay) && /egosourcing|sourcing/.test(fromA + hay)) return true;
  if (/klaviyo email marketing|one monthly support arrangement/.test(hay)) return true;
  if (/@crm\.wix\.com$/.test(fromA) && !/form name:\s*contact/i.test(body) && !/contact email:/i.test(body)) return true;
  if (/registrants? \/ attendees|attendees list|acquiring the/.test(hay) && /toy fair|event/.test(hay)) return true;
  if (/led wall|stand.?s visual impact|euroledwall|showwallgroup/.test(hay) && /spielwarenmesse|trade show|stand/.test(hay)) return true;
  if (/disputed payment reversal|credited payment/.test(hay) && /secure\.net|capital one/.test(fromA + hay)) return true;
  if (/graphic designer position/.test(hay) && /application|resume|cv\b/.test(hay)) return true;
  if (/technical errors and\s+not well optimized for google|seo|digimark/.test(hay) && /website/.test(hay)) return true;
  if (/freight forwarder|ship goods from china/.test(hay) && /small request|keep mine next/.test(hay)) return true;
  if (/cleaning quote|titan apex|without charge/.test(hay) && /lucky egg\?/.test(subject.toLowerCase() + hay)) return true;
  if (/ecomscale|reel idea/.test(hay) && /instagram|meta ads/.test(hay)) return true;
  if (/gift for you, reply for more details/.test(hay)) return true;
  if (/mycarpe|extra \d+% to your cart|walking away from huge savings/.test(hay)) return true;
  if (/ecomscale|a reel idea for/.test(hay) && /instagram|meta ads|reel/.test(hay)) return true;
  return false;
}

const TOPIC_VALUES = [
  "Return request",
  "Refund request",
  "Shipping / where's my order",
  "Damaged or faulty",
  "Missing parts",
  "Replacement",
  "Product / gameplay question",
  "Order change / cancellation",
  "Address issue",
  "Wholesale / B2B",
  "Complaint",
  "Feedback / praise",
  "Other",
];

function inferTopic(subject: string, body: string): string | null {
  const t = `${subject}
${body}`.toLowerCase();
  if (/\breplacement\b/.test(t)) return "Replacement";
  if (/\brefund\b/.test(t)) return "Refund request";
  if (/\breturn(?:s|ing|ed)?\b/.test(t) && !/returned mail|undeliverable/.test(t)) return "Return request";
  if (/\bmissing (?:part|parts|piece|pieces|item|items)\b/.test(t)) return "Missing parts";
  if (/\b(?:damaged|faulty|broken|not working|doesn't work|does not work)\b/.test(t)) return "Damaged or faulty";
  if (/\bwhere(?:'s| is) my (?:order|parcel|package)\b|\btracking\b/.test(t)) return "Shipping / where's my order";
  if (/\bcancel/.test(t) || /\bchange (?:my )?(?:address|order)\b/.test(t)) return "Order change / cancellation";
  if (/\bwholesale\b|\bb2b\b/.test(t)) return "Wholesale / B2B";
  return null;
}



/** Free-mail and similar personal inboxes: never treated as corporate senders. */
const FREE_MAIL_DOMAINS = [
  "gmail.com",
  "googlemail.com",
  "outlook.com",
  "outlook.co.uk",
  "hotmail.com",
  "hotmail.co.uk",
  "hotmail.fr",
  "hotmail.de",
  "hotmail.it",
  "hotmail.es",
  "live.com",
  "live.co.uk",
  "msn.com",
  "yahoo.com",
  "yahoo.co.uk",
  "yahoo.de",
  "yahoo.fr",
  "yahoo.es",
  "yahoo.it",
  "yahoo.com.br",
  "yahoo.ca",
  "ymail.com",
  "rocketmail.com",
  "icloud.com",
  "me.com",
  "mac.com",
  "aol.com",
  "aol.co.uk",
  "protonmail.com",
  "proton.me",
  "pm.me",
  "gmx.com",
  "gmx.de",
  "gmx.net",
  "web.de",
  "mail.com",
  "email.com",
  "inbox.lv",
  "inbox.com",
  "mail.ru",
  "yandex.com",
  "yandex.ru",
  "zoho.com",
  "zohomail.com",
  "fastmail.com",
  "fastmail.fm",
  "hey.com",
  "btinternet.com",
  "btopenworld.com",
  "sky.com",
  "virginmedia.com",
  "ntlworld.com",
  "blueyonder.co.uk",
  "talktalk.net",
  "plus.com",
  "comcast.net",
  "sbcglobal.net",
  "att.net",
  "verizon.net",
  "bellsouth.net",
  "cox.net",
  "charter.net",
  "earthlink.net",
  "shaw.ca",
  "rogers.com",
  "telus.net",
  "sympatico.ca",
  "qq.com",
  "163.com",
  "126.com",
  "sina.com",
  "naver.com",
  "daum.net",
  "hanmail.net",
  "wp.pl",
  "o2.pl",
  "interia.pl",
  "onet.pl",
  "seznam.cz",
  "abv.bg",
  "ukr.net",
  "t-online.de",
  "orange.fr",
  "wanadoo.fr",
  "free.fr",
  "libero.it",
  "virgilio.it",
  "tin.it",
  "alice.it",
];

/**
 * Company / platform domains that should not enter the Eggsy CX hey@ inbox.
 * Matches the domain or any subdomain (e.g. smtpmail.smythstoys.com).
 * Amazon buyer relays at marketplace.amazon.* are classified before this list is used.
 */
const CORPORATE_DOMAINS = [
  // Big tech / platforms
  "google.com",
  "microsoft.com",
  "office.com",
  "office365.com",
  "windows.com",
  "apple.com",
  "adobe.com",
  "meta.com",
  "facebook.com",
  "instagram.com",
  "whatsapp.com",
  "linkedin.com",
  "twitter.com",
  "x.com",
  // Marketplaces (seller/platform notices only)
  "amazon.com",
  "amazon.co.uk",
  "amazon.de",
  "amazon.fr",
  "amazon.it",
  "amazon.es",
  "amazon.nl",
  "amazon.se",
  "amazon.pl",
  "amazon.ca",
  "amazon.com.be",
  "amazon.com.au",
  "amazon.co.jp",
  "walmart.com",
  "tiktok.com",
  "bytedance.com",
  "shopify.com",
  "shopifyemail.com",
  // Retailers / distributors / wholesale platforms
  "smythstoys.com",
  "indigo.ca",
  "fivebelow.com",
  "tjx.com",
  "tkmaxx.com",
  "marshalls.com",
  "homegoods.com",
  "tesco.com",
  "tesco.co.uk",
  "asda.com",
  "argos.co.uk",
  "sainsburys.co.uk",
  "johnlewis.com",
  "waitrose.com",
  "theentertainer.com",
  "hamleys.com",
  "toysrus.com",
  "toysrus.co.uk",
  "target.com",
  "costco.com",
  "costco.co.uk",
  "walmart.ca",
  "alibaba.com",
  "aliexpress.com",
  "temu.com",
  "jd.com",
  "faire.com",
  "ankorstore.com",
  // Couriers (business accounts)
  "dhl.com",
  "dhl.co.uk",
  "royalmail.com",
  "ups.com",
  "fedex.com",
  "evri.com",
  "parcelforce.com",
  "dpd.com",
  "dpd.uk",
  "usps.com",
  "hermesworld.com",
  // SaaS / finance / productivity / notifications
  "stripe.com",
  "paypal.com",
  "paypal.co.uk",
  "square.com",
  "squareup.com",
  "xero.com",
  "intuit.com",
  "quickbooks.com",
  "hubspot.com",
  "salesforce.com",
  "klaviyo.com",
  "mailchimp.com",
  "canva.com",
  "zoom.us",
  "zoom.com",
  "netlify.com",
  "vercel.com",
  "openai.com",
  "anthropic.com",
  "dropbox.com",
  "atlassian.com",
  "slack.com",
  "notion.so",
  "zendesk.com",
  "intercom.com",
  "freshdesk.com",
  "telephony-cloud.com",
  "sendgrid.net",
  "mailgun.com",
  "mailgun.org",
];

const AUTOMATED_LOCAL_PART =
  /^(?:no[-_.]?reply|do[-_.]?not[-_.]?reply|donotreply|noreply(?:[-+._].*)?|notifications?|notify|mailer(?:-daemon)?|postmaster|automated?|alerts?|bounces?|newsletter|voicemail|system)$/i;

function emailDomain(addr: string): string {
  const at = (addr || "").lastIndexOf("@");
  return at >= 0 ? addr.slice(at + 1).toLowerCase() : "";
}

function emailLocalPart(addr: string): string {
  const at = (addr || "").lastIndexOf("@");
  return at >= 0 ? addr.slice(0, at).toLowerCase() : "";
}

function isDomainOrSubdomain(domain: string, root: string): boolean {
  return domain === root || domain.endsWith("." + root);
}

function isFreeMailAddress(fromA: string): boolean {
  const domain = emailDomain(fromA);
  return FREE_MAIL_DOMAINS.some((root) => isDomainOrSubdomain(domain, root));
}

function isMarketplaceAmazonRelay(fromA: string): boolean {
  return emailDomain(fromA).includes("marketplace.amazon.");
}

function matchesCorporateDomain(fromA: string): boolean {
  const domain = emailDomain(fromA);
  if (!domain) return false;
  return CORPORATE_DOMAINS.some((root) => isDomainOrSubdomain(domain, root));
}

/** Shopify-style or Amazon buyer order plus a clear consumer CS request. */
function isConsumerCustomerQuery(subject: string, body: string): boolean {
  const hay = `${subject}\n${body}`.toLowerCase();
  const hasOrder =
    /\b(?:order(?:\s+(?:number|no\.?|#))?|#)\s*[:#]?\s*\d{4,7}\b/.test(hay) ||
    /\b\d{3}-\d{7}-\d{7}\b/.test(hay);
  if (!hasOrder) return false;
  return /\b(?:refund|return|replace(?:ment)?|damaged|faulty|broken|missing (?:part|parts|piece|pieces|game|games|item|items)|where(?:'s| is) my (?:order|parcel|package)|not working|doesn'?t work|does not work|wrong (?:item|game|version)|cancel(?:led)? (?:my )?order)\b/.test(hay);
}

function isPurchaseOrder(subject: string, body: string): boolean {
  const hay = `${subject}\n${body}`.toLowerCase();
  if (/\bpurchase[\s-]*orders?\b/.test(hay)) return true;
  if (/\bbon(?:s)? de commande\b/.test(hay)) return true;
  if (/\bportefeuille de commandes?\b/.test(hay)) return true;
  // PO# 4400617180 / P.O. 4400617180 / PO-4400617180 — require digits so "PO Box" is ignored.
  if (/\bp\.?\s*o\.?\s*(?:number|no\.?|#|[:\-])\s*\d{4,}\b/.test(hay)) return true;
  if (/\bpo[#:\-]\s*\d{4,}\b/.test(hay)) return true;
  if (/\bpallet\s+(?:data|quantity|qty|request|requests|info|information)\b/.test(hay)) return true;
  if (/\b(?:stock|inventory)\s+requests?\b/.test(hay)) return true;
  if (/\bedi\b/.test(hay) && /\b(?:purchase order|order confirmation|asn|850|855)\b/.test(hay)) return true;
  if (
    /\b(?:dear vendor|dear supplier|cher fournisseur|geehrter lieferant)\b/.test(hay) &&
    /\b(?:purchase|order|pallet|sku|deliver|delivery|stock|po[#:\-\s]?\d)\b/.test(hay)
  ) {
    return true;
  }
  return false;
}

/** Shopify/Wix customer forms must never be treated as corporate mail. */
function isCustomerFormMailer(fromA: string, subject: string, body: string): boolean {
  const hay = `${subject}\n${body}`;
  if (/@(?:crm\.)?wix\.com$/i.test(fromA) && (/form name:/i.test(hay) || /contact email:/i.test(hay))) return true;
  if (
    fromA === "mailer@shopify.com" ||
    /via shopify contact form/i.test(hay) ||
    /^contact form:/i.test(subject) ||
    /^new customer message on /i.test(subject)
  ) {
    return true;
  }
  return false;
}

/**
 * Corporate / platform / retailer mail for email_hey only.
 * Free-mail customers, customer forms, and a clear consumer query from a company domain are kept.
 */
function isCorporateSender(fromA: string, subject: string, body: string): boolean {
  if (isMarketplaceAmazonRelay(fromA)) return false;
  if (isCustomerFormMailer(fromA, subject, body)) return false;
  if (isFreeMailAddress(fromA)) return false;
  if (isConsumerCustomerQuery(subject, body) && !isPurchaseOrder(subject, body)) return false;
  if (matchesCorporateDomain(fromA)) return true;
  if (AUTOMATED_LOCAL_PART.test(emailLocalPart(fromA))) return true;
  return false;
}


function classify(msg: GmailMessage, from: string, replyTo: string, subject: string, body: string) {
  const fromA = addrOf(from);
  if (fromA === HEY) return { kind: "outgoing" as const };
  // Run before channel routing so Shopify/Wix forms are also skipped.
  if (isJobOrRecruitment(subject, body)) return { kind: "skip" as const, reason: "job" };
  if (isIpInfringementNotice(subject, body)) return { kind: "skip" as const, reason: "ip" };

  const hay = `${from} ${replyTo} ${subject}`;
  const amazon = matchAmazon(hay);
  if (amazon) {
    // Marketplace mail that lands in hey@. tagMmc runs after the junk, corporate,
    // colleague-forward and Marty-forward filters. Direct amazon/tiktok/walmart
    // imports are tagged by the messages_tag_mmc trigger, which calls the same classifier.
    return { kind: "ingest" as const, origin: amazon.origin, shop: amazon.shop };
  }

  if (
    fromA === "mailer@shopify.com" ||
    /via shopify contact form/i.test(from) ||
    /^contact form:/i.test(subject) ||
    /^new customer message on /i.test(subject)
  ) {
    // Shopify form. Tagged by tagMmc after the filters above, not inside this return.
    return { kind: "ingest" as const, origin: "shopify_form", shop: shopifyShop(subject, body) };
  }

  if (
    /@wix\.com$/i.test(fromA) ||
    /@crm\.wix\.com$/i.test(fromA) ||
    /murdermysterycases/i.test(fromA) ||
    /you received a new message from .{0,120}wix/i.test(body) ||
    (/you have received a new notification from murder mystery cases/i.test(subject) && /contact email:/i.test(body))
  ) {
    // Wix form. This origin is MMC-only; tagMmc applies the shared classifier after the filters above.
    return { kind: "ingest" as const, origin: "wix_mmc_form", shop: "Murder Mystery Cases (Wix form)" };
  }

  if (/message from walmart\.com customer/i.test(subject) || /marketplace\.walmart/i.test(hay)) {
    // Walmart buyer mail. Same post-filter MMC tagging as the other marketplace branches.
    return { kind: "ingest" as const, origin: "walmart", shop: "Walmart US" };
  }

  const tiktokBuyer = /tiktok/i.test(hay) &&
    /(?:buyer|customer)\s+message|new message from .{0,60}customer/i.test(`${subject}\n${body}`) &&
    !isAutomated(fromA, subject);
  if (tiktokBuyer) {
    const regionOrigin = extractTikTokShopRegion(`${hay}\n${body}`)
      || (/seller-uk\.tiktok|shop_region=GB|\b£\d|royal mail|inpost|evri|ZK\d+GB/i.test(`${hay}\n${body}`) ? "tiktok_uk" as const : null)
      || (/@.*uk|tiktok uk|\.co\.uk/i.test(hay) ? "tiktok_uk" as const : null)
      || (/eu|europe|seller-(?:eu|de)\.tiktok|shop_region=(?:DE|FR|IT|ES)/i.test(`${hay}\n${body}`) ? "tiktok_eu" as const : null)
      || ("tiktok_us" as const);
    const origin = regionOrigin;
    const shop = origin === "tiktok_uk" ? "TikTok UK" : origin === "tiktok_eu" ? "TikTok EU" : "TikTok US";
    // TikTok buyer mail. Same post-filter MMC tagging as the other marketplace branches.
    return { kind: "ingest" as const, origin, shop };
  }

  // Creative collaboration (illustrators, game designers) must not be dropped as junk, automated subject, or corporate mail.
  if (isCreativeCollaboration(subject, body)) {
    return { kind: "ingest" as const, origin: "email_hey", shop: emailShop(subject, body) };
  }
  if (isAutomated(fromA, subject)) return { kind: "skip" as const, reason: "automated" };
  if (isJunkPitch(fromA, subject, body)) return { kind: "skip" as const, reason: "junk" };
  // email_hey only: corporate senders and purchase orders. Forms and marketplace origins already returned above.
  if (isPurchaseOrder(subject, body)) return { kind: "skip" as const, reason: "purchase_order" };
  const named = namedPersonSalutation(body);
  const noReply = AUTOMATED_LOCAL_PART.test(emailLocalPart(fromA));
  if (isCorporateSender(fromA, subject, body)) {
    // Named-colleague mail still comes in, unless it is a no-reply or system notification.
    if (!(named && !noReply)) return { kind: "skip" as const, reason: "corporate" };
  }
  return { kind: "ingest" as const, origin: "email_hey", shop: emailShop(subject, body) };
}

async function gmailToken(): Promise<string> {
  if (cachedToken && Date.now() < cachedTokenExp - 30_000) return cachedToken;
  const clientId = Deno.env.get("GMAIL_CLIENT_ID") || "";
  const clientSecret = Deno.env.get("GMAIL_CLIENT_SECRET") || "";
  const refreshToken = Deno.env.get("GMAIL_REFRESH_TOKEN") || "";
  if (!clientId || !clientSecret || !refreshToken) {
    throw new Error("Missing GMAIL_CLIENT_ID, GMAIL_CLIENT_SECRET or GMAIL_REFRESH_TOKEN");
  }
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: clientId,
      client_secret: clientSecret,
      refresh_token: refreshToken,
      grant_type: "refresh_token",
    }),
  });
  const data = await res.json();
  if (!res.ok || !data.access_token) {
    throw new Error(`Gmail token refresh failed (${res.status})`);
  }
  cachedToken = data.access_token as string;
  cachedTokenExp = Date.now() + Number(data.expires_in || 3600) * 1000;
  return cachedToken;
}

async function gmailFetch(path: string, init: RequestInit = {}) {
  const token = await gmailToken();
  const res = await fetch(`https://gmail.googleapis.com/gmail/v1/users/me/${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      ...(init.headers || {}),
    },
  });
  const text = await res.text();
  let data: any = {};
  try {
    data = text ? JSON.parse(text) : {};
  } catch {
    data = { raw: text };
  }
  if (!res.ok) {
    const detail = data?.error?.message || data?.error || "";
    const err = new Error(`Gmail ${path.split("?")[0]} failed (${res.status}${detail ? `: ${detail}` : ""})`) as Error & { status?: number; body?: unknown };
    err.status = res.status;
    err.body = data;
    throw err;
  }
  return data;
}

async function gmailFetchRetry(path: string, init: RequestInit = {}, attempts = 5) {
  let last: unknown;
  for (let i = 0; i < attempts; i++) {
    try {
      return await gmailFetch(path, init);
    } catch (e) {
      last = e;
      const status = (e as { status?: number }).status;
      if (status === 403 || status === 429 || status === 503) {
        await new Promise((r) => setTimeout(r, 400 * (2 ** i)));
        continue;
      }
      throw e;
    }
  }
  throw last;
}

function sbAdmin(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL") || "";
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  return createClient(url, key, { auth: { persistSession: false } });
}

async function authorized(req: Request, sb: SupabaseClient): Promise<boolean> {
  const url = new URL(req.url);
  const token = url.searchParams.get("token") || req.headers.get("x-eggsy-gmail-push") || "";
  if (token) {
    const { data } = await sb.rpc("cx_gmail_hook_ok", { p_secret: token });
    if (data === true) return true;
  }
  const hook = req.headers.get("x-eggsy-hook") || "";
  if (hook) {
    const { data } = await sb.rpc("cx_email_hook_ok", { p_secret: hook });
    if (data === true) return true;
  }
  return false;
}

async function getState(sb: SupabaseClient) {
  const { data, error } = await sb.from("gmail_sync_state").select("*").eq("id", 1).maybeSingle();
  if (error) throw error;
  return data as {
    history_id: string | null;
    watch_expiration: string | null;
    watch_topic: string | null;
  } | null;
}

async function saveState(sb: SupabaseClient, patch: Record<string, unknown>) {
  const { error } = await sb.from("gmail_sync_state").update({
    ...patch,
    updated_at: new Date().toISOString(),
  }).eq("id", 1);
  if (error) throw error;
}

async function profileHistoryId(): Promise<string> {
  const profile = await gmailFetch("profile");
  return String(profile.historyId);
}

async function renewWatch(): Promise<{ historyId: string; expiration: string | null; error?: string }> {
  try {
    const data = await gmailFetch("watch", {
      method: "POST",
      body: JSON.stringify({ topicName: TOPIC_NAME, labelIds: ["INBOX"] }),
    });
    return {
      historyId: String(data.historyId),
      expiration: data.expiration ? new Date(Number(data.expiration)).toISOString() : null,
    };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return { historyId: "", expiration: null, error: msg };
  }
}

async function listMessageIdsSince(afterIso: string): Promise<string[]> {
  const afterMs = Date.parse(afterIso);
  const afterQuery = `after:${Math.floor(afterMs / 1000)}`;
  const ids: string[] = [];
  let pageToken = "";
  do {
    const params = new URLSearchParams({ q: afterQuery, maxResults: "100" });
    if (pageToken) params.set("pageToken", pageToken);
    const data = await gmailFetch(`messages?${params}`);
    for (const m of data.messages || []) ids.push(m.id);
    pageToken = data.nextPageToken || "";
  } while (pageToken);
  return ids;
}

async function listMessageIdsFromHistory(startHistoryId: string): Promise<{ ids: string[]; newHistoryId: string; stale?: boolean }> {
  const ids = new Set<string>();
  let pageToken = "";
  let newHistoryId = startHistoryId;
  try {
    do {
      const params = new URLSearchParams({
        startHistoryId,
        maxResults: "500",
      });
      if (pageToken) params.set("pageToken", pageToken);
      const data = await gmailFetch(`history?${params}`);
      newHistoryId = String(data.historyId || newHistoryId);
      for (const h of data.history || []) {
        for (const added of h.messagesAdded || []) {
          if (added.message?.id) ids.add(added.message.id);
        }
      }
      pageToken = data.nextPageToken || "";
    } while (pageToken);
    return { ids: [...ids], newHistoryId };
  } catch (e) {
    const status = (e as { status?: number }).status;
    if (status === 404) return { ids: [], newHistoryId: startHistoryId, stale: true };
    throw e;
  }
}

async function findExistingMessage(sb: SupabaseClient, messageId: string) {
  const { data } = await sb
    .from("messages")
    .select("id, conversation_id")
    .eq("external_id", `${GMAIL_PREFIX}${messageId}`)
    .maybeSingle();
  return data;
}

async function findConversation(
  sb: SupabaseClient,
  origin: string,
  threadId: string,
  orderNumber: string | null,
) {
  const { data: byThread } = await sb
    .from("conversations")
    .select("id, status, customer_handle, order_number, subject, last_message_at")
    .eq("external_id", `${GMAIL_PREFIX}${threadId}`)
    .maybeSingle();
  if (byThread) return byThread;

  const { data: byMsgThread } = await sb
    .from("messages")
    .select("conversation_id")
    .eq("external_thread_id", threadId)
    .limit(1)
    .maybeSingle();
  if (byMsgThread?.conversation_id) {
    const { data } = await sb
      .from("conversations")
      .select("id, status, customer_handle, order_number, subject, last_message_at")
      .eq("id", byMsgThread.conversation_id)
      .maybeSingle();
    if (data) return data;
  }

  if (orderNumber && /^[0-9-]+$/.test(orderNumber) && origin.startsWith("amazon")) {
    const { data: byExt } = await sb
      .from("conversations")
      .select("id, status, customer_handle, order_number, subject, last_message_at")
      .eq("origin", origin)
      .eq("external_id", `amazon:${orderNumber}`)
      .maybeSingle();
    if (byExt) return byExt;
    const { data: byOrder } = await sb
      .from("conversations")
      .select("id, status, customer_handle, order_number, subject, last_message_at")
      .eq("origin", origin)
      .eq("order_number", orderNumber)
      .limit(1)
      .maybeSingle();
    if (byOrder) return byOrder;
  }
  return null;
}

type ConversationRow = {
  id: string;
  status?: string | null;
  customer_handle?: string | null;
  order_number?: string | null;
  subject?: string | null;
  last_message_at?: string | null;
};

type IngestOpts = {
  afterMs?: number;
  historical?: boolean;
};

function newerThan(sentAt: string, current?: string | null) {
  if (!current) return true;
  return Date.parse(sentAt) > Date.parse(current);
}

async function fetchThreadMessages(threadId: string): Promise<GmailMessage[]> {
  const t = await gmailFetchRetry(`threads/${encodeURIComponent(threadId)}?format=full`);
  const msgs = (t.messages || []) as GmailMessage[];
  return msgs
    .filter((m) => !(m.labelIds || []).includes("DRAFT"))
    .sort((a, b) => Number(a.internalDate || 0) - Number(b.internalDate || 0));
}

function parseQuotedDate(raw: string, outbound: boolean): string | null {
  const cleaned = raw.replace(/\s+/g, " ").trim();
  const tryParse = (value: string) => {
    const t = Date.parse(value);
    if (!Number.isFinite(t)) return null;
    const iso = new Date(t).toISOString();
    // Reject dates with no year (e.g. "Wed, Sep 2" -> 2001).
    if (new Date(t).getUTCFullYear() < 2020) return null;
    return iso;
  };
  const hasTz = /\b(UTC|GMT|BST|EDT|EST|CDT|CST|MDT|MST|PDT|PST|CEST|CET|Z|[+-]\d{2}:?\d{2})\b/i.test(cleaned);
  const noAt = cleaned.replace(/\s+at\s+/gi, " ");
  if (hasTz) return tryParse(cleaned) || tryParse(noAt);
  const months = ["jan","feb","mar","apr","may","jun","jul","aug","sep","sept","oct","nov","dec"];
  const monRaw = cleaned.match(/\b(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)\b/i)?.[1]?.toLowerCase() || "";
  const month = monRaw.startsWith("sep") ? 8 : Math.max(0, months.indexOf(monRaw));
  // Customer-side quotes often omit a timezone; use Eastern, which matches
  // Janet West and most US hey@ threads. Our own Gmail quotes default to London.
  const summer = month >= 2 && month <= 9;
  const tz = outbound ? (summer ? "BST" : "GMT") : (summer ? "EDT" : "EST");
  return tryParse(`${noAt} ${tz}`) || tryParse(`${cleaned} ${tz}`) || tryParse(noAt) || tryParse(cleaned);
}

function parseQuoteHeader(header: string): { author: string; addr: string; sentAt: string | null; outbound: boolean } {
  const cleaned = header.replace(/^[>\s]*/g, "").replace(/^On\s+/i, "").replace(/\s+wrote:\s*$/i, "").trim();
  const withAddr = cleaned.match(/^(.*?)\s*<([^>]+)>\s*$/);
  const addr = (withAddr?.[2] || "").trim().toLowerCase();
  const before = (withAddr?.[1] || cleaned).trim();
  const outbound = addr === HEY || addr.endsWith("@luckyegg.co") || /\blucky egg\b/i.test(cleaned);
  let author = "";
  let dateRaw = before;
  const commaName = before.match(/^(.*),\s*([^,]+)$/);
  if (commaName && !/\d/.test(commaName[2]) && !/\b(?:AM|PM|UTC|GMT|BST|EDT|EST|CDT|CST|PDT|PST)\b/i.test(commaName[2])) {
    dateRaw = commaName[1].trim();
    author = commaName[2].trim();
  } else {
    const trailing = before.match(/^(.*)\s+([A-Z][a-zA-Z'.-]+(?:\s+[A-Z][a-zA-Z'.-]+)+)$/);
    if (trailing && !/\b(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|Mon|Tue|Wed|Thu|Fri|Sat|Sun|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\b/i.test(trailing[2])) {
      dateRaw = trailing[1].trim();
      author = trailing[2].trim();
    }
  }
  if (outbound) author = author && !/^lucky egg$/i.test(author) ? author : "Lucky Egg (hey@)";
  if (!author) author = addr ? nameOf(`${before} <${addr}>`) : (addr || "Unknown");
  return { author, addr, sentAt: parseQuotedDate(dateRaw, outbound), outbound };
}

function splitQuotedHistory(fullBody: string): { latest: string; quoted: Array<{ header: string; body: string }> } {
  const src = (fullBody || "").replace(/\r\n/g, "\n");
  const re = /^[ \t]*(?:>[ \t]*)*On\s+.+\s+wrote:\s*$/gim;
  const quoted: Array<{ header: string; body: string }> = [];
  let last = 0;
  let header: string | null = null;
  let firstBody = "";
  let m: RegExpExecArray | null;
  while ((m = re.exec(src))) {
    const chunk = src.slice(last, m.index).replace(/^[ \t]+|[ \t]+$/gm, "").trim();
    if (header) quoted.push({ header, body: chunk });
    else firstBody = chunk;
    header = m[0].replace(/^[ \t]+(?:>[ \t]*)*/gm, "").trim();
    last = m.index + m[0].length;
  }
  if (header) quoted.push({ header, body: src.slice(last).replace(/^[ \t]+|[ \t]+$/gm, "").trim() });
  else firstBody = src.trim();
  return { latest: firstBody, quoted: quoted.filter((q) => q.body) };
}

function dequoteBody(s: string) {
  return (s || "")
    .replace(/\r\n/g, "\n")
    .split("\n")
    .map((line) => line.replace(/^[ \t]*>+[ \t]?/, ""))
    .join("\n")
    .trim();
}

function normalizeBody(s: string) {
  return dequoteBody(s).replace(/\s+/g, " ").trim().toLowerCase();
}

function isBoilerplateQuote(body: string) {
  const n = normalizeBody(body);
  if (!n) return true;
  if (/you received a new message from your online store/.test(n)) return true;
  if (/you received this message because/.test(n)) return true;
  if (/luckyegg\.co\/_t\/c\//.test(n) || /\/_t\/c\/v3\//.test(n)) return true;
  if (/^sent from (?:my i(phone|pad)|mail for i(phone|pad)|yahoo mail)/.test(n) && n.length < 80) return true;
  return false;
}

async function ingestQuotedHistory(
  sb: SupabaseClient,
  conv: ConversationRow,
  threadId: string,
  sourceBodies: string[],
) {
  const { data: existing } = await sb
    .from("messages")
    .select("id, body, external_id, sent_at, direction")
    .eq("conversation_id", conv.id);
  const known = new Set((existing || []).map((m) => normalizeBody(m.body || "")));
  let added = 0;
  // Quotes are newest-first in the email; reverse so we insert oldest first.
  const parts: Array<{ header: string; body: string }> = [];
  for (const body of sourceBodies) {
    const split = splitQuotedHistory(body);
    parts.push(...split.quoted);
  }
  const seen = new Set<string>();
  for (const part of parts.reverse()) {
    const body = dequoteBody(part.body);
    const key = normalizeBody(body);
    if (!key || key.length < 12 || known.has(key) || seen.has(key) || isBoilerplateQuote(body)) continue;
    seen.add(key);
    const meta = parseQuoteHeader(part.header);
    const sentAt = meta.sentAt || conv.last_message_at || new Date().toISOString();
    const stamp = meta.sentAt || `undated-${added + 1}`;
    const externalId = `gmail-quoted:${threadId}:${stamp}`;
    const { error } = await sb.from("messages").insert({
      conversation_id: conv.id,
      direction: meta.outbound ? "outbound" : "inbound",
      author: meta.author,
      body,
      sent_at: sentAt,
      external_id: externalId,
      external_thread_id: threadId,
    });
    if (error) {
      if (String(error.message || "").toLowerCase().includes("duplicate")) continue;
      console.error("quoted history insert failed", threadId, error.message);
      continue;
    }
    known.add(key);
    added += 1;
  }
  return added;
}

// Shared SQL classifier. Colleague and Marty forwards have already been decided by the caller.
async function tagMmc(sb: SupabaseClient, conversationId: string, forwarded: boolean) {
  if (forwarded) {
    const { error } = await sb.from("conversations").update({ is_mmc: false }).eq("id", conversationId);
    if (error) console.error("mmc clear failed", conversationId, error.message);
    return;
  }
  const { error } = await sb.rpc("cx_refresh_conversation_mmc", { p_id: conversationId });
  if (error) console.error("mmc tag failed", conversationId, error.message);
}

async function ingestMessage(sb: SupabaseClient, msg: GmailMessage, opts: IngestOpts = {}) {
  const afterMs = opts.afterMs;
  const sentAtMs = Number(msg.internalDate || 0);
  if (afterMs && !opts.historical && sentAtMs && sentAtMs < afterMs) return { action: "skipped", reason: "before_cutoff" };

  const existing = await findExistingMessage(sb, msg.id);
  if (existing) return { action: "skipped", reason: "duplicate" };

  const from = headerValue(msg.payload?.headers, "From");
  const replyTo = headerValue(msg.payload?.headers, "Reply-To");
  const subject = headerValue(msg.payload?.headers, "Subject") || "(no subject)";
  const rawBody = extractBody(msg.payload);
  const body = rawBody.replace(/\r\n/g, "\n").trim() || msg.snippet || "";
  const sentAt = sentAtMs ? new Date(sentAtMs).toISOString() : new Date().toISOString();
  const classified = classify(msg, from, replyTo, subject, body);

  if (classified.kind === "skip") return { action: "skipped", reason: classified.reason };

  if (classified.kind === "outgoing") {
    const conv = await findConversation(sb, "email_hey", msg.threadId, extractOrderNumber(subject, body));
    if (!conv) return { action: "skipped", reason: "outgoing_no_ticket" };
    const { error } = await sb.from("messages").insert({
      conversation_id: conv.id,
      direction: "outbound",
      author: "Lucky Egg (hey@)",
      body,
      sent_at: sentAt,
      external_id: `${GMAIL_PREFIX}${msg.id}`,
      external_thread_id: msg.threadId,
    });
    if (error) {
      if (String(error.message || "").toLowerCase().includes("duplicate")) {
        return { action: "skipped", reason: "duplicate" };
      }
      throw error;
    }
    const outUpdates: Record<string, unknown> = { updated_at: new Date().toISOString() };
    if (newerThan(sentAt, conv.last_message_at)) outUpdates.last_message_at = sentAt;
    await sb.from("conversations").update(outUpdates).eq("id", conv.id);
    conv.last_message_at = (outUpdates.last_message_at as string) || conv.last_message_at;
    return { action: "logged_outgoing", conversation_id: conv.id };
  }

  let customerName = nameOf(from);
  let customerHandle = addrOf(from);
  let storedBody = body;
  if (classified.origin === "shopify_form") {
    const parsed = parseShopifyForm(body, replyTo);
    if (parsed.name) customerName = parsed.name;
    if (parsed.email) customerHandle = parsed.email;
    storedBody = parsed.comment;
  } else if (replyTo && addrOf(replyTo) && addrOf(replyTo) !== addrOf(from) && !addrOf(from).includes("marketplace.amazon.")) {
    // Prefer a real customer reply-to when the visible From is a mailer.
    if (from.toLowerCase().includes("mailer") || from.toLowerCase().includes("no-reply") || from.toLowerCase().includes("via ")) {
      customerHandle = addrOf(replyTo);
    }
  }

  const orderNumber = extractOrderNumber(subject, storedBody);
  let conv = await findConversation(sb, classified.origin, msg.threadId, orderNumber);

  const now = new Date().toISOString();

  if (!conv) {
    const insert = {
      origin: classified.origin,
      shop: classified.shop,
      customer_name: customerName || customerHandle,
      customer_handle: customerHandle,
      subject,
      order_number: orderNumber,
      status: "open",
      external_id: `${GMAIL_PREFIX}${msg.threadId}`,
      last_message_at: sentAt,
      topic: inferTopic(subject, storedBody),
      created_at: now,
      updated_at: now,
    };
    const { data, error } = await sb.from("conversations").insert(insert).select("id, status, customer_handle, order_number, subject, last_message_at").maybeSingle();
    if (error) {
      const again = await findConversation(sb, classified.origin, msg.threadId, orderNumber);
      if (!again) throw error;
      conv = again;
    } else {
      conv = data!;
    }
  }

  const { error: msgErr } = await sb.from("messages").insert({
    conversation_id: conv.id,
    direction: "inbound",
    author: customerName || customerHandle,
    body: storedBody,
    sent_at: sentAt,
    external_id: `${GMAIL_PREFIX}${msg.id}`,
    external_thread_id: msg.threadId,
  });
  if (msgErr) {
    if (String(msgErr.message || "").toLowerCase().includes("duplicate")) {
      return { action: "skipped", reason: "duplicate" };
    }
    throw msgErr;
  }

  const reopen = !opts.historical && (conv.status === "awaiting_customer" || conv.status === "resolved");
  const updates: Record<string, unknown> = {
    updated_at: now,
  };
  if (newerThan(sentAt, conv.last_message_at)) updates.last_message_at = sentAt;
  if (reopen) {
    updates.status = "open";
    updates.status_changed_at = now;
  }
  if (!conv.customer_handle && customerHandle) updates.customer_handle = customerHandle;
  if (!conv.order_number && orderNumber) updates.order_number = orderNumber;
  if (!conv.subject && subject) updates.subject = subject;
  await sb.from("conversations").update(updates).eq("id", conv.id);
  if (updates.last_message_at) conv.last_message_at = updates.last_message_at as string;
  let forward: { action: string; detail?: string } | undefined;
  if (!opts.historical) {
    try {
      forward = await maybeAutoForward(sb, gmailFetchRetry, {
        conv: { ...conv, origin: classified.origin, customer_name: customerName || conv.customer_handle },
        origin: classified.origin,
        body: storedBody,
        subject,
        orderNumber,
        sourceExternalId: `${GMAIL_PREFIX}${msg.id}`,
        historical: opts.historical,
        customerName,
        sentAt,
      });
    } catch (e) {
      console.error("maybeAutoForward failed", conv.id, e instanceof Error ? e.message : e);
    }
  }
  // Junk, corporate, colleague-forward and Marty-forward have already run (classify skips
  // the first two; maybeAutoForward does the forwards). Only then tag the ticket.
  await tagMmc(sb, conv.id, forward?.action === "forward");
  return { action: "ingested", conversation_id: conv.id, reopened: reopen, forward };
}


const ANSWERED_LABEL_NAME = "answered";
let answeredLabelId: string | null = null;

function isLuckyEggAddress(from: string): boolean {
  const a = addrOf(from);
  return a === HEY || a.endsWith("@luckyegg.co");
}

async function ensureAnsweredLabel(): Promise<string> {
  if (answeredLabelId) return answeredLabelId;
  const list = await gmailFetch("labels");
  const found = (list.labels || []).find((l: any) => l.name === ANSWERED_LABEL_NAME);
  if (found?.id) return (answeredLabelId = found.id);
  const created = await gmailFetch("labels", {
    method: "POST",
    body: JSON.stringify({
      name: ANSWERED_LABEL_NAME,
      labelListVisibility: "labelShow",
      messageListVisibility: "show",
    }),
  });
  return (answeredLabelId = created.id);
}

async function markThreadAnswered(threadId: string) {
  if (!threadId) return;
  const id = await ensureAnsweredLabel();
  await gmailFetch("threads/" + threadId + "/modify", {
    method: "POST",
    body: JSON.stringify({ addLabelIds: [id], removeLabelIds: ["INBOX"] }),
  });
}

async function markThreadUnanswered(threadId: string) {
  if (!threadId) return;
  const id = await ensureAnsweredLabel();
  await gmailFetch("threads/" + threadId + "/modify", {
    method: "POST",
    body: JSON.stringify({ addLabelIds: ["INBOX"], removeLabelIds: [id] }),
  });
}

async function reconcileAnsweredLabel(threadId: string) {
  if (!threadId) return;
  const t = await gmailFetchRetry("threads/" + threadId + "?format=metadata&metadataHeaders=From");
  const msgs = (t.messages || []).filter((m: any) => {
    const labels = m.labelIds || [];
    return !labels.includes("DRAFT") && !labels.includes("TRASH") && !labels.includes("SPAM");
  });
  const last = msgs.length ? msgs[msgs.length - 1] : null;
  const from = last ? headerValue(last.payload?.headers, "From") : "";
  if (from && isLuckyEggAddress(from)) await markThreadAnswered(threadId);
  else await markThreadUnanswered(threadId);
}

async function ingestQuotedFromExisting(sb: SupabaseClient, conv: ConversationRow, threadId: string) {
  const { data: existingMsgs } = await sb
    .from("messages")
    .select("body")
    .eq("conversation_id", conv.id);
  const bodies = (existingMsgs || []).map((m) => (m.body || "").replace(/\r\n/g, "\n").trim()).filter(Boolean);
  if (!bodies.length) return 0;
  return await ingestQuotedHistory(sb, conv, threadId, bodies);
}

async function ingestFullThread(
  sb: SupabaseClient,
  threadId: string,
  opts: { afterMs?: number; triggerIds?: Set<string>; historicalOnly?: boolean } = {},
) {
  const counts = { ingested: 0, skipped: 0, logged_outgoing: 0, quoted: 0, errors: 0, conversation_id: "" as string };
  let msgs: GmailMessage[] = [];
  try {
    msgs = await fetchThreadMessages(threadId);
  } catch (e) {
    const status = (e as { status?: number }).status;
    if (status === 404) {
      const conv = await findConversation(sb, "email_hey", threadId, null);
      if (conv?.id) {
        counts.quoted = await ingestQuotedFromExisting(sb, conv, threadId);
        counts.conversation_id = conv.id;
      }
      return { ...counts, missing: true as const };
    }
    throw e;
  }
  if (!msgs.length) return { ...counts, missing: false as const };

  const existing = await findConversation(sb, "email_hey", threadId, null);
  const inbound = [];
  const outbound = [];
  for (const msg of msgs) {
    const from = headerValue(msg.payload?.headers, "From");
    const replyTo = headerValue(msg.payload?.headers, "Reply-To");
    const subject = headerValue(msg.payload?.headers, "Subject") || "(no subject)";
    const body = extractBody(msg.payload);
    const classified = classify(msg, from, replyTo, subject, body);
    const sentAtMs = Number(msg.internalDate || 0);
    const isTrigger = opts.triggerIds ? opts.triggerIds.has(msg.id) : (!opts.afterMs || !sentAtMs || sentAtMs >= opts.afterMs);
    const historical = Boolean(opts.historicalOnly || !isTrigger);
    if (classified.kind === "outgoing") outbound.push({ msg, historical });
    else inbound.push({ msg, historical, classified });
  }

  const hasIngestibleInbound = inbound.some((row) => {
    if (row.classified.kind === "skip") return false;
    if (opts.historicalOnly) return true;
    if (existing) return true;
    return !row.historical;
  });
  if (!existing && !hasIngestibleInbound && outbound.length && !opts.historicalOnly) {
    // Keep previous behaviour for brand-new threads that only contain our sent mail.
    counts.skipped += msgs.length;
    return { ...counts, missing: false as const };
  }

  for (const row of inbound) {
    try {
      const result = await ingestMessage(sb, row.msg, { historical: row.historical });
      if (result.action === "ingested") {
        counts.ingested += 1;
        if (result.conversation_id) counts.conversation_id = result.conversation_id;
      } else if (result.action === "logged_outgoing") {
        counts.logged_outgoing += 1;
        if (result.conversation_id) counts.conversation_id = result.conversation_id;
      } else {
        counts.skipped += 1;
        if ((result as { conversation_id?: string }).conversation_id) {
          counts.conversation_id = (result as { conversation_id: string }).conversation_id;
        }
      }
    } catch (e) {
      counts.errors += 1;
      console.error("gmail-push thread inbound failed", threadId, row.msg.id, e instanceof Error ? e.message : e);
    }
  }
  for (const row of outbound) {
    try {
      const result = await ingestMessage(sb, row.msg, { historical: row.historical });
      if (result.action === "logged_outgoing") {
        counts.logged_outgoing += 1;
        if (result.conversation_id) counts.conversation_id = result.conversation_id;
      } else if (result.action === "ingested") {
        counts.ingested += 1;
        if (result.conversation_id) counts.conversation_id = result.conversation_id;
      } else {
        counts.skipped += 1;
      }
    } catch (e) {
      counts.errors += 1;
      console.error("gmail-push thread outbound failed", threadId, row.msg.id, e instanceof Error ? e.message : e);
    }
  }

  const conv = counts.conversation_id
    ? { id: counts.conversation_id } as ConversationRow
    : await findConversation(sb, "email_hey", threadId, null);
  if (conv?.id) {
    const bodies = msgs.map((m) => extractBody(m.payload).replace(/\r\n/g, "\n").trim()).filter(Boolean);
    try {
      counts.quoted = await ingestQuotedHistory(sb, conv, threadId, bodies);
    } catch (e) {
      console.error("gmail-push quoted history failed", threadId, e instanceof Error ? e.message : e);
    }
    counts.conversation_id = conv.id;
  }
  return { ...counts, missing: false as const };
}

async function backfillExistingThreads(
  sb: SupabaseClient,
  opts: { offset?: number; limit?: number; conversationId?: string } = {},
) {
  const limit = Math.min(Math.max(opts.limit || 25, 1), 80);
  const offset = Math.max(opts.offset || 0, 0);
  const deadline = Date.now() + 100_000;
  let q = sb
    .from("conversations")
    .select("id, origin, external_id")
    .in("origin", ["email_hey", "shopify_form", "wix_mmc_form"])
    .like("external_id", "gmail:%")
    .order("created_at", { ascending: true })
    .order("id", { ascending: true });
  if (opts.conversationId) q = q.eq("id", opts.conversationId);
  else q = q.range(offset, offset + limit - 1);
  const { data, error } = await q;
  if (error) throw error;
  const rows = data || [];
  const summary = {
    scanned: 0,
    ingested: 0,
    logged_outgoing: 0,
    quoted: 0,
    skipped: 0,
    errors: 0,
    missing_threads: 0,
    conversation_ids: [] as string[],
    timed_out: false,
  };
  for (const row of rows) {
    if (Date.now() > deadline) {
      summary.timed_out = true;
      break;
    }
    summary.scanned += 1;
    const threadId = String(row.external_id || "").replace(/^gmail:/, "");
    if (!threadId) continue;
    try {
      const result = await ingestFullThread(sb, threadId, { historicalOnly: true });
      summary.ingested += result.ingested;
      summary.logged_outgoing += result.logged_outgoing;
      summary.quoted += result.quoted;
      summary.skipped += result.skipped;
      summary.errors += result.errors;
      if (result.missing) summary.missing_threads += 1;
      if (result.ingested || result.logged_outgoing || result.quoted) {
        summary.conversation_ids.push(row.id);
      }
    } catch (e) {
      summary.errors += 1;
      console.error("gmail-push backfill thread failed", threadId, e instanceof Error ? e.message : e);
    }
  }
  const nextOffset = offset + summary.scanned;
  const done = !summary.timed_out && rows.length < limit;
  return { ...summary, offset, next_offset: nextOffset, done, batch: rows.length };
}

async function backfillQuotedFallback(
  sb: SupabaseClient,
  opts: { offset?: number; limit?: number } = {},
) {
  const limit = Math.min(Math.max(opts.limit || 50, 1), 100);
  const offset = Math.max(opts.offset || 0, 0);
  const deadline = Date.now() + 100_000;
  const { data, error } = await sb
    .from("conversations")
    .select("id, origin, external_id")
    .in("origin", ["email_hey", "shopify_form", "wix_mmc_form"])
    .like("external_id", "gmail:%")
    .order("created_at", { ascending: true })
    .order("id", { ascending: true })
    .range(offset, offset + limit - 1);
  if (error) throw error;
  const rows = data || [];
  const summary = {
    scanned: 0,
    quoted: 0,
    errors: 0,
    conversation_ids: [] as string[],
    timed_out: false,
  };
  for (const row of rows) {
    if (Date.now() > deadline) {
      summary.timed_out = true;
      break;
    }
    summary.scanned += 1;
    const threadId = String(row.external_id || "").replace(/^gmail:/, "");
    if (!threadId) continue;
    try {
      const added = await ingestQuotedFromExisting(sb, { id: row.id }, threadId);
      if (added) {
        summary.quoted += added;
        summary.conversation_ids.push(row.id);
      }
    } catch (e) {
      summary.errors += 1;
      console.error("gmail-push quoted fallback failed", threadId, e instanceof Error ? e.message : e);
    }
  }
  const nextOffset = offset + summary.scanned;
  const done = !summary.timed_out && rows.length < limit;
  return { ...summary, offset, next_offset: nextOffset, done, batch: rows.length };
}

async function processIds(sb: SupabaseClient, ids: string[], afterMs?: number) {
  const counts = { ingested: 0, skipped: 0, logged_outgoing: 0, quoted: 0, errors: 0 };
  const ingested: string[] = [];
  const triggerThreads = new Map<string, Set<string>>();
  for (const id of ids) {
    try {
      const meta = await gmailFetchRetry(
        `messages/${id}?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Subject&metadataHeaders=Reply-To`,
      ) as GmailMessage;
      const sentAtMs = Number(meta.internalDate || 0);
      if (afterMs && sentAtMs && sentAtMs < afterMs) {
        counts.skipped += 1;
        continue;
      }
      const from = headerValue(meta.payload?.headers, "From");
      const replyTo = headerValue(meta.payload?.headers, "Reply-To");
      const subject = headerValue(meta.payload?.headers, "Subject") || "(no subject)";
      const pre = classify(meta, from, replyTo, subject, meta.snippet || "");
      if (pre.kind === "skip") {
        counts.skipped += 1;
        continue;
      }
      const threadId = meta.threadId || id;
      if (!triggerThreads.has(threadId)) triggerThreads.set(threadId, new Set());
      triggerThreads.get(threadId)!.add(meta.id);
    } catch (e) {
      counts.errors += 1;
      console.error("gmail-push ingest failed", id, e instanceof Error ? e.message : e);
    }
  }
  for (const [threadId, triggerIds] of triggerThreads) {
    try {
      const result = await ingestFullThread(sb, threadId, { afterMs, triggerIds });
      counts.ingested += result.ingested;
      counts.logged_outgoing += result.logged_outgoing;
      counts.quoted += result.quoted;
      counts.skipped += result.skipped;
      counts.errors += result.errors;
      if (result.conversation_id && (result.ingested || result.logged_outgoing)) {
        ingested.push(result.conversation_id);
      }
      try { await reconcileAnsweredLabel(threadId); }
      catch (e) { console.error("answered-label reconcile failed", threadId, e instanceof Error ? e.message : e); }
    } catch (e) {
      counts.errors += 1;
      console.error("gmail-push thread ingest failed", threadId, e instanceof Error ? e.message : e);
    }
  }
  return { ...counts, conversation_ids: [...new Set(ingested)] };
}

async function maybeRenewWatch(sb: SupabaseClient, force = false) {
  const state = await getState(sb);
  const exp = state?.watch_expiration ? Date.parse(state.watch_expiration) : 0;
  if (!force && exp && exp - Date.now() > WATCH_RENEW_MS) {
    return { renewed: false, expiration: state?.watch_expiration, error: null as string | null };
  }
  const watch = await renewWatch();
  if (watch.error) {
    const prev = await getState(sb);
    await saveState(sb, { last_error: [ (prev as any)?.last_error, `watch: ${watch.error}` ].filter(Boolean).join("; ") });
    return { renewed: false, expiration: state?.watch_expiration || null, error: watch.error };
  }
  const patch: Record<string, unknown> = {
    watch_expiration: watch.expiration,
    watch_topic: TOPIC_NAME,
    last_error: null,
  };
  if (watch.historyId && !state?.history_id) patch.history_id = watch.historyId;
  await saveState(sb, patch);
  return { renewed: true, expiration: watch.expiration, error: null as string | null };
}

async function runSync(sb: SupabaseClient, opts: { after?: string; watch?: boolean }) {
  const afterMs = opts.after ? Date.parse(opts.after) : undefined;
  let ids: string[] = [];
  const state = await getState(sb);
  let nextHistoryId = state?.history_id || "";

  if (opts.after) {
    ids = await listMessageIdsSince(opts.after);
    nextHistoryId = await profileHistoryId();
  } else if (state?.history_id) {
    const hist = await listMessageIdsFromHistory(state.history_id);
    if (hist.stale) {
      const fallbackAfter = new Date(Date.now() - 2 * 24 * 60 * 60 * 1000).toISOString();
      ids = await listMessageIdsSince(fallbackAfter);
      nextHistoryId = await profileHistoryId();
    } else {
      ids = hist.ids;
      nextHistoryId = hist.newHistoryId;
    }
  } else {
    nextHistoryId = await profileHistoryId();
  }

  const processed = await processIds(sb, ids, afterMs);
  await saveState(sb, {
    history_id: nextHistoryId,
    last_synced_at: new Date().toISOString(),
    last_result: processed,
    last_error: processed.errors ? `${processed.errors} message errors` : null,
  });

  let watch: { renewed: boolean; expiration: string | null; error: string | null } | undefined;
  if (opts.watch !== false) {
    watch = await maybeRenewWatch(sb, opts.watch === true);
  }
  return { ...processed, history_id: nextHistoryId, watch };
}

Deno.serve(async (req: Request) => {
  if (req.method === "GET") {
    return json({ ok: true, service: "gmail-push", version: FUNCTION_VERSION });
  }
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const sb = sbAdmin();
  if (!(await authorized(req, sb))) return json({ error: "unauthorized" }, 401);

  let body: any = {};
  try {
    body = await req.json();
  } catch {
    body = {};
  }

  const isPubSub = Boolean(body?.message?.data || body?.message?.messageId);
  const mode = isPubSub ? "sync" : (body.mode || "sync");

  try {
    const fwd = await handleForwardModes(sb, gmailFetchRetry, { ...body, mode });
    if (fwd.handled) return json(fwd.response);
    if (mode === "watch") {
      const watch = await maybeRenewWatch(sb, true);
      return json({ ok: !watch.error, mode, watch });
    }
    if (mode === "backfill_threads") {
      const result = await backfillExistingThreads(sb, {
        offset: Number(body.offset || 0),
        limit: body.limit,
        conversationId: body.conversation_id,
      });
      return json({ ok: true, mode, ...result });
    }
    if (mode === "backfill_quoted_fallback") {
      const result = await backfillQuotedFallback(sb, {
        offset: Number(body.offset || 0),
        limit: body.limit,
      });
      return json({ ok: true, mode, ...result });
    }
    const after = mode === "backfill" ? (body.after || "2026-11-05T11:15:00Z") : body.after;
    const result = await runSync(sb, { after, watch: mode !== "backfill" || body.watch === true });
    return json({ ok: true, mode, ...result });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("gmail-push failed", message);
    try {
      await saveState(sb, { last_error: message, last_synced_at: new Date().toISOString() });
    } catch {
      // ignore state write failures
    }
    return json({ ok: false, error: message }, 500);
  }
});
