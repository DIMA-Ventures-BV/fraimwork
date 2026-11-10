// The documented API a customer's own screen builds on: /api/v1, scoped tokens, CORS, events.
import assert from 'node:assert/strict'
import { execFileSync, spawn, spawnSync } from 'node:child_process'
import { chmod, mkdir, mkdtemp, writeFile } from 'node:fs/promises'
import fs from 'node:fs'
import net from 'node:net'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const bin = path.join(here, '../../workspace/bin/fraim-queue')
const schemaFile = path.join(here, '../../workspace/bin/fraim-queue-openapi.json')

const freePort = () => new Promise((resolve) => {
  const s = net.createServer()
  s.listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => resolve(port)) })
})

async function setup(t, extraEnv = {}) {
  const home = await mkdtemp(path.join(tmpdir(), 'fraim-api-'))
  const fake = path.join(home, 'bin')
  await mkdir(fake)
  const log = path.join(home, 'calls.log')
  await writeFile(path.join(fake, 'fraim-goal'), `#!/bin/sh\nprintf '%s\\n' "$*" >> ${log}\necho g5\n`)
  await writeFile(path.join(fake, 'fraim-notify'), '#!/bin/sh\nexit 0\n')
  await writeFile(path.join(fake, 'fraim-lead'), `#!/bin/sh\nprintf 'lead %s\\n' "$*" >> ${log}\n`)
  await writeFile(path.join(fake, 'fraim-herdr'), `#!/bin/sh\necho '[{"name":"s2","kind":"session","status":"blocked","question":"Which one?","cwd":"/code"}]'\n`)
  for (const f of ['fraim-goal', 'fraim-notify', 'fraim-lead', 'fraim-herdr']) await chmod(path.join(fake, f), 0o755)
  const port = await freePort()
  const env = {
    PATH: `${fake}:${process.env.PATH}`, HOME: home, FRAIM_RUNTIME_ENV: '/dev/null', FRAIM_QUEUE_QUIET: '1',
    FRAIM_QUEUE_PORT: String(port), FRAIM_QUEUE_BIND: '127.0.0.1', ...extraEnv,
  }
  const autos = path.join(home, 'fraim/automations')
  await mkdir(path.join(autos, 'web'), { recursive: true })
  await mkdir(path.join(home, 'fraim/leads/web'), { recursive: true })
  await writeFile(path.join(home, 'fraim/leads/web/lead.md'), '---\nrole: lead\n---\n')
  await writeFile(path.join(autos, 'web/automation.md'), '---\ndescription: The shop\nschedule: "0 6 * * 1-5"\nlead: web\n---\n')
  const cli = (...args) => execFileSync(process.execPath, [bin, ...args], { env, encoding: 'utf8' }).trim()
  const cliAs = (extra, ...args) => spawnSync(process.execPath, [bin, ...args], { env: { ...env, ...extra }, encoding: 'utf8' })
  const server = spawn(process.execPath, [bin, 'serve'], { env, stdio: ['ignore', 'ignore', 'pipe'] })
  t.after(() => server.kill())
  await new Promise((resolve) => server.stderr.once('data', resolve))
  const base = `http://127.0.0.1:${port}`
  const call = (token, p, opts = {}) => fetch(base + p, { ...opts, headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(opts.body ? { 'Content-Type': 'application/json' } : {}), ...opts.headers } })
  const post = (token, p, body, headers = {}) => call(token, p, { method: 'POST', body: JSON.stringify(body), headers })
  return { home, env, cli, cliAs, base, call, post, log: () => (fs.existsSync(log) ? fs.readFileSync(log, 'utf8') : '') }
}

const newToken = (s, name, scope, ...origins) => s.cli('token', 'new', '--name', name, '--scope', scope, ...origins.flatMap((o) => ['--origin', o]))

