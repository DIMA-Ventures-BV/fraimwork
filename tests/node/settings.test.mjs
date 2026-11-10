// The Settings screen: what it shows and how it changes the owner's files.
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { chmod, mkdir, mkdtemp, writeFile } from 'node:fs/promises'
import fs from 'node:fs'
import net from 'node:net'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const bin = path.join(here, '../../workspace/bin/fraim-queue')
const TOKEN = 'settings-test-token'

const freePort = () => new Promise((resolve) => {
  const s = net.createServer()
  s.listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => resolve(port)) })
})

async function start(t) {
  const home = await mkdtemp(path.join(tmpdir(), 'fraim-settings-'))
  const f = (p) => path.join(home, p)
  const put = async (p, text) => { await mkdir(path.dirname(f(p)), { recursive: true }); await writeFile(f(p), text) }
  await put('.config/fraim/queue-token', `${TOKEN}\n`)
  await put('fraim/leads/chief/lead.md', '---\nrole: chief\n---\n# Chief\n\n## Area\nEverything.\n')
  await put('fraim/leads/web/lead.md', '---\nrole: lead\n---\n# Web\n\n## Area\nThe shop.\n')
  await put('fraim/leads/web/tools', '# keep me\nmcp__posthog\nBash(npm audit:*)\n')
  await put('fraim/leads/web/budget', '3\n')
  await put('fraim/automations/chief/automation.md', '---\nschedule: "0 8 * * *"\nlead: chief\n---\n')
  await put('fraim/automations/web/automation.md', '---\ndescription: Lead web: the shop\nschedule: "0 6 * * 1-5"\nlead: web\n---\n')
  await put('fraim/automations/digest/automation.md', '---\ndescription: Mail digest\nevery: 1h\ntools: Read\n---\nRead the mail.\n')
  await put('fraim/brain/rules.md', '# Rules\n\n## General\n- Never use emoji. [r1: e1]\n\n## Lead web\n- Keep the shop fast. [r2: e2]\n')
  await put('fraim/claude/core/.mcp.json', JSON.stringify({ mcpServers: { posthog: { env: { KEY: 'sk-very-secret' } } } }))
  await put('fraim/claude/core/skills/deploy/SKILL.md', '---\nname: deploy\ndescription: Ship it\n---\nSteps.\n')
  await mkdir(f('fake'))
  await put('fake/fraim-auto', '#!/bin/sh\necho "fraim-auto $*" >> "$HOME/auto.log"\nif [ "$1" = check ] && grep -q "99 99" "$HOME/fraim/automations/$2/automation.md"; then echo "$2:"; echo "  - bad time"; exit 1; fi\nexit 0\n')
  await put('fake/fraim-lead', '#!/bin/sh\necho "fraim-lead $*" >> "$HOME/auto.log"\nexit 0\n')
  await put('fake/fraim-herdr', '#!/bin/sh\necho "[]"\n')
  for (const n of ['fraim-auto', 'fraim-lead', 'fraim-herdr']) await chmod(f(`fake/${n}`), 0o755)
  const port = await freePort()
  const env = { PATH: `${f('fake')}:${process.env.PATH}`, HOME: home, FRAIM_RUNTIME_ENV: '/dev/null', FRAIM_QUEUE_QUIET: '1', FRAIM_QUEUE_PORT: String(port), FRAIM_QUEUE_BIND: '127.0.0.1' }
  const server = spawn(process.execPath, [bin, 'serve'], { env, stdio: ['ignore', 'ignore', 'pipe'] })
  t.after(() => server.kill())
  await new Promise((resolve) => server.stderr.once('data', resolve))
  const base = `http://127.0.0.1:${port}`
  const headers = { Cookie: `fraim_queue=${TOKEN}`, 'Content-Type': 'application/json', 'X-Fraim-Queue': '1' }
  const get = async (p) => { const r = await fetch(base + p, { headers }); return { status: r.status, body: await r.json().catch(() => null) } }
  const post = async (p, b = {}) => { const r = await fetch(base + p, { method: 'POST', headers, body: JSON.stringify(b) }); return { status: r.status, body: await r.json().catch(() => null) } }
  return { base, f, read: (p) => fs.readFileSync(f(p), 'utf8'), get, post, headers }
}

