// A WhatsApp message the session did not answer gets a reminder, at most twice.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { Unanswered } from '../../workspace/channel/unanswered.mjs'

test('an unanswered message gets a reminder after the wait, at most twice', () => {
  const u = new Unanswered({ after: 1000, max: 2 })
  u.received('chat1', 'How are we doing', 'Michael', 0)
  assert.deepEqual(u.due(999), [])
  const first = u.due(1000)
  assert.equal(first.length, 1)
  assert.equal(first[0].chatId, 'chat1')
  assert.match(first[0].content, /"How are we doing"/)
  assert.match(first[0].content, /reply tool/)
  assert.deepEqual(u.due(1500), [])
  assert.equal(u.due(2000).length, 1)
  assert.deepEqual(u.due(3000), [])
  assert.deepEqual(u.due(10000), [])
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
