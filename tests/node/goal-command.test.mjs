// The session_command tool's argument mapping.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { sessionCommandArgs } from '../../workspace/channel/goal-command.mjs'

test('sessionCommandArgs maps the tool input and refuses other commands', () => {
  assert.deepEqual(sessionCommandArgs({ command: 'clear', chat_id: 'c@s' }), ['--chat', 'c@s', 'clear'])
  assert.deepEqual(sessionCommandArgs({ command: 'compact', argument: 'keep the flights' }), ['compact', 'keep the flights'])
  assert.deepEqual(sessionCommandArgs({ command: 'compact' }), ['compact'])
  assert.deepEqual(sessionCommandArgs({ command: 'model', argument: ' Opus ' }), ['model', 'opus'])
  assert.throws(() => sessionCommandArgs({ command: 'login' }))
  assert.throws(() => sessionCommandArgs({}))
})
