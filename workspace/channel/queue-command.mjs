// Owner shortcuts for the review queue, the brain and the leads, handled by the channel
// itself so they work while the always-on session is busy:
//   "queue"                              list open items
//   "ok q3 [note]" / "approve q3"        approve (runs the item's next step, if any)
//   "no q3 <why>" / "reject q3 <why>"    reject; the reason is required and teaches the brain
//   "skip q3" / "dismiss q3"             close without effect
//   "remember: <preference>"             add a rule for the brain, at once
//   "rules"                              the brain's rules
//   "why r3" / "forget r3"               where a rule came from / remove it
//   "undo rules"                         put the rules back as they were before the last change
//   "leads"                              list the lead agents
// A leading slash is allowed. Only the owner may use them.
const LIST_RE = /^\s*\/?queue\s*$/i
const LEADS_RE = /^\s*\/?leads\s*$/i
const APPROVE_RE = /^\s*\/?(?:ok|approve)\s+(q\d{1,6})\b\s*([\s\S]*)$/i
const REJECT_RE = /^\s*\/?(?:no|reject)\s+(q\d{1,6})\b\s*([\s\S]*)$/i
const DISMISS_RE = /^\s*\/?(?:skip|dismiss)\s+(q\d{1,6})\s*$/i
const RULES_RE = /^\s*\/?rules\s*$/i
const RULE_RE = /^\s*\/?(why|forget)\s+(r\d{1,6})\s*$/i
const UNDO_RE = /^\s*\/?undo\s+rules\s*$/i
const REMEMBER_RE = /^\s*\/?remember\s*:\s*([\s\S]*\S[\s\S]*)$/i

// { action, id?, note?, text? } for a queue command from the owner, otherwise null.
export function parseQueueCommand(event, owner) {
  if (!owner || event?.sender !== owner) return null
  const text = event.text ?? ''
  if (LIST_RE.test(text)) return { action: 'list' }
  if (LEADS_RE.test(text)) return { action: 'leads' }
  let m = APPROVE_RE.exec(text)
  if (m) return { action: 'approve', id: m[1].toLowerCase(), note: m[2].trim() }
  m = REJECT_RE.exec(text)
  if (m) return { action: 'reject', id: m[1].toLowerCase(), note: m[2].trim() }
  m = DISMISS_RE.exec(text)
  if (m) return { action: 'dismiss', id: m[1].toLowerCase() }
  if (RULES_RE.test(text)) return { action: 'rules' }
  if (UNDO_RE.test(text)) return { action: 'undo-rules' }
  m = RULE_RE.exec(text)
  if (m) return { action: m[1].toLowerCase(), id: m[2].toLowerCase() }
  m = REMEMBER_RE.exec(text)
  if (m) return { action: 'remember', text: m[1].trim() }
  return null
}

// [command, args] to run for a parsed queue command.
export function queueArgs(command) {
  switch (command.action) {
    case 'list': return ['fraim-queue', ['list']]
    case 'leads': return ['fraim-lead', ['list']]
    case 'remember': return ['fraim-brain', ['note', command.text]]
    case 'rules': return ['fraim-brain', ['show']]
    case 'why': return ['fraim-brain', ['why', command.id]]
    case 'forget': return ['fraim-brain', ['forget', command.id]]
    case 'undo-rules': return ['fraim-brain', ['undo']]
    case 'dismiss': return ['fraim-queue', ['dismiss', command.id, '--via', 'whatsapp']]
    default: {
      const args = [command.action, command.id]
      if (command.note) args.push('--note', command.note)
      args.push('--via', 'whatsapp')
      return ['fraim-queue', args]
    }
  }
}