test('settings need the token and a post needs the header', async (t) => {
  const s = await start(t)
  assert.equal((await fetch(`${s.base}/settings`)).status, 401)
  assert.equal((await fetch(`${s.base}/api/settings`)).status, 401)
  const page = await fetch(`${s.base}/settings`, { headers: s.headers })
  assert.match(await page.text(), /fraim settings/)
  const noHeader = await fetch(`${s.base}/api/settings/rules`, { method: 'POST', headers: { Cookie: `fraim_queue=${TOKEN}` }, body: '{}' })
  assert.equal(noHeader.status, 403)
})

test('the overview shows the whole setup and never a key', async (t) => {
  const s = await start(t)
  const raw = await fetch(`${s.base}/api/settings`, { headers: s.headers }).then((r) => r.text())
  assert.doesNotMatch(raw, /sk-very-secret/)
  const d = JSON.parse(raw)
  assert.deepEqual(d.people.map((p) => p.name), ['chief', 'web'])
  assert.deepEqual(d.watchers.map((p) => p.name), ['digest'])
  assert.deepEqual(d.services, ['posthog'])
  assert.ok(d.prompts.some((p) => p.name === 'chief-run'))
  assert.ok(d.docs.some((x) => x.file === 'prompts.md'))
  assert.equal(d.skills.find((x) => x.name === 'deploy').editable, true)
  assert.equal(d.skills.find((x) => x.name === 'deploy').file, undefined)
})

test('an employee page has its job, own rules, shared rules, tools and budget', async (t) => {
  const s = await start(t)
  const { body: e } = await s.get('/api/settings/employee/web')
  assert.match(e.job, /The shop/)
  assert.doesNotMatch(e.job, /role: lead/)
  assert.deepEqual(e.own.map((r) => r.text), ['Keep the shop fast.'])
  assert.deepEqual(e.shared[0].rules.map((r) => r.text), ['Never use emoji.'])
  assert.deepEqual(e.tools, ['mcp__posthog', 'Bash(npm audit:*)'])
  assert.equal(e.budget, '3')
  assert.equal((await s.get('/api/settings/employee/nobody')).status, 404)
})

test('saving a job keeps the first block, refuses a stale page and keeps a copy', async (t) => {
  const s = await start(t)
  const { body: e } = await s.get('/api/settings/employee/web')
  assert.equal((await s.post('/api/settings/employee/web/job', { text: '# Web\n\nNew job.', version: e.version })).status, 200)
  assert.equal(s.read('fraim/leads/web/lead.md'), '---\nrole: lead\n---\n# Web\n\nNew job.\n')
  assert.equal(fs.readdirSync(s.f('fraim/.settings-history')).length, 1)
  const stale = await s.post('/api/settings/employee/web/job', { text: 'Old page.', version: e.version })
  assert.equal(stale.status, 409)
  assert.match(s.read('fraim/leads/web/lead.md'), /New job/)
})

test('tools keep their comments and a bad entry is refused', async (t) => {
  const s = await start(t)
  await s.post('/api/settings/employee/web/tools', { entries: ['mcp__linear'] })
  assert.equal(s.read('fraim/leads/web/tools'), '# keep me\nmcp__linear\n')
  assert.equal((await s.post('/api/settings/employee/web/tools', { entries: ['a,b'] })).status, 400)
  assert.equal((await s.post('/api/settings/employee/digest/tools', { entries: ['Read', 'Grep'] })).status, 200)
  assert.match(s.read('fraim/automations/digest/automation.md'), /^tools: Read,Grep$/m)
})

