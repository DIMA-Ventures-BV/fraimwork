// Owner shortcuts for background goals, handled by the channel itself so they work
// while the always-on session is busy:
//   "goal: <text>" or "goal <text>"   start a goal
//   "goals"                           list goals
//   "goal g3"                         show goal g3
//   "stop g3"                         stop goal g3
// A leading slash is allowed ("/goal ..."). Only the owner may use them.
const LIST_RE = /^\s*\/?goals\s*$/i
const SHOW_RE = /^\s*\/?goal\s+(g\d{1,6})\s*$/i
const STOP_RE = /^\s*\/?stop\s+(g\d{1,6})\s*$/i
const START_RE = /^\s*\/?goal\s*[:\s]\s*([\s\S]*\S[\s\S]*)$/i

// { action, id?, text? } when the message is a goal command from the owner, otherwise null.
export function parseGoalCommand(event, owner) {
  if (!owner || event?.sender !== owner) return null
  const text = event.text ?? ''
  if (LIST_RE.test(text)) return { action: 'list' }
  let match = SHOW_RE.exec(text)
  if (match) return { action: 'show', id: match[1].toLowerCase() }
  match = STOP_RE.exec(text)
  if (match) return { action: 'stop', id: match[1].toLowerCase() }
  match = START_RE.exec(text)
  if (match) return { action: 'start', text: match[1].trim() }
  return null
}

// The fraim-goal arguments for a parsed command.
export function goalArgs(command, chatId) {
  if (command.action === 'start') return ['start', '--chat', chatId, '--', command.text]
  if (command.action === 'list') return ['list']
  return [command.action, command.id]
}
