// Only the Claude started with the channel flag may read WhatsApp messages.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { hasChannelFlag, startedByMainSession } from '../../workspace/channel/main-session.mjs'

test('main has the channel flag and an automation run does not', () => {
  assert.equal(hasChannelFlag('claude\0--dangerously-load-development-channels\0server:whatsapp\0'), true)
  assert.equal(hasChannelFlag('claude\0-p\0--output-format\0json\0'), false)
})

test('a parent that cannot be read does not count as main', () => {
  assert.equal(startedByMainSession(999999999), false)
})
