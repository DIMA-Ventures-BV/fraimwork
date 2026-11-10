// The context that goes with every message from the owner: the conversation so far and the
// decisions that wait (fraim-relay context), with what to do with it. Without it the session
// reads a short "yes" or "unclear" against whatever it still remembers.
// A message that waited while the server was away says so, or its "now" reads as this moment.
export function catchUpNote(event) {
  if (!event.catchup) return ''
  const when = event.ts ? ` at ${new Date(event.ts * 1000).toTimeString().slice(0, 5)}` : ''
  return `(Sent${when} while the server was offline; it arrived just now.)`
}

export function withContext(text, context) {
  if (!context) return text
  return [
    text,
    '',
    '--- For you, not written by the owner ---',
    context,
    '',
    "Before you answer, work out from this conversation what the owner's message is about.",
    'When it answers a waiting decision (yes, no, do it, not now), record it first: fraim-queue approve|reject|dismiss ID --via whatsapp --note "<their words>". Then say in one line what happens now because of their answer.',
    'Never answer a yes without recording it, and never ask again for a yes they already gave.',
    'Do not bring up the other waiting decisions unless the owner asks what is open: they stay in the list, one question at a time.',
    'When they say something was unclear, do not ask which part: write it again in plain words. Say what they asked or answered, what happened, and what still waits for them.',
    "Answer in the language of their message, unless the owner's own rules for how you talk say otherwise.",
  ].join('\n')
}