test('tokens: scoped, stored only as a hash, and a run nobody watches cannot manage them', async (t) => {
  const s = await setup(t)
  const reader = newToken(s, 'reader', 'read')
  assert.match(reader, /^fq_[\w-]{40,}$/)
  const file = path.join(s.home, '.config/fraim/authority/api-tokens')
  const stored = fs.readFileSync(file, 'utf8')
  assert.ok(!stored.includes(reader), 'the token itself is never stored')
  assert.equal(fs.statSync(file).mode & 0o777, 0o600)
  assert.match(s.cli('token', 'list'), /reader\s+read/)
  assert.ok(!s.cli('token', 'list').includes(JSON.parse(stored.split('\n')[0]).hash), 'list shows no hash')

  for (const args of [['new', '--name', 'x', '--scope', 'read'], ['list'], ['rm', 'reader']]) {
    const r = s.cliAs({ FRAIM_HEADLESS: '1' }, 'token', ...args)
    assert.equal(r.status, 1, `headless token ${args[0]} is refused`)
    assert.match(r.stderr, /only the owner/)
  }
  assert.equal(s.cliAs({}, 'token', 'new', '--name', 'x', '--scope', 'admin').status, 2)
  assert.equal(s.cliAs({}, 'token', 'new', '--name', 'y', '--scope', 'read', '--origin', 'https://*.example.com').status, 2)
  assert.equal(s.cliAs({}, 'token', 'new', '--name', 'reader', '--scope', 'read').status, 1, 'a name is used once')

  assert.equal((await s.call(reader, '/api/v1/items')).status, 200)
  assert.equal((await s.call('fq_wrong', '/api/v1/items')).status, 401)
  assert.equal((await s.call('', '/api/v1/items')).status, 401)
  s.cli('token', 'rm', 'reader')
  assert.equal((await s.call(reader, '/api/v1/items')).status, 401, 'a removed token stops working')
  assert.equal(s.cliAs({}, 'token', 'rm', 'reader').status, 1)
})

test('items: pagination, state filter, get, create and decide through the owner path', async (t) => {
  const s = await setup(t)
  const reader = newToken(s, 'reader', 'read')
  const writer = newToken(s, 'writer', 'write')
  const decider = newToken(s, 'decider', 'decide')
  for (const title of ['One', 'Two', 'Three']) s.cli('add', '--title', title)

  const page = await (await s.call(reader, '/api/v1/items?limit=2&offset=1')).json()
  assert.deepEqual([page.total, page.limit, page.offset, page.items.length], [3, 2, 1, 2])
  assert.equal((await s.call(reader, '/api/v1/items?limit=9999')).status, 400)
  assert.equal((await s.call(reader, '/api/v1/items?state=maybe')).status, 400)
  const one = await (await s.call(reader, '/api/v1/items/q1')).json()
  assert.equal(one.title, 'One')
  assert.equal((await s.call(reader, '/api/v1/items/q99')).status, 404)

  assert.equal((await s.post(reader, '/api/v1/items', { title: 'No' })).status, 403, 'read cannot write')
  const created = await s.post(writer, '/api/v1/items', {
    title: 'From my app', ask: 'Ship it?', if_yes: 'It ships', kind: 'decision', links: ['https://example.com/a'],
    on_approve: 'rm -rf everything', approved_by: 'q1', approvedBy: 'q1', switch_on: 'x', switchOn: 'x', media: ['/etc/hosts'], source: 'the owner in the chat', reply: { to: 'x' },
  })
  assert.equal(created.status, 201)
  const item = await created.json()
  assert.equal(item.state, 'open', 'a new item always waits for the owner')
  assert.equal(item.if_yes, 'It ships')
  assert.equal(item.on_approve, '', 'a write token cannot plant a next step')
  assert.equal(item.switch_on, '')
  assert.deepEqual(item.media, [])
  assert.equal(item.reply, undefined)
  assert.equal(item.source, 'app writer')
  assert.equal((await s.post(writer, '/api/v1/items', { title: 'Bad', links: ['javascript:alert(1)'] })).status, 400)
  assert.equal((await s.post(writer, '/api/v1/items', {})).status, 400)
  assert.equal((await s.post(writer, '/api/v1/items', { title: 'x'.repeat(70000) })).status, 413)

  assert.equal((await s.post(writer, '/api/v1/items/q1/decide', { verdict: 'approved' })).status, 403, 'write cannot decide')
  const decided = await s.post(decider, '/api/v1/items/q1/decide', { verdict: 'approved', note: 'ok' })
  assert.equal(decided.status, 200)
  const body = await decided.json()
  assert.deepEqual([body.state, body.via], ['approved', 'api:decider'])
  assert.equal((await s.post(decider, '/api/v1/items/q1/decide', { verdict: 'approved' })).status, 409)
  assert.equal((await s.post(decider, '/api/v1/items/q2/decide', { verdict: 'rejected' })).status, 400, 'reject needs a reason')
  const open = await (await s.call(reader, '/api/v1/items?state=open')).json()
  assert.ok(open.items.every((i) => i.state === 'open'))
  assert.equal(open.total, 3)
})

