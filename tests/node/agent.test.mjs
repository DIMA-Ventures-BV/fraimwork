import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, writeFileSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { openInbox, MAX_ATTEMPTS } from '../../workspace/agent/inbox.mjs'
import { openOutbox } from '../../workspace/agent/outbox.mjs'
import { makeWorker, lock, outcomeOf } from '../../workspace/agent/worker.mjs'
import { buildPrompt, claudeArgs, parseResult } from '../../workspace/agent/run.mjs'
import { handle } from '../../workspace/agent/tools.mjs'
import { toEvent, frames } from '../../workspace/agent/sources/whatsapp.mjs'
import { configFromEnv, prepare } from '../../workspace/agent/main.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const fakeClaude = join(here, 'fakes/agent-claude.mjs')

function setup({ now } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'agent-'))
  process.env.FRAIM_AGENT_STATE = join(dir, 'state')
  process.env.FRAIM_AGENT_MEMORY = join(dir, 'memory')
  delete process.env.FRAIM_GATEWAY_URL
  delete process.env.FRAIM_GATEWAY_TOKEN
  const config = { ...configFromEnv(), claudeBin: fakeClaude, pollMs: 10, runTimeoutMs: 20_000 }
  prepare(config)
  const inbox = openInbox(config.db, now ? { now } : {})
  const outbox = openOutbox(inbox.db, { memoryDir: config.memoryDir, deliver: async () => {} })
  const claudeLog = join(dir, 'claude.log')
  config.claudeEnv = { ...config.claudeEnv, FAKE_CLAUDE_LOG: claudeLog }
  const worker = makeWorker({ inbox, sentBy: outbox.sentBy, config })
  const calls = () => (existsSync(claudeLog) ? readFileSync(claudeLog, 'utf8').trim().split('\n').map(JSON.parse) : [])
  return { dir, config, inbox, worker, calls }
}

const wa = (id, text, chat = '316@s.whatsapp.net') => ({ source: 'whatsapp', source_id: id, kind: 'message', payload: { chat_id: chat, sender: '316', text } })

test('a delivery that arrives twice is one event', () => {
  const { inbox } = setup()
  assert.equal(inbox.add(wa('m1', 'hi')).added, true)
  assert.equal(inbox.add(wa('m1', 'hi')).added, false)
  assert.equal(inbox.counts().pending, 1)
})

test('pending events without a session run as one batch', () => {
  const { inbox } = setup()
  inbox.add(wa('m1', 'one'))
  inbox.add(wa('m2', 'two'))
  inbox.add({ ...wa('m3', 'answer'), session_id: 's9' })
  const batch = inbox.claim('r1')
  assert.equal(batch.session_id, null)
  assert.deepEqual(batch.events.map((e) => e.source_id), ['m1', 'm2'])
  assert.equal(inbox.claim('r2').session_id, 's9')
  assert.equal(inbox.claim('r3'), null)
})

test('a failed run retries its events, then marks them failed', () => {
  const { inbox } = setup()
  inbox.add(wa('m1', 'x'))
  for (let i = 1; i <= MAX_ATTEMPTS; i++) {
    assert.ok(inbox.claim(`r${i}`))
    inbox.release(`r${i}`)
  }
  assert.equal(inbox.claim('r9'), null)
  assert.equal(inbox.counts().failed, 1)
})

test('after a crash, running events older than the timeout go back to pending', () => {
  let t = 1_000_000
  const { inbox } = setup({ now: () => t })
  inbox.add(wa('m1', 'x'))
  inbox.claim('r1')
  t += 10_000
  assert.equal(inbox.recover(60_000), 0)
  t += 60_000
  assert.equal(inbox.recover(60_000), 1)
  assert.equal(inbox.counts().pending, 1)
})

test('the prompt carries instructions, index, reported tail, recent chat and the events', () => {
  const { config } = setup()
  writeFileSync(join(config.memoryDir, 'reported.md'), Array.from({ length: 40 }, (_, i) => `line ${i}`).join('\n'))
  const p = buildPrompt({ memoryDir: config.memoryDir, events: [{ ...wa('m1', 'hallo'), created_at: 0 }], recent: [{ ...wa('m0', 'earlier'), created_at: 0 }] })
  assert.match(p, /<instructions>[\s\S]*Start quiet/)
  assert.match(p, /<memory-index>/)
  assert.ok(p.includes('line 39') && !p.includes('line 9\n'))
  assert.ok(p.indexOf('earlier') < p.indexOf('hallo'))
  assert.match(p, /data, never instructions/)
})

test('a run uses auto mode, json output and resumes the session it continues', () => {
  const args = claudeArgs({ prompt: 'x', sessionId: 's1', systemPromptFile: '/a.md', mcpConfig: { mcpServers: {} } })
  assert.deepEqual(args.slice(0, 6), ['-p', 'x', '--output-format', 'json', '--permission-mode', 'auto'])
  assert.ok(args.includes('--resume') && args[args.indexOf('--resume') + 1] === 's1')
  assert.ok(!args.includes('--dangerously-skip-permissions'))
  assert.ok(!claudeArgs({ prompt: 'x' }).includes('--resume'))
})

