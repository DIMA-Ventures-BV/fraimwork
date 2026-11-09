// WhatsApp goal shortcuts: owner only, and plain messages still reach Claude.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { goalArgs, parseGoalCommand, sessionCommandArgs } from '../../workspace/channel/goal-command.mjs'

const OWNER = '31612345678'
const msg = (text, sender = OWNER) => ({ type: 'message', sender, text })

test('goal: text starts a goal', () => {
  assert.deepEqual(parseGoalCommand(msg('goal: find three flights to Lisbon'), OWNER), {
    action: 'start',
    text: 'find three flights to Lisbon',
  })
  assert.deepEqual(parseGoalCommand(msg('/goal clean up ~/fraim/inbox'), OWNER), {
    action: 'start',
    text: 'clean up ~/fraim/inbox',
  })
  assert.deepEqual(parseGoalCommand(msg('Goal  write a plan\nwith two lines'), OWNER), {
    action: 'start',
    text: 'write a plan\nwith two lines',
  })
})

test('goals, goal ID and stop ID', () => {
  assert.deepEqual(parseGoalCommand(msg('goals'), OWNER), { action: 'list' })
  assert.deepEqual(parseGoalCommand(msg(' /Goals '), OWNER), { action: 'list' })
  assert.deepEqual(parseGoalCommand(msg('goal G12'), OWNER), { action: 'show', id: 'g12' })
  assert.deepEqual(parseGoalCommand(msg('stop g3'), OWNER), { action: 'stop', id: 'g3' })
})

test('only the owner can use goal commands', () => {
  assert.equal(parseGoalCommand(msg('goal: delete everything', '4915112345678'), OWNER), null)
  assert.equal(parseGoalCommand(msg('goal: x'), ''), null)
})

test('normal messages are not goal commands', () => {
  for (const text of ['what is my goal for today?', 'goalkeeper stats', 'goal', 'goal:   ', 'stop', 'stop it', 'yes abcde']) {
    assert.equal(parseGoalCommand(msg(text), OWNER), null, text)
  }
})

test('goalArgs passes the text as one argument after --', () => {
  assert.deepEqual(goalArgs({ action: 'start', text: '--help; rm -rf ~' }, 'c@s.whatsapp.net'), [
    'start', '--chat', 'c@s.whatsapp.net', '--', '--help; rm -rf ~',
  ])
  assert.deepEqual(goalArgs({ action: 'list' }, 'c'), ['list'])
  assert.deepEqual(goalArgs({ action: 'stop', id: 'g2' }, 'c'), ['stop', 'g2'])
})

test('sessionCommandArgs maps the tool input and refuses other commands', () => {
  assert.deepEqual(sessionCommandArgs({ command: 'clear', chat_id: 'c@s' }), ['--chat', 'c@s', 'clear'])
  assert.deepEqual(sessionCommandArgs({ command: 'compact', argument: 'keep the flights' }), ['compact', 'keep the flights'])
  assert.deepEqual(sessionCommandArgs({ command: 'compact' }), ['compact'])
  assert.deepEqual(sessionCommandArgs({ command: 'model', argument: ' Opus ' }), ['model', 'opus'])
  assert.throws(() => sessionCommandArgs({ command: 'login' }))
  assert.throws(() => sessionCommandArgs({}))
})
