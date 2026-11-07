// "yes abcde" / "no abcde" from the owner answers a Claude permission prompt.
// Claude Code request ids are 5 letters from a-z without "l".
const VERDICT_RE = /^\s*(y|yes|n|no)\s+([a-km-z]{5})\s*$/i

// { request_id, behavior } when the message is the owner's answer, otherwise null.
export function parseVerdict(event, owner) {
  if (!owner || event?.sender !== owner) return null
  const match = VERDICT_RE.exec(event.text ?? '')
  if (!match) return null
  return {
    request_id: match[2].toLowerCase(),
    behavior: match[1].toLowerCase().startsWith('y') ? 'allow' : 'deny',
  }
}
