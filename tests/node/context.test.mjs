// The context that goes with every owner message on WhatsApp.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { withContext } from '../../workspace/channel/context.mjs'

test('an owner message carries the conversation and what to do with a yes', () => {
  const out = withContext('Ja tuurlijk', '[11-10 06:21] You (about q48): Mag ik meekijken?\n\nDecisions that still wait:\n- q48: AI costs')
  assert.ok(out.startsWith('Ja tuurlijk\n'))
  assert.match(out, /not written by the owner/)
  assert.match(out, /You \(about q48\): Mag ik meekijken\?/)
  assert.match(out, /fraim-queue approve\|reject\|dismiss ID --via whatsapp/)
  assert.match(out, /Never answer a yes without recording it/)
  assert.match(out, /do not ask which part/)
})

test('without context the message stays as it is', () => {
  assert.equal(withContext('hoi', ''), 'hoi')
})