test('a run nobody watches cannot approve through the API either', async (t) => {
  const s = await setup(t, { FRAIM_HEADLESS: '1' })
  await mkdir(path.join(s.home, '.config/fraim/authority'), { recursive: true })
  const r = s.cliAs({ FRAIM_HEADLESS: '' }, 'token', 'new', '--name', 'd', '--scope', 'decide')
  assert.equal(r.status, 0)
  s.cliAs({ FRAIM_HEADLESS: '' }, 'add', '--title', 'Wait')
  const refused = await s.post(r.stdout.trim(), '/api/v1/items/q1/decide', { verdict: 'approved' })
  assert.equal(refused.status, 403)
  assert.match((await refused.json()).error, /only the owner/)
  assert.equal(JSON.parse(s.cli('show', 'q1', '--json')).state, 'open')
})

test('threads and agents: raw fields, say, and a message through fraim-lead tell', async (t) => {
  const s = await setup(t)
  const reader = newToken(s, 'reader', 'read')
  const writer = newToken(s, 'writer', 'write')
  await writeFile(path.join(s.home, 'put.json'), JSON.stringify({ kind: 'linear', key: 'l-1', title: 'Issue', who: 'Ann', text: 'Hello' }))
  assert.equal(s.cli('thread', 'put', '--file', path.join(s.home, 'put.json'), '--quiet'), 't1')
  s.cli('thread', 'say', 't1', '--from', 'web', '--', 'I looked.\nDetails:\nlogs')

  const list = await (await s.call(reader, '/api/v1/threads?limit=10')).json()
  assert.equal(list.total, 1)
  assert.deepEqual([list.threads[0].id, list.threads[0].who], ['t1', 'Ann'])
  assert.equal(list.threads[0].messages, undefined, 'a list stays small')
  const thread = await (await s.call(reader, '/api/v1/threads/t1')).json()
  assert.equal(thread.chat[0].from, 'web', 'the raw name, not a display word')
  assert.match(thread.chat[0].text, /Details:/, 'the raw text')

  assert.equal((await s.post(reader, '/api/v1/threads/t1/say', { text: 'x' })).status, 403)
  assert.equal((await s.post(writer, '/api/v1/threads/t9/say', { text: 'x' })).status, 404)
  assert.equal((await s.post(writer, '/api/v1/threads/t1/say', { text: '' })).status, 400)
  assert.equal((await s.post(writer, '/api/v1/threads/t1/say', { text: 'From the app' })).status, 201)
  const chat = (await (await s.call(reader, '/api/v1/threads/t1')).json()).chat
  assert.deepEqual([chat[1].from, chat[1].text], ['app-writer', 'From the app'], 'an app never speaks as the owner')

  const agents = (await (await s.call(reader, '/api/v1/agents')).json()).agents
  const web = agents.find((a) => a.name === 'web')
  assert.deepEqual([web.kind, web.lead, web.role, web.schedule, web.description], ['lead', 'web', 'lead', '0 6 * * 1-5', 'The shop'])
  assert.equal(web.title, undefined, 'no display words')
  assert.equal(agents.find((a) => a.name === 's2').status, 'blocked')

  assert.equal((await s.post(reader, '/api/v1/agents/web/messages', { text: 'x' })).status, 403)
  assert.equal((await s.post(writer, '/api/v1/agents/nobody/messages', { text: 'x' })).status, 404)
  assert.equal((await s.post(writer, '/api/v1/agents/web/messages', { text: 'Check the shop' })).status, 202)
  assert.match(s.log(), /lead tell web --from app-writer -- Check the shop/)
})

