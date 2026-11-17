// MIME envelope shared with send-email-reply/format.ts (the customer-reply sender).
// Customer replies are multipart/alternative: text/plain + text/html, both UTF-8 and base64,
// HTML in the same Arial shell. A forward must keep the original words, so this does not run
// the reply draft's unwrap or markdown pass. Do not import this from send-email-reply.

const enc = new TextEncoder();
export const b64 = (u8: Uint8Array) => {
  let s = "";
  for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode(...u8.subarray(i, i + 0x8000));
  return btoa(s);
};
const b64Lines = (s: string) => b64(enc.encode(s)).replace(/.{1,76}/g, "$&\r\n");
const crlf = (s: string) => s.replace(/\r?\n/g, "\r\n");
const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

function rawHtml(text: string): string {
  const P = 'style="margin:0 0 14px 0"';
  const blocks = String(text || "").replace(/\r\n?/g, "\n").split(/\n\s*\n/);
  const html = blocks.map((b) => "<p " + P + ">" + b.split("\n").map((l) => esc(l)).join("<br>") + "</p>").join("\n");
  return '<!DOCTYPE html><html><head><meta charset="UTF-8"></head><body><div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:1.5;color:#222222">' + html + "</div></body></html>";
}

export function mimeAlternative(text: string): string[] {
  const boundary = "eggsy_" + crypto.randomUUID().replace(/-/g, "");
  const plain = crlf(String(text || ""));
  return [
    'Content-Type: multipart/alternative; boundary="' + boundary + '"',
    "",
    "--" + boundary,
    "Content-Type: text/plain; charset=UTF-8",
    "Content-Transfer-Encoding: base64",
    "",
    b64Lines(plain),
    "--" + boundary,
    "Content-Type: text/html; charset=UTF-8",
    "Content-Transfer-Encoding: base64",
    "",
    b64Lines(crlf(rawHtml(text))),
    "--" + boundary + "--",
    "",
  ];
}