test('a schedule change is checked, synced, and taken back when wrong', async (t) => {
  const s = await start(t)
  const ok = await s.post('/api/settings/employee/web/schedule', { automation: 'web', mode: 'every', value: '2h' })
  assert.equal(ok.status, 200)
  const text = s.read('fraim/automations/web/automation.md')
  assert.match(text, /^every: 2h$/m)
  assert.doesNotMatch(text, /^schedule:/m)
  assert.match(s.read('auto.log'), /fraim-auto sync/)
  const bad = await s.post('/api/settings/employee/web/schedule', { automation: 'web', mode: 'schedule', value: '99 99 * * *' })
  assert.equal(bad.status, 400)
  assert.equal(s.read('fraim/automations/web/automation.md'), text)
  assert.equal((await s.post('/api/settings/employee/web/schedule', { automation: 'digest', mode: 'every', value: '2h' })).status, 404)
})

test('rules are added, changed, removed and undone through the brain', async (t) => {
  const s = await start(t)
  const added = await s.post('/api/settings/rules', { action: 'add', text: 'Be brief.', lead: 'web' })
  assert.equal(added.status, 200)
  const section = () => s.read('fraim/brain/rules.md')
  assert.match(section(), /## Lead web[\s\S]*Be brief\./)
  assert.equal((await s.post('/api/settings/rules', { action: 'edit', id: 'r2', lead: 'web', text: 'Keep the shop very fast.' })).status, 200)
  assert.match(section(), /Keep the shop very fast\./)
  assert.doesNotMatch(section(), /Keep the shop fast\./)
  assert.equal((await s.post('/api/settings/rules', { action: 'remove', id: 'r1' })).status, 200)
  assert.doesNotMatch(section(), /Never use emoji/)
  assert.equal((await s.post('/api/settings/rules', { action: 'undo' })).status, 200)
  assert.match(section(), /Never use emoji/)
})

test('instructions are saved per employee, a broken one is refused, and reset works', async (t) => {
  const s = await start(t)
  const { body: p } = await s.get('/api/settings/prompt/lead-run?lead=web')
  assert.equal(p.source, 'default')
  const bad = await s.post('/api/settings/prompt/lead-run?lead=web', { text: 'Broken {{#x}}', version: p.version })
  assert.equal(bad.status, 400)
  assert.match(bad.body.error, /never closed/)
  assert.equal((await s.get('/api/settings/prompt/lead-run?lead=web')).body.source, 'default')
  const saved = await s.post('/api/settings/prompt/lead-run?lead=web', { text: 'Only this.', version: p.version })
  assert.equal(saved.status, 200)
  assert.equal(saved.body.source, 'lead web')
  assert.equal(s.read('fraim/leads/web/prompts/lead-run.md'), 'Only this.')
  assert.equal((await s.get('/api/settings/prompt/lead-run')).body.source, 'default')
  assert.equal((await s.post('/api/settings/prompt/lead-run/reset?lead=web')).body.source, 'default')
})

test('skills are found by listing only, and the name lines must stay', async (t) => {
  const s = await start(t)
  assert.equal((await s.get(`/api/settings/skill/${encodeURIComponent('core~../../../secrets')}`)).status, 404)
  const { body } = await s.get('/api/settings/skill/core~deploy')
  assert.equal((await s.post('/api/settings/skill/core~deploy', { text: 'no header', version: body.version })).status, 400)
  const text = '---\nname: deploy\ndescription: Ship it now\n---\nNew steps.\n'
  assert.equal((await s.post('/api/settings/skill/core~deploy', { text, version: body.version })).status, 200)
  assert.equal(s.read('fraim/claude/core/skills/deploy/SKILL.md'), text)
})

test('switching off and on goes through the commands', async (t) => {
  const s = await start(t)
  await s.post('/api/settings/employee/web/power', { on: false })
  await s.post('/api/settings/employee/digest/power', { on: true })
  const log = s.read('auto.log')
  assert.match(log, /fraim-lead pause web/)
  assert.match(log, /fraim-auto resume digest/)
})
