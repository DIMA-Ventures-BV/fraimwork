// A WhatsApp message the session did not answer gets two reminders, then the bridge sends
// the answer from the session's screen itself.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { Unanswered, lastAnswer } from '../../workspace/channel/unanswered.mjs'

test('an unanswered message gets two reminders, then one fallback, then nothing', () => {
  const u = new Unanswered({ after: 1000, max: 2 })
  u.received('chat1', 'How are we doing', 'Michael', 0)
  assert.equal(u.pending(999), false)
  assert.deepEqual(u.due(999), [])
  const first = u.due(1000)
  assert.equal(first.length, 1)
  assert.equal(first[0].chatId, 'chat1')
  assert.match(first[0].content, /"How are we doing"/)
  assert.match(first[0].content, /reply tool/)
  assert.deepEqual(u.due(1500), [])
  assert.equal(u.due(2000)[0].reminded, 2)
  assert.deepEqual(u.due(3000), [{ chatId: 'chat1', fallback: true, text: 'How are we doing' }])
  assert.deepEqual(u.due(10000), [])
})

test('while the session still works, nothing is due and no reminder is used up', () => {
  const u = new Unanswered({ after: 1000, max: 1 })
  u.received('chat1', 'run the report', '', 0)
  assert.deepEqual(u.due(1000, true), [])
  assert.deepEqual(u.due(1500, true), [])
  assert.equal(u.due(2000, false)[0].reminded, 1)
})

test('a reply clears the wait; a new message starts it again', () => {
  const u = new Unanswered({ after: 1000 })
  u.received('chat1', 'one', '', 0)
  u.answered('chat1')
  assert.deepEqual(u.due(5000), [])
  u.received('chat1', 'two', '', 6000)
  u.received('chat1', 'three', '', 6500)
  const r = u.due(7500)
  assert.equal(r.length, 1)
  assert.match(r[0].content, /"three"/)
})

// The shape of a real screen of the always-on session (claude code in herdr).
const SCREEN = `● Nee, iets ouds.

✻ Cooked for 6s · done 5:51 PM

← whatsapp: Where do we stand did all leads already run

● Bash(fraim-lead list 2>&1 | head -30)
  ⎿  chief  chief  0 8 * * *  budget 99/day  last: ok 2026-11-09 18:31
     content  lead  40 7 * * 2,4  budget 99/day  last: never ran
     … +8 lines (ctrl+o to expand)

● Nee, de meeste hebben nog niet gedraaid.

  Wel gedraaid vandaag:
  - Hoofdlead (dagelijks overzicht)

  Wil je dat ik ze nu eenmalig laat draaien?

✻ Sautéed for 5s · done 5:51 PM

← whatsapp: Reminder from the WhatsApp bridge: the last message ("x") has no answer on WhatsApp yet.

────────────────────────────────────────
❯
────────────────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle)`

test('the answer on the screen is the text after the last message, without tool calls or reminders', () => {
  assert.equal(lastAnswer(SCREEN), 'Nee, de meeste hebben nog niet gedraaid.\n\nWel gedraaid vandaag:\n- Hoofdlead (dagelijks overzicht)\n\nWil je dat ik ze nu eenmalig laat draaien?')
})

test('no message or no text on the screen gives no answer', () => {
  assert.equal(lastAnswer(''), '')
  assert.equal(lastAnswer('← whatsapp: hi\n\n● Bash(ls)\n  ⎿  a\n\n✻ done'), '')
})
