// WhatsApp shortcuts for live sessions (goals g1.., coding sessions s1..): owner only.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { parseGoalCommand, parseSessionCommand, screenTail } from '../../workspace/channel/goal-command.mjs'

const OWNER = '31612345678'
const msg = (text, sender = OWNER) => ({ type: 'message', sender, text })

test('g3: text and s2: text send into that session', () => {
  assert.deepEqual(parseSessionCommand(msg('g3: use the cheaper hotel'), OWNER), {
    tool: 'fraim-goal',
    args: ['send', 'g3', 'use the cheaper hotel'],
    action: 'send',
    id: 'g3',
  })
  assert.deepEqual(parseSessionCommand(msg('S2 : run the tests\nthen push'), OWNER), {
    tool: 'fraim-sessions',
    args: ['send', 's2', 'run the tests\nthen push'],
    action: 'send',
    id: 's2',
  })
})

test('show, sessions and stop s2', () => {
  assert.deepEqual(parseSessionCommand(msg('show g3'), OWNER).args, ['read', 'g3'])
  assert.deepEqual(parseSessionCommand(msg('/show s1'), OWNER).args, ['read', 's1'])
  assert.deepEqual(parseSessionCommand(msg('sessions'), OWNER).args, ['list'])
  assert.deepEqual(parseSessionCommand(msg('stop s4'), OWNER), {
    tool: 'fraim-sessions',
    args: ['stop', 's4'],
    action: 'stop',
    id: 's4',
  })
})

test('stop g3 stays a goal command, checked first by the channel', () => {
  assert.deepEqual(parseGoalCommand(msg('stop g3'), OWNER), { action: 'stop', id: 'g3' })
  assert.equal(parseSessionCommand(msg('stop g3'), OWNER), null)
})

test('others and plain messages are not commands', () => {
  assert.equal(parseSessionCommand(msg('g3: do it', '31600000000'), OWNER), null)
  assert.equal(parseSessionCommand(msg('g3: do it'), ''), null)
  assert.equal(parseSessionCommand(msg('g3:'), OWNER), null)
  assert.equal(parseSessionCommand(msg('see g3: it failed'), OWNER), null)
  assert.equal(parseSessionCommand(msg('x3: hi'), OWNER), null)
})

test('screenTail drops empty and rule lines and keeps the end', () => {
  const screen = ['● Done.', '', '─────────', '❯ ', '──────', '  ⏵⏵ bypass permissions on'].join('\n')
  assert.equal(screenTail(screen), '● Done.\n❯\n  ⏵⏵ bypass permissions on')
  assert.equal(screenTail(Array.from({ length: 40 }, (_, i) => `line ${i}`).join('\n'), 3), 'line 37\nline 38\nline 39')
  assert.equal(screenTail(''), '')
})
