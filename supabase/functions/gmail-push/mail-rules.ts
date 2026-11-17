/** Greeting, colleague-name and creative-collaboration rules for gmail-push v14. */

export const EMAIL_CS_ORIGINS = new Set(["email_hey", "shopify_form", "wix_mmc_form"]);

const GENERIC_ADDRESSEES = new Set([
  "lucky", "egg", "team", "sir", "madam", "madame", "sirs", "customer", "seller",
  "support", "service", "all", "everyone", "everybody", "friend", "friends",
  "valued", "whom", "vendor", "partner", "partners", "there", "store", "shop",
  "company", "manager", "managers", "colleague", "colleagues", "staff", "user",
  "users", "buyer", "buyers", "member", "members", "client", "clients", "player",
  "players",
]);

/** CS colleagues: do not auto-forward their order or ongoing customer threads. */
const CS_FIRST_NAMES = new Set([
  "mich", "michelle", "kim", "kimberly", "kimberley", "hatty", "harriet",
]);

export type Salutation = { greeting: string; name: string; rest: string[] };

export function firstCustomerLine(body: string): string {
  let text = (body || "").replace(/^\uFEFF/, "").replace(/\r\n/g, "\n");
  const comment = text.match(/(?:^|\n)\s*(?:Comment|Message|Body):\s*([\s\S]+)/i);
  if (comment) text = comment[1];
  for (const line of text.split("\n")) {
    const t = line.replace(/[\u00a0\u200b]/g, " ").trim();
    if (t) return t;
  }
  return "";
}

/** Opening "Dear/Hi/Hello/Hey <Name>" addressed to a personal name, not a team or role. */
export function namedPersonSalutation(body: string): Salutation | null {
  const line = firstCustomerLine(body);
  if (!line) return null;
  const m = line.match(/^((?:dear|hi|hello|hey))\s+(?:((?:mr|ms|mrs|miss|dr|prof)\.?)\s+)?(.+?)\s*[,:]?\s*$/i);
  if (!m) return null;
  const greeting = m[1].toLowerCase();
  const rest = (m[3] || "").trim();
  if (!rest) return null;
  if (/^(sir|madam|madame)(?:\s*(?:\/|or)\s*(sir|madam|madame))?$/i.test(rest)) return null;
  if (/^to whom it may concern$/i.test(rest)) return null;
  const tokens = rest.split(/\s+/).filter(Boolean);
  if (!tokens.length) return null;
  const name = tokens[0].replace(/[."]+$/g, "");
  if (!/^[A-Z][A-Za-z''-]*$/.test(name)) return null;
  if (GENERIC_ADDRESSEES.has(name.toLowerCase())) return null;
  for (const tok of tokens.slice(1)) {
    const clean = tok.replace(/[."]+$/g, "");
    if (!/^[A-Z][A-Za-z''-]*$/.test(clean)) return null;
  }
  return { greeting, name, rest: tokens.slice(1).map((t) => t.replace(/[."]+$/g, "")) };
}

export function isProtectedCsCustomerThread(name: string, orderNumber: string | null, hasPriorReply: boolean): boolean {
  if (!CS_FIRST_NAMES.has(name.toLowerCase())) return false;
  return Boolean(orderNumber) || hasPriorReply;
}

function isVendorOrAgencyPitch(hay: string): boolean {
  if (/\b(?:seo|search engine optimi[sz]ation|media buy|ppc|klaviyo|marketing agency|performance marketing|google ads|meta ads)\b/.test(hay)
    && /\b(?:agency|service|services|audit|ranking|campaign|ads?|optimisation|optimization)\b/.test(hay)) {
    return true;
  }
  if (/\b(?:freight forward|oem|odm|sourcing from china)\b/.test(hay)) return true;
  if (/\b(?:moq|minimum order|wholesale|trade account|price list|lead times?)\b/.test(hay)
    && /\b(?:retail|store|shop|account|units?|stock|wholesale|b2b)\b/.test(hay)) {
    return true;
  }
  if (/\b(?:influencer|tiktok (?:account|creator|campaign)|instagram (?:account|influencer)|gifting collaboration|sponsored post|creator (?:collab|collaboration))\b/.test(hay)) {
    return true;
  }
  if (
    /\b(?:press|editorial|review(?:s|er)? site|magazine|feature article)\b/.test(hay)
    && /\b(?:feature|coverage|article|review)\b/.test(hay)
    && !/\b(?:illustrat|portfolio|game designer|invent)\b/.test(hay)
  ) {
    return true;
  }
  return false;
}

/**
 * Freelance illustrators, artists, designers and game inventors offering to work
 * with Lucky Egg. Not job applications, not vendor/SEO/marketing/influencer pitches.
 */
export function isCreativeCollaboration(subject: string, body: string): boolean {
  const hay = `${subject}\n${body}`.toLowerCase();
  if (isVendorOrAgencyPitch(hay)) return false;
  const creativeRole = /\b(?:illustrators?|illustration|illustrat(?:ing|ed)|concept artists?|character artists?|game artists?|game designers?|game invent(?:or|ers?)|board[- ]?game designers?|card[- ]?game designers?|graphic designers?|freelance(?:r)? (?:illustrator|designer|artist)s?)\b/.test(hay)
    || /\b(?:i am|i'm|i[’']m|as an?)\s+(?:an?\s+)?(?:illustrator|artist|designer)\b/.test(hay);
  const portfolio = /\b(?:portfolio|behance\.net|artstation\.com|dribbble\.com)\b/.test(hay);
  const offer = /\b(?:work together|working together|collaborate|collaboration|work with (?:you|lucky egg)|interested in working)\b/.test(hay);
  const invented = /\b(?:i(?:'ve| have|’ve)? (?:invented|designed|created|made) (?:a |an )?(?:new )?(?:board |card |tabletop )?game)\b/.test(hay)
    || /\b(?:my (?:board |card |tabletop )?game (?:idea|design|prototype|pitch))\b/.test(hay);
  if (invented) return true;
  if (creativeRole && (offer || portfolio)) return true;
  if (portfolio && offer && /\b(?:illustrat|artist|design(?:er|s)?|draw(?:ing|n)?|artwork)\b/.test(hay)) return true;
  return false;
}