test('the page cookie works on v1, needs the header to post, and never gets CORS', async (t) => {
  const s = await setup(t)
  s.cli('add', '--title', 'One')
  const login = await fetch(`${s.base}/?t=${s.cli('token')}`, { redirect: 'manual' })
  const cookie = login.headers.get('set-cookie').split(';')[0]
  const origin = 'https://app.example.com'
  newToken(s, 'app', 'read', origin)
  const read = await s.call('', '/api/v1/items', { headers: { cookie, Origin: origin } })
  assert.equal(read.status, 200)
  assert.equal(read.headers.get('access-control-allow-origin'), null, 'credentialed cookies never get CORS')
  assert.equal((await s.post('', '/api/v1/items/q1/decide', { verdict: 'approved' }, { cookie })).status, 403, 'no cross-site posts')
  const ok = await s.post('', '/api/v1/items/q1/decide', { verdict: 'approved' }, { cookie, 'X-Fraim-Queue': '1' })
  assert.equal((await ok.json()).via, 'page')
})

test('CORS: only origins a token lists, OPTIONS without auth, no credentials', async (t) => {
  const s = await setup(t)
  const origin = 'https://app.example.com'
  const token = newToken(s, 'app', 'read', origin)
  const other = newToken(s, 'other', 'read')

  const preflight = await fetch(`${s.base}/api/v1/items`, { method: 'OPTIONS', headers: { Origin: origin, 'Access-Control-Request-Method': 'GET' } })
  assert.equal(preflight.status, 204)
  assert.equal(preflight.headers.get('access-control-allow-origin'), origin)
  assert.match(preflight.headers.get('access-control-allow-headers'), /authorization/i)
  assert.equal(preflight.headers.get('access-control-allow-credentials'), null)
  assert.equal(preflight.headers.get('vary'), 'Origin')
  const stranger = await fetch(`${s.base}/api/v1/items`, { method: 'OPTIONS', headers: { Origin: 'https://evil.example.com' } })
  assert.equal(stranger.headers.get('access-control-allow-origin'), null)

  const listed = await s.call(token, '/api/v1/items', { headers: { Origin: origin } })
  assert.equal(listed.headers.get('access-control-allow-origin'), origin)
  assert.equal(listed.headers.get('access-control-allow-credentials'), null)
  assert.equal((await s.call(other, '/api/v1/items', { headers: { Origin: origin } })).status, 403, 'an origin must be on the token it uses')
  const noOrigin = await s.call(token, '/api/v1/items')
  assert.equal(noOrigin.status, 200, 'a server-side caller sends no Origin')
  assert.equal(noOrigin.headers.get('access-control-allow-origin'), null)
})

test('events tell a screen what changed, and stop when the token is removed', async (t) => {
  const s = await setup(t)
  const reader = newToken(s, 'reader', 'read')
  assert.equal((await s.call('', '/api/v1/events')).status, 401)
  const stream = await s.call(reader, '/api/v1/events')
  assert.match(stream.headers.get('content-type'), /text\/event-stream/)
  const reader2 = stream.body.getReader()
  let seen = ''
  const until = async (re) => {
    while (!re.test(seen)) {
      const { value, done } = await reader2.read()
      if (done) return false
      seen += Buffer.from(value).toString()
    }
    return true
  }
  assert.ok(await until(/event: ready/))
  s.cli('add', '--title', 'New')
  assert.ok(await until(/event: item\.changed\ndata: \{"id":"q1"\}/))
  await writeFile(path.join(s.home, 'put.json'), JSON.stringify({ kind: 'other', key: 'k', title: 'T' }))
  s.cli('thread', 'put', '--file', path.join(s.home, 'put.json'), '--quiet')
  assert.ok(await until(/event: thread\.changed\ndata: \{"id":"t1"\}/))
  s.cli('token', 'rm', 'reader')
  assert.equal(await until(/never/), false, 'the stream ends when its token is gone')
})

