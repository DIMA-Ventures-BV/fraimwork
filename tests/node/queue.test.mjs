// The review queue web page (token, decisions, media).
import assert from 'node:assert/strict'
import { execFileSync, spawn } from 'node:child_process'
import { mkdtemp, writeFile, chmod, mkdir } from 'node:fs/promises'
import fs from 'node:fs'
import net from 'node:net'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const bin = path.join(here, '../../workspace/bin/fraim-queue')


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
  await writeFile(path.join(fake, 'fraim-herdr'), `#!/bin/sh\necho '[{"name":"s2","kind":"session","status":"blocked","question":"Old covers too?","cwd":"/code"},{"name":"bash1","kind":"shell","status":"none"}]'\n`)
  await writeFile(path.join(fake, 'hc'), '#!/bin/sh\necho "screen of $2"\n')
  await chmod(path.join(fake, 'fraim-herdr'), 0o755)
  await chmod(path.join(fake, 'hc'), 0o755)
  await chmod(path.join(fake, 'fraim-goal'), 0o755)
  await chmod(path.join(fake, 'fraim-notify'), 0o755)
  const port = await freePort()
  const env = {
    PATH: `${fake}:${process.env.PATH}`, HOME: home, FRAIM_RUNTIME_ENV: '/dev/null', FRAIM_QUEUE_QUIET: '1',
    FRAIM_QUEUE_PORT: String(port), FRAIM_QUEUE_BIND: '127.0.0.1',
  }
  const cli = (...args) => execFileSync(process.execPath, [bin, ...args], { env, encoding: 'utf8' }).trim()
  const autos = path.join(home, 'fraim/automations')
  const state = path.join(home, '.local/state/fraim/automations')
  for (const d of ['chief', 'web', 'digest']) {
    await mkdir(path.join(autos, d), { recursive: true })
    await mkdir(path.join(state, d), { recursive: true })
  }
  await mkdir(path.join(home, 'fraim/leads/chief/runs'), { recursive: true })
  await mkdir(path.join(home, 'fraim/leads/web'), { recursive: true })
  await writeFile(path.join(home, 'fraim/leads/chief/lead.md'), '---\nrole: chief\n---\n')
  await writeFile(path.join(home, 'fraim/leads/web/lead.md'), '---\nrole: lead\n---\n')
  await writeFile(path.join(home, 'fraim/leads/chief/runs/20261109-080000.md'), 'Two things today.\n\n--- inbox this run read ---\n[m1] engineer: built it\n')
  await writeFile(path.join(autos, 'chief/automation.md'), '---\nschedule: "0 8 * * *"\nlead: chief\n---\n')
  await writeFile(path.join(autos, 'web/automation.md'), '---\ndescription: Lead web: the shop\nschedule: "0 6 * * 1-5"\nlead: web\n---\n')
  await writeFile(path.join(autos, 'digest/automation.md'), '---\ndescription: Mail digest\nevery: 1h  # hourly\n---\nDo it.\n')
  await writeFile(path.join(state, 'web/last_status'), 'failed 2026-11-09 06:00 Claude stopped with exit code 1\n')
  await writeFile(path.join(state, 'digest/paused'), 'by the owner\n')
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
  const team = await (await get('/api/team')).json()
  assert.equal(team.chief.text, 'Two things today.')
  assert.equal(team.chief.time, '2026-11-09 08:00')
  assert.deepEqual(team.leads.map((l) => [l.name, l.role, l.status]), [['chief', 'chief', 'never'], ['web', 'lead', 'failed']])
  assert.equal(team.leads[1].description, 'the shop')
  assert.deepEqual(team.automations.map((a) => [a.name, a.when, a.status]), [['digest', 'every 1h', 'paused']])
  assert.equal((await fetch(`${base}/api/team`)).status, 401)
  await mkdir(path.join(state, 'web/lock'))
  const act = await (await get('/api/active')).json()
  assert.deepEqual(act.map((a) => [a.name, a.kind, a.status]), [['s2', 'session', 'blocked'], ['web', 'lead', 'working']], 'shells are left out, blocked first')
  assert.equal(act[0].question, 'Old covers too?')
  assert.equal((await (await get('/api/active/s2/screen')).json()).text.trim(), 'screen of s2')
  await mkdir(path.join(home, 'fraim/leads/web/.running'), { recursive: true })
  await writeFile(path.join(home, 'fraim/leads/web/.running/live.jsonl'), [
    { type: 'system', subtype: 'init' },
    { type: 'assistant', message: { content: [{ type: 'text', text: 'Checking the shop.' }, { type: 'tool_use', name: 'Bash', input: { command: 'curl -s https://shop.example/health' } }] } },
    { type: 'user', message: { content: [{ type: 'tool_result', content: 'ok' }] } },
  ].map((e) => JSON.stringify(e)).join('\n') + '\n')
  assert.equal(act[1].live, true, 'a lead run shows what it does')
  assert.equal((await (await get('/api/active/web/screen')).json()).text, 'Checking the shop.\n\n> Bash: curl -s https://shop.example/health')
  assert.equal((await get('/api/active/..%2Fx/screen')).status, 404)
  assert.equal((await post('/api/active/s2/send', { text: 'hi' }, {})).status, 403, 'no cross-site sends')
  assert.equal((await post('/api/active/web/send', { text: 'hi' })).status, 500, 'a lead run takes no messages')
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
