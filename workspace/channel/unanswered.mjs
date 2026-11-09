// Messages the session has not answered yet. Claude sometimes ends a turn with its answer only
// on its own screen; the owner then hears nothing. A message that waits longer than `after`
// milliseconds gets a reminder into the session, at most `max` times. After that the bridge
// sends the answer from the session's screen itself, so the owner always hears back.
export class Unanswered {
  constructor({ after = 180000, max = 2 } = {}) {
    this.after = after
    this.max = max
    this.waiting = new Map()
  }

  received(chatId, text, name, now = Date.now()) {
    const prev = this.waiting.get(chatId)
    this.waiting.set(chatId, { since: prev ? prev.since : now, due: now + this.after, text: String(text || '').slice(0, 200), name: name || '', reminded: prev ? prev.reminded : 0 })
  }

  answered(chatId) {
    this.waiting.delete(String(chatId))
  }

  pending(now = Date.now()) {
    for (const w of this.waiting.values()) if (now >= w.due) return true
    return false
  }

  // What to do now, one entry per chat: a reminder into the session, or (after `max`
  // reminders) a fallback that sends the screen's answer. While the session still works,
  // nothing is due: the answer may still come.
  due(now = Date.now(), busy = false) {
    const out = []
    for (const [chatId, w] of this.waiting) {
      if (now < w.due) continue
      if (busy) { w.due = now + this.after; continue }
      if (w.reminded >= this.max) {
        this.waiting.delete(chatId)
        out.push({ chatId, fallback: true, text: w.text })
        continue
      }
      w.reminded += 1
      w.due = now + this.after
      out.push({ chatId, content: reminderText(w), reminded: w.reminded })
    }
    return out
  }
}

export function reminderText(w) {
  const who = w.name ? `${w.name}'s` : 'the'
  return `Reminder from the WhatsApp bridge: ${who} last message ("${w.text}") has no answer on WhatsApp yet. ` +
    'Text you write in this session never reaches WhatsApp. Answer now with the reply tool and this chat_id; ' +
    'when the work is still running, reply in one line that you are on it.'
}

const TOOL_LINE = /^● [A-Za-z0-9_.:-]+\(/
const END_LINE = /^(✻|─{5,}|❯|\s*⏵)/

// The answer Claude wrote on its screen after the last WhatsApp message (not after a reminder):
// its text blocks ("● ..." and their indented lines), without tool calls and their output.
export function lastAnswer(screen) {
  const lines = String(screen || '').split('\n')
  let start = -1
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i].startsWith('← whatsapp:') && !lines[i].includes('Reminder from the WhatsApp bridge')) { start = i; break }
  }
  if (start < 0) return ''
  const blocks = []
  let cur = null
  for (const line of lines.slice(start + 1)) {
    if (line.startsWith('● ')) {
      cur = TOOL_LINE.test(line) ? null : [line.slice(2)]
      if (cur) blocks.push(cur)
      continue
    }
    if (line.startsWith('← ') || line.startsWith('  ⎿') || /^\s+Called [a-z]/.test(line) || END_LINE.test(line)) { cur = null; continue }
    if (cur && (line.startsWith('  ') || line === '')) cur.push(line.slice(2))
    else cur = null
  }
  return blocks.map((b) => b.join('\n').trim()).filter((t) => t && !/^Called /.test(t)).join('\n\n').trim().slice(0, 4000)
}