test('the schema is served and matches the real routes', async (t) => {
  const s = await setup(t)
  const reader = newToken(s, 'reader', 'read')
  const onDisk = JSON.parse(fs.readFileSync(schemaFile, 'utf8'))
  assert.match(onDisk.openapi, /^3\./)
  assert.deepEqual(await (await s.call(reader, '/api/v1/schema')).json(), onDisk)
  const { ROUTES } = await import(path.join(here, '../../workspace/bin/fraim-queue-api.mjs'))
  const documented = Object.entries(onDisk.paths).flatMap(([p, ops]) => Object.entries(ops).map(([m, op]) => `${m.toUpperCase()} ${p} ${op['x-scope']}`)).sort()
  assert.deepEqual(documented, ROUTES.map((r) => `${r.method} ${r.path} ${r.scope}`).sort())
  for (const [p, ops] of Object.entries(onDisk.paths)) {
    const names = [...p.matchAll(/\{(\w+)\}/g)].map((m) => m[1])
    for (const op of Object.values(ops)) {
      assert.deepEqual((op.parameters || []).filter((x) => x.in === 'path').map((x) => x.name).sort(), names.sort(), `${p} declares its path parameters`)
      assert.ok(op.responses, `${p} documents responses`)
    }
  }
})

test('old routes and the shipped page keep working next to v1', async (t) => {
  const s = await setup(t)
  s.cli('add', '--title', 'One')
  assert.equal((await fetch(`${s.base}/health`)).status, 200)
  assert.equal((await fetch(`${s.base}/api/items`)).status, 401)
  const login = await fetch(`${s.base}/?t=${s.cli('token')}`, { redirect: 'manual' })
  const cookie = login.headers.get('set-cookie').split(';')[0]
  assert.equal((await (await fetch(`${s.base}/api/items`, { headers: { cookie } })).json())[0].title, 'One')
})

test('what a goal is told on approve and rework comes from prompt files the owner can change', async (t) => {
  const s = await setup(t)
  s.cli('add', '--title', 'Do it', '--goal', 'g1', '--summary', 'the result', '--on-approve', 'the next step')
  s.cli('approve', 'q1', '--note', 'go')
  assert.match(s.log(), /The owner approved queue item q1 \("Do it"\)\. Do this approved next step now:\nthe next step\n\nThe owner added: go\n\nContext and earlier work: ~\/fraim\/goals\/g1\./)
  s.cli('add', '--title', 'Redo', '--goal', 'g2', '--summary', 'old work')
  s.cli('reject', 'q2', '--note', 'use green')
  assert.match(s.log(), /Rework after the owner's review of queue item q2 \("Redo"\)\.\n\nThe original goal:\nRedo\n\nYour previous result:\nold work\n\nThe owner's feedback, which wins over anything above:\nuse green\n\nEarlier notes and files are in ~\/fraim\/goals\/g2\. Build on that work instead of starting over\./)
  await mkdir(path.join(s.home, 'fraim/prompts'), { recursive: true })
  await writeFile(path.join(s.home, 'fraim/prompts/queue-rework.md'), 'Mine: {{note}}\n')
  s.cli('add', '--title', 'Again', '--goal', 'g3')
  s.cli('reject', 'q3', '--note', 'owner words')
  assert.match(s.log(), /Mine: owner words/, "the owner's file wins")
})
