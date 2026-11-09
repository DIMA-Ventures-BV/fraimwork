// Messages the session has not answered yet. Claude sometimes ends a turn with its answer only
// on its own screen; the owner then hears nothing. A message that waits longer than `after`
// milliseconds gets a reminder into the session, at most `max` times.
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

  // The reminders to send now, one per chat.
  due(now = Date.now()) {
    const out = []
    for (const [chatId, w] of this.waiting) {
      if (now < w.due) continue
      if (w.reminded >= this.max) { this.waiting.delete(chatId); continue }
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
