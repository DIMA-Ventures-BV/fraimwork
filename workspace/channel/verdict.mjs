// The owner's answer to a Claude permission prompt.
// Claude Code request ids are 5 letters from a-z without "l".
const VERDICT_RE = /^\s*(y|yes|n|no)\s+([a-km-z]{5})\s*$/i
const YES_RE = /^\s*(y|yes|yep|yeah|ja|jep|jawel|ok|oke|okay|go|sure|prima|akkoord|doe maar|ga door|ga je gang)\b/i
const NO_RE = /^\s*(n|no|nope|nee|niet|stop|don'?t|niet doen)\b/i
const SHORT_WORDS = 8
const ID_IN_TEXT = /\b(?:yes|no)\s+\*?([a-km-z]{5})\b/i

function behavior(text) {
  if (NO_RE.test(text)) return 'deny'
  if (YES_RE.test(text)) return 'allow'
  return null
}

// { request_id, behavior } when the message is the owner's answer, otherwise null.
// pending: the open requests, newest last, and latest: the id of the request that is the newest
// message the owner got (none when anything else was sent after it). Without them only
// "yes abcde" counts.
// - "yes abcde" / "no abcde" answers that request.
// - A swipe-reply to the approval message that starts with yes or no answers it.
// - A short plain "yes", "ja", "ok, go" or "no" answers the one open request, only while it is
//   the last thing the owner saw, so a yes meant for the chief's own question is never taken.
export function parseVerdict(event, owner, { pending = [], latest = '' } = {}) {
  if (!owner || event?.sender !== owner) return null
  const text = event.text ?? ''
  const match = VERDICT_RE.exec(text)
  if (match) {
    return {
      request_id: match[2].toLowerCase(),
      behavior: match[1].toLowerCase().startsWith('y') ? 'allow' : 'deny',
    }
  }
  const quoted = event.quote?.from === 'server' ? ID_IN_TEXT.exec(event.quote.text ?? '') : null
  if (quoted) {
    const id = quoted[1].toLowerCase()
    const b = behavior(text)
    return pending.includes(id) && b ? { request_id: id, behavior: b } : null
  }
  if (pending.length !== 1 || latest !== pending[0]) return null
  if (text.trim().split(/\s+/).length > SHORT_WORDS) return null
  const b = behavior(text)
  return b ? { request_id: pending[0], behavior: b } : null
}

// The approval message in plain words. The full command stays in it: the owner approves what
// runs, so it is never cut. A JSON preview shows only its command.
export function approvalText({ tool_name, description, input_preview, request_id }) {
  let what = input_preview
  try {
    const parsed = JSON.parse(input_preview)
    if (typeof parsed?.command === 'string') what = parsed.command
  } catch {}
  return [
    `A safety check wants your OK before I go on: ${description || tool_name}.`,
    'Answer *yes* or *no*.',
    '',
    `_What it runs (yes ${request_id}):_`,
    what,
  ].join('\n')
}
