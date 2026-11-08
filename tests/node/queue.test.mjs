// The review queue: WhatsApp shortcuts (owner only) and the web page (token, decisions, media).
import assert from 'node:assert/strict'
import { execFileSync, spawn } from 'node:child_process'
import { mkdtemp, writeFile, chmod, mkdir } from 'node:fs/promises'
import fs from 'node:fs'
import net from 'node:net'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { parseQueueCommand, queueArgs } from '../../workspace/channel/queue-command.mjs'

const OWNER = '31612345678'
const msg = (text, sender = OWNER) => ({ type: 'message', sender, text })
const here = path.dirname(fileURLToPath(import.meta.url))
const bin = path.join(here, '../../workspace/bin/fraim-queue')

test('queue shortcuts', () => {
  assert.deepEqual(parseQueueCommand(msg('queue'), OWNER), { action: 'list' })
  assert.deepEqual(parseQueueCommand(msg('/Leads'), OWNER), { action: 'leads' })
  assert.deepEqual(parseQueueCommand(msg('ok q3'), OWNER), { action: 'approve', id: 'q3', note: '' })
  assert.deepEqual(parseQueueCommand(msg('OK Q3 ship it'), OWNER), { action: 'approve', id: 'q3', note: 'ship it' })
  assert.deepEqual(parseQueueCommand(msg('no q12 use the brand green\nnot blue'), OWNER), {
    action: 'reject', id: 'q12', note: 'use the brand green\nnot blue',
  })
  assert.deepEqual(parseQueueCommand(msg('skip q4'), OWNER), { action: 'dismiss', id: 'q4' })
  assert.deepEqual(parseQueueCommand(msg('remember: no emoji, ever'), OWNER), { action: 'remember', text: 'no emoji, ever' })
})

test('queue args', () => {
  assert.deepEqual(queueArgs({ action: 'reject', id: 'q1', note: 'why' }), ['fraim-queue', ['reject', 'q1', '--note', 'why']])
  assert.deepEqual(queueArgs({ action: 'approve', id: 'q1', note: '' }), ['fraim-queue', ['approve', 'q1']])
  assert.deepEqual(queueArgs({ action: 'remember', text: 'x' }), ['fraim-brain', ['note', 'x']])
})

test('only the owner, and normal messages pass through', () => {
  assert.equal(parseQueueCommand(msg('ok q1', '4915112345678'), OWNER), null)
  for (const text of ['ok', 'no', 'no abcde', 'yes abcde', 'queue up the songs', 'ok qq', 'remember:  ', 'okay q1']) {
    assert.equal(parseQueueCommand(msg(text), OWNER), null, text)
  }
})

const freePort = () =>
  new Promise((resolve) => {
    const s = net.createServer()
    s.listen(0, '127.0.0.1', () => {
      const { port } = s.address()
      s.close(() => resolve(port))
    })
  })

test('the page needs the token, shows items, serves media and records decisions', async (t) => {
  const home = await mkdtemp(path.join(tmpdir(), 'fraim-queue-'))
  const fake = path.join(home, 'bin')
  await mkdir(fake)
  await writeFile(path.join(fake, 'fraim-goal'), '#!/bin/sh\necho g5\n')
  await writeFile(path.join(fake, 'fraim-notify'), '#!/bin/sh\nexit 0\n')
  await chmod(path.join(fake, 'fraim-goal'), 0o755)
  await chmod(path.join(fake, 'fraim-notify'), 0o755)
  const port = await freePort()
  const env = {
    PATH: `${fake}:${process.env.PATH}`, HOME: home, FRAIM_RUNTIME_ENV: '/dev/null', FRAIM_QUEUE_QUIET: '1',
    FRAIM_QUEUE_PORT: String(port), FRAIM_QUEUE_BIND: '127.0.0.1',
  }
  const cli = (...args) => execFileSync(process.execPath, [bin, ...args], { env, encoding: 'utf8' }).trim()
  await writeFile(path.join(home, 'shot.png'), 'png-bytes')
  cli('add', '--title', 'With a picture', '--goal', 'g1', '--media', path.join(home, 'shot.png'))
  cli('add', '--title', 'Plain', '--priority', '1')
  const token = cli('token')

  const server = spawn(process.execPath, [bin, 'serve'], { env, stdio: ['ignore', 'ignore', 'pipe'] })
  t.after(() => server.kill())
  await new Promise((resolve) => server.stderr.once('data', resolve))
  const base = `http://127.0.0.1:${port}`

  assert.equal((await fetch(`${base}/health`)).status, 200)
  assert.equal((await fetch(`${base}/api/items`)).status, 401)
  assert.equal((await fetch(`${base}/?t=wrong`, { redirect: 'manual' })).status, 403)
  const login = await fetch(`${base}/?t=${token}`, { redirect: 'manual' })
  assert.equal(login.status, 303)
  const cookie = login.headers.get('set-cookie').split(';')[0]
  assert.match(login.headers.get('set-cookie'), /HttpOnly; SameSite=Strict/)
  const get = (p) => fetch(base + p, { headers: { cookie } })
  const post = (p, body, headers = { 'X-Fraim-Queue': '1' }) =>
    fetch(base + p, { method: 'POST', headers: { cookie, 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body) })

  assert.match(await (await get('/')).text(), /<title>fraim queue<\/title>/)
  const items = await (await get('/api/items')).json()
  assert.deepEqual(items.map((i) => i.id), ['q2', 'q1'], 'priority 1 first')
  assert.equal(await (await get('/media/q1/shot.png')).text(), 'png-bytes')
  assert.equal((await get('/media/q1/..%2Fitem.json')).status, 404)

  assert.equal((await post('/api/items/q1/decide', { verdict: 'approved' }, {})).status, 403, 'no cross-site posts')
  assert.equal((await post('/api/items/q1/decide', { verdict: 'rejected', note: '' })).status, 400)
  const rejected = await (await post('/api/items/q1/decide', { verdict: 'rejected', note: 'crop the picture' })).json()
  assert.equal(rejected.state, 'rejected')
  assert.equal(rejected.follow_up, 'g5')
  assert.equal((await post('/api/items/q1/decide', { verdict: 'approved' })).status, 409)
  assert.equal((await (await post('/api/items/q2/priority', { priority: 3 })).json()).priority, 3)
  assert.deepEqual((await (await get('/api/items')).json()).map((i) => i.id), ['q2'])
  assert.equal((await (await get('/api/items?all=1')).json()).length, 2)
  assert.match(fs.readFileSync(path.join(home, 'fraim/brain/log.md'), 'utf8'), /rejected q1 "With a picture": crop the picture/)
})