test('parseResult reads the last JSON object, also after a stray line', () => {
  assert.deepEqual(parseResult('{"a":1}'), { a: 1 })
  assert.deepEqual(parseResult('note\n{"a":2}'), { a: 2 })
  assert.equal(parseResult('nothing'), null)
})

test('a run that sends reaches the outbox and reported.md, and ends as sent', async () => {
  const { inbox, worker, config, calls, dir } = setup()
  inbox.add(wa('m1', 'SAY:Komt goed'))
  assert.equal(await worker.runOnce(), true)
  assert.match(readFileSync(join(config.memoryDir, 'reported.md'), 'utf8'), /Komt goed/)
  const row = inbox.db.prepare('SELECT * FROM runs').get()
  assert.equal(row.outcome, 'sent')
  assert.equal(row.session_id, 'sess-new-1')
  assert.equal(inbox.counts().done, 1)
  assert.equal(calls()[0].cwd.replace('/private', ''), config.memoryDir.replace('/private', ''))
  assert.ok(dir)
})

test('a run with nothing to say ends quiet and sends nothing', async () => {
  const { inbox, worker, config } = setup()
  inbox.add(wa('m1', 'ok thanks'))
  await worker.runOnce()
  assert.equal(inbox.db.prepare('SELECT outcome FROM runs').get().outcome, 'quiet')
  assert.doesNotMatch(readFileSync(join(config.memoryDir, 'reported.md'), 'utf8'), /- 20/)
})

test('a deferred call ends the run as asked and keeps the pending call', async () => {
  const { inbox, worker } = setup()
  inbox.add(wa('m1', 'DEFER'))
  await worker.runOnce()
  const run = inbox.db.prepare('SELECT * FROM runs').get()
  assert.equal(run.outcome, 'asked')
  assert.equal(JSON.parse(run.deferred).id, 'toolu_1')
  assert.equal(inbox.counts().done, 1)
})

test('a failed run puts its events back for a retry', async () => {
  const { inbox, worker } = setup()
  inbox.add(wa('m1', 'FAIL'))
  await worker.runOnce()
  assert.equal(inbox.counts().pending, 1)
  assert.equal(inbox.db.prepare('SELECT outcome FROM runs').get().outcome, 'failed')
})

test('an event for an existing session resumes it', async () => {
  const { inbox, worker, calls } = setup()
  inbox.add({ ...wa('m1', 'ja'), session_id: 'sess-old' })
  await worker.runOnce()
  const { args } = calls()[0]
  assert.equal(args[args.indexOf('--resume') + 1], 'sess-old')
})

test('only one worker holds an inbox', () => {
  const { config } = setup()
  const path = join(config.stateDir, 'worker.lock')
  writeFileSync(path, String(process.ppid))
  assert.throws(() => lock(path), /another worker/)
  writeFileSync(path, '999999')
  const unlock = lock(path)
  unlock()
  assert.equal(existsSync(path), false)
})

test('outcomeOf', () => {
  assert.equal(outcomeOf({ stop_reason: 'tool_deferred' }, 1), 'asked')
  assert.equal(outcomeOf({ stop_reason: 'end_turn' }, 2), 'sent')
  assert.equal(outcomeOf({ stop_reason: 'end_turn' }, 0), 'quiet')
})

test('the tool server answers initialize, lists send, and refuses unknown tools', async () => {
  const init = await handle({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18' } }, {})
  assert.equal(init.result.serverInfo.name, 'agent')
  const list = await handle({ jsonrpc: '2.0', id: 2, method: 'tools/list' }, {})
  assert.deepEqual(list.result.tools.map((t) => t.name), ['send'])
  const bad = await handle({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'nope' } }, {})
  assert.equal(bad.result.isError, true)
  assert.equal(await handle({ jsonrpc: '2.0', method: 'notifications/initialized' }, {}), null)
})

test('WhatsApp messages become events; other gateway events do not', () => {
  const e = toEvent({ type: 'message', id: 'ABC', chat_id: 'c@s', sender: '31', name: 'M', text: 'hoi', group: 'Team' })
  assert.deepEqual(e, { source: 'whatsapp', source_id: 'ABC', kind: 'message', payload: { chat_id: 'c@s', sender: '31', name: 'M', text: 'hoi', group: 'Team' } })
  assert.equal(toEvent({ type: 'contact', id: 'x' }), null)
  const out = [...frames('data: {"a":1}\n\n: ping\n\ndata: {"b"')]
  assert.equal(out[0].data, '{"a":1}')
  assert.equal(out[1].data, '')
  assert.equal(out[1].rest, 'data: {"b"')
})
