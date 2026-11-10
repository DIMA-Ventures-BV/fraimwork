// One shape for every channel: who an answer goes to, repeats, and picking up new mail.
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { chmod, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises'
import http from 'node:http'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'
import { SavedQueue, givesUp, readsUpsert, reconnectDelay } from '../../whatsapp/lib.mjs'
import { catchUpNote } from '../../workspace/channel/context.mjs'
import { claim, replyTarget, sendReply } from '../../workspace/bin/fraim-channels.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const bin = path.join(here, '../../workspace/bin/fraim-channels')
const run = promisify(execFile)

async function service(t, answer) {
  const calls = []
  const server = http.createServer((req, res) => {
    let raw = ''
    req.on('data', (c) => { raw += c })
    req.on('end', () => {
      const body = raw ? JSON.parse(raw) : {}
      calls.push({ route: req.url, method: req.method, auth: req.headers.authorization, body })
      res.writeHead(200, { 'Content-Type': 'application/json' })
      res.end(JSON.stringify(answer(req.url, body)))
    })
  })
  await new Promise((r) => server.listen(0, '127.0.0.1', r))
  t.after(() => server.close())
  return { url: `http://127.0.0.1:${server.address().port}`, calls }
}

async function home(url) {
  const dir = await mkdtemp(path.join(tmpdir(), 'fraim-channels-'))
  await mkdir(path.join(dir, 'bin'))
  await mkdir(path.join(dir, 'fraim/automations/mail-requests'), { recursive: true })
  await writeFile(path.join(dir, 'fraim/automations/mail-requests/automation.md'), 'x')
  await writeFile(path.join(dir, 'bin/fraim-auto'), `#!/bin/sh\nprintf '%s\\n' "$*" >> "${dir}/auto.log"\n`)
  await chmod(path.join(dir, 'bin/fraim-auto'), 0o755)
  return {
    dir,
    env: { ...process.env, HOME: dir, PATH: `${path.join(dir, 'bin')}:${process.env.PATH}`, FRAIM_RUNTIME_ENV: '/dev/null', FRAIM_MODULES: 'google,whatsapp', FRAIM_MAIL_AUTOMATION: 'mail-requests', FRAIM_REPLY_TOKEN: 'reply-secret', FRAIM_GATEWAY_TOKEN: 'gw-secret', FRAIM_REPLY_MAIL_URL: url, FRAIM_GATEWAY_URL: url },
  }
}

test('a mail conversation answers the address its own chain gives', async (t) => {
  const s = await service(t, () => ({ name: 'Anna', to: 'anna@example.com', subject: 'Re: Login' }))
  const r = await replyTarget({ key: 'gmail:abc123def' }, { FRAIM_REPLY_TOKEN: 'k', FRAIM_REPLY_MAIL_URL: s.url })
  assert.deepEqual(r, { channel: 'email', to: 'anna@example.com', name: 'Anna', subject: 'Re: Login', gmail_thread: 'abc123def' })
  assert.equal(s.calls[0].route, '/who')
  assert.equal(s.calls[0].auth, 'Bearer k')
})

test('a WhatsApp conversation answers its number, after the gateway accepts it', async (t) => {
  const s = await service(t, () => ({ ok: true }))
  const r = await replyTarget({ key: 'whatsapp:31612345678', who: 'Bert' }, { FRAIM_REPLY_TOKEN: 'k', FRAIM_GATEWAY_URL: s.url })
  assert.deepEqual(r, { channel: 'whatsapp', to: '31612345678', name: 'Bert', subject: '' })
  assert.equal(s.calls[0].route, '/reply/check')
})

test('a conversation without someone to answer has no target', async () => {
  assert.equal(await replyTarget({ key: 'linear:ABC-1' }, {}), null)
})

test('an approved reply goes to the service of its own channel', async (t) => {
  const s = await service(t, () => ({ ok: true }))
  const env = { FRAIM_REPLY_TOKEN: 'k', FRAIM_REPLY_MAIL_URL: s.url, FRAIM_GATEWAY_URL: s.url }
  await sendReply({ channel: 'email', gmail_thread: 'abc123def', to: 'a@b.nl', text: 'hi' }, env)
  await sendReply({ channel: 'whatsapp', to: '31612345678', text: 'yo' }, env)
  assert.deepEqual(s.calls.map((c) => c.body), [{ thread_id: 'abc123def', to: 'a@b.nl', text: 'hi' }, { to: '31612345678', text: 'yo' }])
  assert.throws(() => sendReply({ channel: 'pigeon', text: 'x' }, env), /no channel pigeon/)
})

test('a message counts once per channel, across processes', async () => {
  const { env, dir } = await home('http://127.0.0.1:1')
  const seen = (id) => run(process.execPath, [bin, 'seen', 'whatsapp', id], { env }).then(() => 0, (e) => e.code)
  assert.equal(await seen('m1'), 0)
  assert.equal(await seen('m1'), 10)
  assert.equal(claim('email', 'm1', path.join(dir, '.local/state/fraim/channels')), true)
  assert.equal(claim('email', '', dir), true)
})

test('by default new mail starts nothing and nobody follows the channel', async (t) => {
  const s = await service(t, () => ({ events: [{ seq: 1, id: 'm1', thread: 'thread11' }], last: 1 }))
  const { env, dir } = await home(s.url)
  const { FRAIM_MAIL_AUTOMATION: _switchedOn, ...untouched } = env
  await run(process.execPath, [bin, 'listen', '--once'], { env: untouched })
  assert.equal(s.calls.length, 0)
  await assert.rejects(readFile(path.join(dir, 'auto.log')))
})

test('a switched-on trigger hands only Thread IDs to its automation, once', async (t) => {
  const s = await service(t, () => ({ events: [{ seq: 1, id: 'm1', thread: 'thread11' }, { seq: 2, id: 'm2', thread: 'thread11' }, { seq: 3, id: 'm3', thread: 'thread22' }], last: 3 }))
  const { env, dir } = await home(s.url)
  await run(process.execPath, [bin, 'listen', '--once'], { env })
  assert.equal(await readFile(path.join(dir, 'auto.log'), 'utf8'), 'run mail-requests --input thread11 thread22\n')
  assert.equal((await readFile(path.join(dir, '.local/state/fraim/channels/email.cursor'), 'utf8')).trim(), '3')
  assert.equal(s.calls[0].auth, 'Bearer reply-secret')

  await writeFile(path.join(dir, '.local/state/fraim/channels/email.cursor'), '0\n')
  await run(process.execPath, [bin, 'listen', '--once'], { env })
  assert.equal((await readFile(path.join(dir, 'auto.log'), 'utf8')).trim().split('\n').length, 1)
})

test('a list of mail that restarted is read from the start', async (t) => {
  const s = await service(t, (_route, body) => (body.after > 2 ? { events: [], last: 2 } : { events: [{ seq: 2, id: 'm9', thread: 'thread99' }], last: 2 }))
  const { env, dir } = await home(s.url)
  await mkdir(path.join(dir, '.local/state/fraim/channels'), { recursive: true })
  await writeFile(path.join(dir, '.local/state/fraim/channels/email.cursor'), '40\n')
  await run(process.execPath, [bin, 'listen', '--once'], { env })
  assert.match(await readFile(path.join(dir, 'auto.log'), 'utf8'), /thread99/)
})

test('without the mail automation the mail is noted and nothing runs', async (t) => {
  const s = await service(t, () => ({ events: [{ seq: 1, id: 'm1', thread: 'thread11' }], last: 1 }))
  const { env, dir } = await home(s.url)
  const out = await run(process.execPath, [bin, 'listen', '--once'], { env: { ...env, FRAIM_MAIL_AUTOMATION: 'nope' } })
  assert.match(out.stderr, /no automation nope/)
  await assert.rejects(readFile(path.join(dir, 'auto.log')))
})

test('check fails when the mail watcher stopped looking, not when nobody signed in', async (t) => {
  let answer = { signed_in: false, mode: 'check', last_check: 0 }
  const s = await service(t, () => answer)
  const { env } = await home(s.url)
  const check = () => run(process.execPath, [bin, 'check', 'email'], { env }).then(() => 0, (e) => e.code)
  assert.equal(await check(), 0)
  answer = { signed_in: true, mode: 'check', last_check: Math.floor(Date.now() / 1000) - 3600 }
  assert.equal(await check(), 1)
  answer = { signed_in: true, mode: 'push', last_check: Math.floor(Date.now() / 1000) }
  assert.equal(await check(), 0)
})

test('list shows each channel and leaves out modules that are off', async (t) => {
  const s = await service(t, (route) => (route === '/status' ? { signed_in: true, mode: 'push', last_check: Math.floor(Date.now() / 1000), connected: true } : {}))
  const { env } = await home(s.url)
  const { stdout } = await run(process.execPath, [bin, 'list'], { env })
  assert.match(stdout, /email\s+ok\s+signed in, new mail by Google push/)
  assert.match(stdout, /whatsapp\s+ok\s+connected/)
  const off = await run(process.execPath, [bin, 'list'], { env: { ...env, FRAIM_MODULES: '' } })
  assert.match(off.stdout, /whatsapp\s+-\s+off/)
  assert.equal(s.calls.find((c) => c.method === 'GET').auth, 'Bearer gw-secret')
})

test('live messages always count; offline ones only while recent', () => {
  assert.equal(readsUpsert('notify', 0, 1000, 60), true)
  assert.equal(readsUpsert('append', 990, 1000, 60), true)
  assert.equal(readsUpsert('append', 900, 1000, 60), false)
  assert.equal(readsUpsert('append', 0, 1000, 60), false)
  assert.equal(readsUpsert('history', 999, 1000, 60), false)
})

test('reconnecting waits longer each time, up to a minute', () => {
  assert.deepEqual([0, 1, 2, 9].map(reconnectDelay), [3000, 6000, 12000, 60000])
})

test('the gateway restarts itself only when nothing else can bring it back', () => {
  const base = { downSince: 1000, waitingForQr: false, loggedOut: false, now: 9000, limitMs: 5000 }
  assert.equal(givesUp(base), true)
  assert.equal(givesUp({ ...base, now: 2000 }), false)
  assert.equal(givesUp({ ...base, downSince: null }), false)
  assert.equal(givesUp({ ...base, waitingForQr: true }), false)
  assert.equal(givesUp({ ...base, loggedOut: true }), false)
})

test('waiting messages survive a restart of the gateway', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'fraim-queue-'))
  const file = path.join(dir, 'queue.json')
  const before = new SavedQueue(file, 2)
  before.push({ id: 1 })
  before.push({ id: 2 })
  before.push({ id: 3 })
  const after = new SavedQueue(file, 2)
  assert.equal(after.length, 2)
  assert.deepEqual(after.drain().map((e) => e.id), [2, 3])
  assert.equal(new SavedQueue(file, 2).length, 0)
})

test('a damaged queue file is reported and the gateway still starts', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'fraim-queue-'))
  const file = path.join(dir, 'queue.json')
  await writeFile(file, 'not json')
  const errors = []
  assert.equal(new SavedQueue(file, 2, (e) => errors.push(e)).length, 0)
  assert.equal(errors.length, 1)
})

test('a message that waited offline says when it was sent', () => {
  assert.equal(catchUpNote({ text: 'hi' }), '')
  assert.match(catchUpNote({ catchup: true, ts: 1700000000 }), /^\(Sent at \d\d:\d\d while the server was offline/)
  assert.match(catchUpNote({ catchup: true }), /^\(Sent while the server/)
})
