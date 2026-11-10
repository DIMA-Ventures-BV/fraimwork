// The Settings screen of the queue app: everything that decides how the agents work, in one
// place and in plain words. It reads and writes the same files the commands and the chief use;
// it has no settings of its own. fraim-queue serves it on /settings. See docs/settings.md.
import { spawnSync } from 'node:child_process'
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HOME = process.env.HOME || '/home/claude'
const FILES = process.env.FRAIM_FILES_DIR || path.join(HOME, 'fraim')
const LEADS = process.env.FRAIM_LEADS_DIR || path.join(FILES, 'leads')
const AUTOS = process.env.FRAIM_AUTOMATIONS_DIR || path.join(FILES, 'automations')
const BRAIN = process.env.FRAIM_BRAIN_DIR || path.join(FILES, 'brain')
const SKILLS = process.env.FRAIM_SKILLS_DIR || path.join(HOME, '.claude/skills')
const HISTORY = path.join(FILES, '.settings-history')
const KEEP_COPIES = 20

const here = path.dirname(fileURLToPath(import.meta.url))
const checkout = (dir, installed) => (fs.existsSync(path.join(here, '../..', dir)) ? path.join(here, '../..', dir) : installed)
const DOCS = process.env.FRAIM_DOCS_DIR || checkout('docs', '/etc/fraim/docs')
const SHIPPED_SKILLS = path.join(process.env.FRAIM_SERVER_PLUGIN || checkout('server-plugin', '/opt/fraim/server-plugin'), 'skills')

const NAME = '[a-z0-9][a-z0-9_-]{0,47}'
const TOOL_ENTRY = /^[A-Za-z0-9_*().\/:~@ -]{1,200}$/
const CRON = /^[0-9*\/,-]+( [0-9*\/,-]+){4}$/
const EVERY = /^[1-9][0-9]{0,3}[mhd]$/
const NOTE_FILES = {
  inbox: path.join(FILES, 'inbox-rules.md'),
  voice: path.join(FILES, 'styles/voice.md'),
}

class Refused extends Error {
  constructor(message, status = 400) { super(message); this.status = status }
}

const read = (file) => { try { return fs.readFileSync(file, 'utf8') } catch { return null } }
const list = (dir) => { try { return fs.readdirSync(dir).filter((n) => !n.startsWith('.')).sort() } catch { return [] } }
const version = (text) => crypto.createHash('sha256').update(text ?? '').digest('hex').slice(0, 16)

function keepCopy(file, text) {
  fs.mkdirSync(HISTORY, { recursive: true })
  const key = path.relative(HOME, file).replace(/[\\/]/g, '__')
  const stamp = new Date().toISOString().replace(/[-:.]/g, '').slice(0, 18)
  fs.writeFileSync(path.join(HISTORY, `${key}.${stamp}`), text)
  const copies = list(HISTORY).filter((n) => n.startsWith(`${key}.`))
  for (const old of copies.slice(0, -KEEP_COPIES)) fs.rmSync(path.join(HISTORY, old), { force: true })
}

function writeFile(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true })
  const tmp = `${file}.${process.pid}.tmp`
  fs.writeFileSync(tmp, text)
  fs.renameSync(tmp, file)
}

// An agent or a second window may have changed the file after this page read it: the owner
// must never overwrite that without seeing it.
function replaceFile(file, text, seen) {
  const old = read(file)
  if (seen !== undefined && seen !== version(old)) throw new Refused('Someone changed this in the meantime. Reload the page and make your change again.', 409)
  if (old !== null) keepCopy(file, old)
  writeFile(file, text)
}

function splitFront(text) {
  const m = /^---\r?\n[\s\S]*?\r?\n---[ \t]*\r?\n?/.exec(text || '')
  return m ? { front: m[0], body: text.slice(m[0].length) } : { front: '', body: text || '' }
}

function frontValue(front, key) {
  const m = new RegExp(`^${key}:[ \\t]*(.*)$`, 'm').exec(front)
  return m ? m[1].replace(/[ \t]+#.*$/, '').trim().replace(/^(["'])(.*)\1$/, '$2') : ''
}

function setFront(text, key, value) {
  const { front, body } = splitFront(text)
  const lines = front.trimEnd().split(/\r?\n/)
  const at = lines.findIndex((l) => l.startsWith(`${key}:`))
  if (value === null) { if (at >= 0) lines.splice(at, 1) } else {
    const line = `${key}: ${value}`
    if (at >= 0) lines[at] = line
    else lines.splice(lines.length - 1, 0, line)
  }
  return `${lines.join('\n')}\n${body}`
}

export function parseRules(text) {
  const sections = []
  let section = null
  for (const line of String(text || '').split('\n')) {
    if (/^## /.test(line)) { section = { name: line.slice(3).trim(), rules: [] }; sections.push(section); continue }
    const m = /^- (.*?) \[(r\d+)(?::[^\]]*)?\]\s*$/.exec(line)
    if (!m) continue
    if (!section) { section = { name: 'General', rules: [] }; sections.push(section) }
    section.rules.push({ id: m[2], text: m[1] })
  }
  return sections.filter((s) => s.rules.length)
}

function skillInfo(dir, id, group, editable) {
  const file = path.join(dir, 'SKILL.md')
  const text = read(file)
  if (text === null) return null
  const front = splitFront(text).front
  return { id, name: frontValue(front, 'name') || path.basename(dir), about: frontValue(front, 'description'), group, editable, file }
}

function allSkills() {
  const out = []
  const add = (dir, source, group, editable) => {
    for (const n of list(dir)) {
      if (fs.lstatSync(path.join(dir, n)).isSymbolicLink()) continue
      const s = skillInfo(path.join(dir, n), `${source}~${n}`, group, editable)
      if (s) out.push(s)
    }
  }
  add(path.join(FILES, 'claude/core/skills'), 'core', 'Yours, on every computer', true)
  add(path.join(FILES, 'claude/server/skills'), 'server', 'Yours, on the server', true)
  add(path.join(FILES, 'claude/laptop/skills'), 'laptop', 'Yours, on laptops', true)
  add(SKILLS, 'learned', 'Learned from your approvals', true)
  add(SHIPPED_SKILLS, 'shipped', 'Comes with fraimwork', false)
  const cache = path.join(HOME, '.claude/plugins/cache')
  for (const market of list(cache)) {
    for (const plugin of list(path.join(cache, market))) {
      const newest = list(path.join(cache, market, plugin)).at(-1)
      if (newest) add(path.join(cache, market, plugin, newest, 'skills'), `plugin-${market}-${plugin}`, `Plugin: ${plugin}`, false)
    }
  }
  return out
}

// Only the names of connections: their settings can hold keys, and those never reach a page.
function services() {
  const names = new Set()
  const files = ['claude/core/.mcp.json', 'claude/server/.mcp.json'].map((f) => path.join(FILES, f)).concat(path.join(HOME, '.claude.json'))
  for (const f of files) {
    try { for (const k of Object.keys(JSON.parse(read(f) || '{}').mcpServers || {})) names.add(k) } catch {}
  }
  return [...names].sort()
}

function allDocs() {
  const docs = []
  const guide = read(path.join(FILES, 'fraim-guide.md'))
  if (guide !== null) docs.push({ file: 'fraim-guide.md', title: 'Your guide' })
  for (const f of list(DOCS)) {
    if (!f.endsWith('.md')) continue
    docs.push({ file: f, title: (/^# +(.+)$/m.exec(read(path.join(DOCS, f)) || '') || [])[1] || f.slice(0, -3) })
  }
  return docs
}

const schedulePart = (when) => {
  if (/^schedule /.test(when)) return { mode: 'schedule', value: when.slice(9) }
  if (/^every /.test(when)) return { mode: 'every', value: when.slice(6).split(/\s/)[0] }
  return null
}

export function createSettings({ employees, team, tool, runtimeEnv, send, readBody }) {
  function run(cmd, args) {
    const r = spawnSync(tool(cmd), args, { encoding: 'utf8', timeout: 20000, env: runtimeEnv() })
    return { ok: r.status === 0, out: (r.stdout || '').trim(), err: (r.stderr || r.error?.message || '').trim() }
  }
  const must = (cmd, args) => {
    const r = run(cmd, args)
    if (!r.ok) throw new Refused(r.err.replace(new RegExp(`^${cmd}: `), '') || `${cmd} failed`)
    return r.out
  }

  const allRules = () => parseRules(read(path.join(BRAIN, 'rules.md')))

  function prompts(lead) {
    const out = run('fraim-prompt', ['list', ...(lead ? ['--lead', lead] : [])]).out
    return out.split('\n').flatMap((l) => {
      const m = /^(\S+)\s+(lead \S+|yours|default|empty)\s*(.*)$/.exec(l)
      return m ? [{ name: m[1], source: m[2], note: m[3].replace(/[()]/g, '').trim() }] : []
    })
  }

  function overview() {
    const { people, watchers } = employees()
    const skills = allSkills().map(({ file, ...s }) => s)
    const tools = (read(path.join(HOME, '.config/fraim/tools')) || '').split('\n').filter((l) => l.trim())
    return { people, watchers, rules: allRules(), prompts: prompts(''), skills, services: services(), commands: tools, docs: allDocs(),
      notes: Object.fromEntries(Object.entries(NOTE_FILES).map(([k, f]) => [k, { text: read(f) || '', version: version(read(f)) }])) }
  }

  function findEmployee(name) {
    const { people, watchers } = employees()
    const lead = people.find((p) => p.name === name)
    const person = lead || watchers.find((p) => p.name === name)
    if (!person) throw new Refused('There is no employee with that name.', 404)
    return { person, kind: lead ? 'lead' : 'auto' }
  }

  const jobFile = (name, kind) => (kind === 'lead' ? path.join(LEADS, name, 'lead.md') : path.join(AUTOS, name, 'automation.md'))
  const automationsOf = (name, kind) => {
    const t = team()
    return (kind === 'lead' ? t.leads.filter((x) => x.lead === name) : t.automations.filter((x) => x.name === name))
  }

  function toolEntries(name, kind) {
    if (kind === 'lead') return (read(path.join(LEADS, name, 'tools')) || '').split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('#'))
    return frontValue(splitFront(read(jobFile(name, kind))).front, 'tools').split(',').map((t) => t.trim()).filter(Boolean)
  }

  function employee(name) {
    const { person, kind } = findEmployee(name)
    const text = read(jobFile(name, kind)) || ''
    const { front, body } = splitFront(text)
    const sections = allRules()
    const ownSection = `Lead ${name}`
    return {
      ...person, kind, role: frontValue(front, 'role') || (kind === 'lead' ? 'lead' : 'automation'),
      job: body.trim(), version: version(text),
      own: sections.find((s) => s.name === ownSection)?.rules || [],
      shared: sections.filter((s) => !s.name.startsWith('Lead ')),
      tools: toolEntries(name, kind), services: services(),
      budget: kind === 'lead' ? (read(path.join(LEADS, name, 'budget')) || '3').trim() : null,
      prompts: kind === 'lead' ? prompts(name) : [],
      schedules: automationsOf(name, kind).map((a) => ({ name: a.name, when: a.when, change: schedulePart(a.when) })),
    }
  }

  function saveJob(name, body) {
    const { kind } = findEmployee(name)
    const file = jobFile(name, kind)
    const text = String(body.text ?? '').trim()
    if (!text) throw new Refused('The job cannot be empty.')
    const old = read(file) || ''
    replaceFile(file, `${splitFront(old).front}${text}\n`, body.version)
    return employee(name)
  }

  function saveTools(name, body) {
    const { kind } = findEmployee(name)
    const entries = [...new Set((Array.isArray(body.entries) ? body.entries : []).map((e) => String(e).trim()).filter(Boolean))]
    const bad = entries.find((e) => !TOOL_ENTRY.test(e))
    if (bad) throw new Refused(`"${bad.slice(0, 60)}" is not a tool name.`)
    if (kind === 'lead') {
      const file = path.join(LEADS, name, 'tools')
      const comments = (read(file) || '').split('\n').filter((l) => l.trim().startsWith('#'))
      replaceFile(file, `${[...comments, ...entries].join('\n')}\n`)
    } else {
      changeAutomation(name, (t) => setFront(t, 'tools', entries.join(',')))
    }
    return employee(name)
  }

  // A change a check does not accept is taken back, so a mistake here never stops a run.
  function changeAutomation(name, change) {
    const file = path.join(AUTOS, name, 'automation.md')
    const old = read(file)
    if (old === null) throw new Refused('That schedule does not exist.', 404)
    replaceFile(file, change(old))
    const check = run('fraim-auto', ['check', name])
    if (!check.ok) {
      writeFile(file, old)
      throw new Refused(`That does not work: ${(check.out || check.err).split('\n').slice(1).join(' ').replace(/^\s*-\s*/, '') || check.err}`)
    }
    must('fraim-auto', ['sync'])
  }

  function saveSchedule(name, body) {
    const { kind } = findEmployee(name)
    if (!automationsOf(name, kind).some((a) => a.name === body.automation)) throw new Refused('That schedule does not belong to this employee.', 404)
    const value = String(body.value || '').trim()
    if (body.mode === 'schedule' && !CRON.test(value)) throw new Refused('That is not a valid time.')
    if (body.mode === 'every' && !EVERY.test(value)) throw new Refused('Write a number and m, h or d, for example 15m.')
    if (body.mode !== 'schedule' && body.mode !== 'every') throw new Refused('Choose how often it runs.')
    changeAutomation(body.automation, (t) => {
      const cleared = setFront(t, body.mode === 'schedule' ? 'every' : 'schedule', null)
      return setFront(cleared, body.mode, body.mode === 'schedule' ? `"${value}"` : value)
    })
    return employee(name)
  }

  function saveBudget(name, body) {
    const { kind } = findEmployee(name)
    if (kind !== 'lead') throw new Refused('Only a lead has a budget.')
    if (!/^[0-9]{1,2}$/.test(String(body.budget))) throw new Refused('The budget is a number from 0 to 99.')
    replaceFile(path.join(LEADS, name, 'budget'), `${body.budget}\n`)
    return employee(name)
  }

  function setPower(name, body) {
    const { kind } = findEmployee(name)
    if (body.on) {
      for (const a of automationsOf(name, kind)) {
        if (/^(false|no|off|0)$/i.test(frontValue(splitFront(read(path.join(AUTOS, a.name, 'automation.md'))).front, 'enabled'))) must('fraim-auto', ['on', a.name])
      }
    }
    if (kind === 'lead') must('fraim-lead', [body.on ? 'resume' : 'pause', name])
    else must('fraim-auto', [body.on ? 'resume' : 'pause', name])
    return employee(name)
  }

  function changeRules(body) {
    const lead = body.lead ? ['--lead', String(body.lead)] : []
    const text = String(body.text || '').trim().replace(/^-+\s*/, '')
    const id = String(body.id || '')
    if (body.action !== 'undo' && body.action !== 'add' && !/^r\d+$/.test(id)) throw new Refused('Choose a rule first.')
    if ((body.action === 'add' || body.action === 'edit') && !text) throw new Refused('Write the rule first.')
    if (body.action === 'add') must('fraim-brain', ['note', ...lead, '--', text])
    else if (body.action === 'edit') { must('fraim-brain', ['note', ...lead, '--', text]); must('fraim-brain', ['forget', id]) }
    else if (body.action === 'remove') must('fraim-brain', ['forget', id])
    else if (body.action === 'undo') must('fraim-brain', ['undo'])
    else throw new Refused('Unknown change.')
    return { rules: allRules() }
  }

  const leadArgs = (lead) => (lead ? ['--lead', lead] : [])
  function checkLead(lead) {
    if (lead && !new RegExp(`^${NAME}$`).test(lead)) throw new Refused('That is not an employee.')
    return lead || ''
  }

  function prompt(name, lead) {
    const file = run('fraim-prompt', ['path', name, ...leadArgs(lead)])
    if (!file.ok) throw new Refused('There is no such instruction.', 404)
    const text = read(file.out) || ''
    const row = prompts(lead).find((p) => p.name === name)
    return { name, lead, text, version: version(text), source: row?.source || 'default', note: row?.note || '' }
  }

  function savePrompt(name, lead, body) {
    const text = String(body.text ?? '')
    if (!text.trim()) throw new Refused('The text cannot be empty. Use "Back to default" instead.')
    if (body.version !== prompt(name, lead).version) throw new Refused('Someone changed this in the meantime. Reload the page and make your change again.', 409)
    const before = prompt(name, lead).source
    const file = must('fraim-prompt', ['own', name, ...leadArgs(lead)])
    const old = read(file)
    replaceFile(file, text)
    const check = run('fraim-prompt', ['check', name, ...leadArgs(lead)])
    if (!check.ok) {
      const own = lead ? `lead ${lead}` : 'yours'
      if (before === own) writeFile(file, old)
      else run('fraim-prompt', ['reset', name, ...leadArgs(lead)])
      throw new Refused(`Not saved: ${check.err.split('\n')[0].replace(/^.*?\.md: /, '')}`)
    }
    return prompt(name, lead)
  }

  function skill(id) {
    const s = allSkills().find((x) => x.id === id)
    if (!s) throw new Refused('There is no such skill.', 404)
    return s
  }
  const skillPage = (s) => { const text = read(s.file) || ''; const { file, ...rest } = s; return { ...rest, text, version: version(text) } }

  function saveSkill(id, body) {
    const s = skill(id)
    if (!s.editable) throw new Refused('This skill comes with the software. Ask the chief to make your own version.', 403)
    const text = String(body.text ?? '')
    if (!/^name:/m.test(splitFront(text).front) || !/^description:/m.test(splitFront(text).front)) throw new Refused('Keep the name and description lines at the top: Claude needs them to find this skill.')
    replaceFile(s.file, text, body.version)
    return skillPage(skill(id))
  }

  function doc(file) {
    if (!allDocs().some((d) => d.file === file)) throw new Refused('There is no such page.', 404)
    return { file, text: read(file === 'fraim-guide.md' ? path.join(FILES, file) : path.join(DOCS, file)) || '' }
  }

  // True when this request was for the settings screen, answered or refused.
  async function handle(req, res, url) {
    if (url.pathname === '/settings' && req.method === 'GET') { send(res, 200, SETTINGS_PAGE, 'text/html; charset=utf-8'); return true }
    if (!url.pathname.startsWith('/api/settings')) return false
    const route = url.pathname.slice('/api/settings'.length)
    const lead = () => checkLead(url.searchParams.get('lead') || '')
    const ok = (body) => { send(res, 200, body); return true }
    try {
      if (req.method === 'GET') {
        if (route === '') return ok(overview())
        let m = new RegExp(`^/employee/(${NAME})$`).exec(route)
        if (m) return ok(employee(m[1]))
        m = /^\/prompt\/([a-z0-9][a-z0-9-]*)$/.exec(route)
        if (m) return ok(prompt(m[1], lead()))
        m = /^\/skill\/([^/]+)$/.exec(route)
        if (m) return ok(skillPage(skill(decodeURIComponent(m[1]))))
        m = /^\/doc\/([a-zA-Z0-9_-]+\.md)$/.exec(route)
        if (m) return ok(doc(m[1]))
      } else if (req.method === 'POST') {
        // A custom header: a form on another site cannot send it, so no cross-site changes.
        if (req.headers['x-fraim-queue'] !== '1') { send(res, 403, { error: 'missing header' }); return true }
        const body = await readBody(req)
        let m = new RegExp(`^/employee/(${NAME})/(job|tools|schedule|budget|power)$`).exec(route)
        if (m) return ok({ job: saveJob, tools: saveTools, schedule: saveSchedule, budget: saveBudget, power: setPower }[m[2]](m[1], body))
        if (route === '/rules') return ok(changeRules(body))
        m = /^\/prompt\/([a-z0-9][a-z0-9-]*)(\/reset)?$/.exec(route)
        if (m && m[2]) { must('fraim-prompt', ['reset', m[1], ...leadArgs(lead())]); return ok(prompt(m[1], lead())) }
        if (m) return ok(savePrompt(m[1], lead(), body))
        m = /^\/skill\/([^/]+)$/.exec(route)
        if (m) return ok(saveSkill(decodeURIComponent(m[1]), body))
        m = /^\/note\/(inbox|voice)$/.exec(route)
        if (m) { replaceFile(NOTE_FILES[m[1]], String(body.text ?? ''), body.version); return ok({ version: version(read(NOTE_FILES[m[1]])) }) }
      }
      send(res, 404, { error: 'not found' })
    } catch (err) {
      send(res, err.status || 500, { error: err.message })
    }
    return true
  }

  return { handle }
}

export const SETTINGS_PAGE = String.raw`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>fraim settings</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
<style>
:root { color-scheme:dark; --bg:#101113; --side:#0c0d0e; --panel:#141517; --hover:#1b1c1f; --active:#222327; --ink:#e6e7e9; --soft:#c2c4c9; --muted:#868a93; --faint:#565a62; --line:#1f2023; --line2:#2b2d31; --accent:#6f7bf0; --accent-bg:#1a1d36; --green:#4cc38a; --red:#f2555a; --yellow:#e2b33c; --font:"Inter",ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif; --mono:ui-monospace,Menlo,monospace; }
* { box-sizing:border-box; }
html, body { height:100%; }
body { margin:0; background:var(--bg); color:var(--ink); font:13px/1.55 var(--font); -webkit-font-smoothing:antialiased; }
button, input, select, textarea { font:inherit; color:inherit; }
a { color:var(--accent); text-decoration:none; }
:focus-visible { outline:2px solid var(--accent); outline-offset:1px; border-radius:4px; }
.app { display:grid; grid-template-columns:228px minmax(0,1fr); height:100vh; }
.side { background:var(--side); border-right:1px solid var(--line); padding:10px 8px; overflow-y:auto; }
.ws { display:flex; align-items:center; gap:8px; padding:4px 8px 12px; font-weight:600; font-size:13.5px; }
.logo { width:20px; height:20px; border-radius:5px; background:var(--accent); display:grid; place-items:center; color:#fff; font-size:11px; }
.nav a { display:flex; align-items:center; padding:5px 8px; border-radius:6px; color:var(--soft); font-weight:500; margin-bottom:1px; }
.nav a:hover { background:var(--hover); } .nav a.on { background:var(--active); color:var(--ink); }
.nav a span { margin-left:auto; color:var(--muted); font-size:12px; font-weight:400; }
.sec { padding:16px 8px 4px; color:var(--muted); font-size:12px; font-weight:500; }
.main { display:flex; flex-direction:column; min-width:0; min-height:0; }
.bar { height:44px; flex:none; display:flex; align-items:center; padding:0 16px; border-bottom:1px solid var(--line); color:var(--muted); gap:6px; }
.bar a { color:var(--muted); } .bar a:hover { color:var(--ink); } .bar b { color:var(--ink); font-weight:600; }
.doc { flex:1; overflow-y:auto; min-height:0; }
.in { max-width:860px; margin:0 auto; padding:24px 32px 40px; }
h2 { font-size:20px; font-weight:600; margin:0 0 4px; }
.about { color:var(--muted); margin:0 0 18px; }
.h3 { display:flex; align-items:center; gap:10px; margin:26px 0 8px; font-weight:600; font-size:13.5px; }
.h3 .act { margin-left:auto; }
.hint { color:var(--muted); font-size:12.5px; margin:0 0 8px; }
.boxed { border:1px solid var(--line); border-radius:8px; overflow:hidden; background:var(--panel); }
.row { display:flex; align-items:center; gap:12px; width:100%; min-height:40px; padding:7px 12px; border-bottom:1px solid var(--line); color:inherit; }
.row:last-child { border-bottom:0; }
a.row:hover { background:var(--hover); }
.grow { flex:1; min-width:0; }
.grow small, .sub { display:block; color:var(--muted); font-size:12.5px; }
.clip { display:block; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.tag { flex:none; font-size:11.5px; color:var(--muted); border:1px solid var(--line2); border-radius:999px; padding:1px 8px; white-space:nowrap; }
.tag.mine { color:var(--accent); border-color:var(--accent); }
.tag.off { color:var(--yellow); border-color:var(--yellow); }
.tag.bad { color:var(--red); border-color:var(--red); }
.btn { border:1px solid var(--line2); background:var(--panel); border-radius:6px; padding:3px 10px; cursor:pointer; font-size:12.5px; font-weight:500; color:var(--soft); }
.btn:hover { background:var(--hover); color:var(--ink); }
.btn.go { background:var(--accent); border-color:var(--accent); color:#fff; }
.btn.warn { color:var(--red); border-color:var(--red); }
.btn:disabled { opacity:.45; cursor:default; }
.link { background:none; border:0; padding:0; color:var(--muted); cursor:pointer; font-size:12.5px; }
.link:hover { color:var(--ink); }
.props { display:grid; grid-template-columns:120px 1fr; gap:4px 12px; margin:0 0 6px; }
.props dt { color:var(--muted); } .props dd { margin:0; }
textarea.ed { display:block; width:100%; min-height:300px; background:var(--panel); border:1px solid var(--line2); border-radius:8px; padding:12px; font:12.5px/1.6 var(--mono); resize:vertical; outline:none; }
textarea.ed.short { min-height:120px; }
textarea.ed:focus, input.f:focus, select.f:focus { border-color:var(--accent); }
input.f, select.f { background:var(--panel); border:1px solid var(--line2); border-radius:6px; padding:4px 8px; outline:none; }
.acts { display:flex; align-items:center; gap:8px; margin-top:8px; flex-wrap:wrap; }
.addrow { display:flex; gap:8px; padding:8px 12px; border-top:1px solid var(--line); }
.addrow input { flex:1; min-width:0; }
.chips { display:flex; flex-wrap:wrap; gap:6px; }
.chip { display:inline-flex; gap:6px; align-items:center; border:1px solid var(--line2); border-radius:999px; padding:2px 10px; background:none; cursor:pointer; font-size:12.5px; color:var(--muted); }
.chip.on { border-color:var(--accent); background:var(--accent-bg); color:var(--ink); }
.warnbox { border:1px solid var(--line2); border-left:2px solid var(--yellow); border-radius:6px; padding:8px 12px; color:var(--soft); margin:0 0 10px; }
.md { color:var(--soft); overflow-wrap:anywhere; }
.md h1 { font-size:18px; margin:18px 0 6px; color:var(--ink); } .md h2 { font-size:15px; margin:18px 0 6px; color:var(--ink); } .md h3, .md h4 { font-size:13.5px; margin:14px 0 4px; color:var(--ink); }
.md p { margin:0 0 10px; } .md ul, .md ol { margin:0 0 10px; padding-left:20px; }
.md b { color:var(--ink); font-weight:600; }
.md code { font:12px var(--mono); background:var(--active); border-radius:4px; padding:1px 4px; }
.md pre { background:var(--panel); border:1px solid var(--line); border-radius:6px; padding:10px 12px; overflow-x:auto; font:12px/1.5 var(--mono); }
.md table { border-collapse:collapse; margin:0 0 12px; display:block; overflow-x:auto; }
.md td, .md th { border:1px solid var(--line2); padding:4px 8px; text-align:left; vertical-align:top; }
.md > :first-child { margin-top:0; }
details > summary { cursor:pointer; color:var(--muted); padding:8px 0; }
.tell { flex:none; border-top:1px solid var(--line); background:var(--bg); padding:10px 16px; }
.tell .wrap { max-width:796px; margin:0 auto; }
.tell textarea { display:block; width:100%; background:var(--panel); border:1px solid var(--line2); border-radius:8px; padding:9px 12px; resize:none; outline:none; }
.tell textarea:focus { border-color:var(--accent); }
.said { color:var(--soft); margin-bottom:8px; white-space:pre-wrap; max-height:150px; overflow-y:auto; }
.said b { color:var(--ink); font-weight:600; }
.none { color:var(--muted); padding:12px; }
.toast { position:fixed; right:16px; top:12px; background:var(--active); border:1px solid var(--line2); padding:8px 12px; border-radius:8px; display:none; z-index:5; max-width:420px; }
@media (max-width:760px) { .app { display:block; height:auto; } .side { border-right:0; border-bottom:1px solid var(--line); } .nav { display:flex; flex-wrap:wrap; gap:2px; } .nav a span { display:none; } .sec { display:none; } .main { height:auto; } .doc { overflow:visible; } .in { padding:16px; } .tell { position:sticky; bottom:0; } }
</style>
</head>
<body>
<div class="app">
  <nav class="side"><div class="ws"><span class="logo">f</span>Settings</div><div class="nav" id="nav"></div></nav>
  <div class="main">
    <div class="bar" id="bar"></div>
    <div class="doc"><div class="in" id="page"></div></div>
    <div class="tell"><div class="wrap"><div class="said" id="said" style="display:none"></div><textarea id="tell" rows="1"></textarea></div></div>
  </div>
</div>
<div class="toast" id="toast"></div>
<script>
function $(s) { return document.querySelector(s) }
function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] }) }
function toast(t) { var e = $('#toast'); e.textContent = t; e.style.display = 'block'; clearTimeout(toast.t); toast.t = setTimeout(function () { e.style.display = 'none' }, 4000) }
async function get(u) { var r = await fetch(u); var d = await r.json().catch(function () { return {} }); if (!r.ok) throw new Error(d.error || 'That did not load.'); return d }
async function post(u, b) {
  var r = await fetch(u, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Fraim-Queue': '1' }, body: JSON.stringify(b || {}) })
  var d = await r.json().catch(function () { return {} })
  if (!r.ok) { toast(d.error || 'That did not work.'); return null }
  return d
}

var PROMPTS = {
  'chief-run': ['Chief of staff: daily work', 'How the chief routes work, writes the morning briefing and when it stays quiet.'],
  'chief-chat': ['Chief of staff: chatting with you', 'How the chief answers you in this app and which changes it makes for you.'],
  'relay': ['Chief of staff: WhatsApp messages', 'How the chief writes every WhatsApp message to you.'],
  'lead-run': ['Employee: what to do each run', 'The steps every lead follows when it starts.'],
  'lead-header': ['Employee: introduction', 'What a lead is told about itself at the start of a run.'],
  'engineer-run': ['Engineer: how to build', 'How the engineer builds, tests and asks to switch things on.'],
  'goal': ['Background tasks', 'What a background task is told and what its result looks like.'],
  'automation': ['Automations', 'The text around your own automation instructions.'],
  'brain-review': ['Learning from your chats', 'How your preferences are found in what you say.'],
  'brain-distill': ['Weekly rule proposals', 'How new rules are proposed from your decisions.'],
  'style-adhd': ['Writing style: short', 'What short messages look like.'],
  'style-detailed': ['Writing style: detailed', 'What detailed messages look like.'],
  'plain-words': ['Plain words', 'How agents avoid technical language with you.'],
  'talk-rules': ['Talking to each other', 'How employees message each other.'],
  'brief-lead': ['New employee: first job text', 'The job description a new lead starts with.'],
  'brief-chief': ['New chief: first job text', 'The job description a new chief starts with.'],
  'brief-engineer': ['New engineer: first job text', 'The job description a new engineer starts with.'],
  'server': ['Every Claude on the server', 'What every session is told. A change takes effect when the WhatsApp chat starts fresh.'],
  'thread-new': ['Inbox: something new came in', 'What the chief is told when a new conversation arrives.'],
  'thread-owner': ['Inbox: you wrote in a conversation', 'What the chief is told when you reply in the inbox.'],
  'thread-closed': ['Inbox: a conversation closed', 'What the chief is told when a conversation closes.']
}
function promptTitle(n) { return (PROMPTS[n] || [n.replace(/-/g, ' ').replace(/^./, function (c) { return c.toUpperCase() })])[0] }
function promptAbout(n) { return (PROMPTS[n] || ['', ''])[1] }
var ROLE_PROMPTS = { chief: ['chief-run', 'chief-chat', 'relay'], engineer: ['engineer-run', 'lead-header'], lead: ['lead-run', 'lead-header'] }
function sourceTag(p) {
  if (p.source === 'default') return '<span class="tag">Default</span>'
  return '<span class="tag mine">' + (p.source === 'yours' ? 'Your version' : 'Only this employee') + '</span>'
}

function words(w) {
  var m = /^schedule (\S+) (\S+) (\S+) (\S+) (\S+)$/.exec(w || '')
  if (m) {
    var at = /^\d+$/.test(m[1]) && /^\d+$/.test(m[2]) ? ('0' + m[2]).slice(-2) + ':' + ('0' + m[1]).slice(-2) : ''
    if (at && m[3] === '*' && m[4] === '*' && m[5] === '*') return 'Every day at ' + at
    if (at && m[3] === '*' && m[4] === '*' && m[5] === '1-5') return 'Every weekday at ' + at
    var n = /^\*\/(\d+)$/.exec(m[1]); if (n && m[2] === '*') return 'Every ' + n[1] + ' minutes'
    return 'On a schedule (' + w.slice(9) + ')'
  }
  var e = /^every (\d+)\s*([mhd])/.exec(w || '')
  if (e) return 'Every ' + e[1] + ' ' + { m: 'minutes', h: 'hours', d: 'days' }[e[2]]
  if (w === 'by hand') return 'Only when someone starts it'
  if (/^queue:/.test(w || '')) return 'When something new lands in the queue'
  return w || ''
}

function inline(s) {
  return esc(s).replace(/\x60([^\x60]+)\x60/g, '<code>$1</code>').replace(/\*\*(.+?)\*\*/g, '<b>$1</b>')
    .replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>')
    .replace(/\[([^\]]+)\]\(([a-zA-Z0-9_-]+\.md)[^)]*\)/g, '<a href="#doc/$2">$1</a>')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
}
function md(text) {
  var lines = String(text || '').replace(/^---\n[\s\S]*?\n---\n?/, '').split('\n'), out = '', i = 0
  while (i < lines.length) {
    var l = lines[i], m
    if (/^\x60\x60\x60/.test(l)) { var code = []; i++; while (i < lines.length && !/^\x60\x60\x60/.test(lines[i])) code.push(lines[i++]); i++; out += '<pre>' + esc(code.join('\n')) + '</pre>'; continue }
    if ((m = /^(#{1,4})\s+(.*)$/.exec(l))) { out += '<h' + m[1].length + '>' + inline(m[2]) + '</h' + m[1].length + '>'; i++; continue }
    if (/^\|.*\|\s*$/.test(l)) {
      var rows = []; while (i < lines.length && /^\|.*\|\s*$/.test(lines[i])) rows.push(lines[i++])
      out += '<table>' + rows.filter(function (r) { return !/^\|[\s:|-]+\|\s*$/.test(r) }).map(function (r, n) {
        var tag = n ? 'td' : 'th'
        return '<tr>' + r.trim().slice(1, -1).split('|').map(function (c) { return '<' + tag + '>' + inline(c.trim()) + '</' + tag + '>' }).join('') + '</tr>'
      }).join('') + '</table>'
      continue
    }
    if (/^\s*([-*]|\d+\.)\s+/.test(l)) {
      var ordered = /^\s*\d+\./.test(l), items = ''
      while (i < lines.length && /^\s*([-*]|\d+\.)\s+/.test(lines[i])) items += '<li>' + inline(lines[i++].replace(/^\s*([-*]|\d+\.)\s+/, '')) + '</li>'
      out += (ordered ? '<ol>' : '<ul>') + items + (ordered ? '</ol>' : '</ul>')
      continue
    }
    if (!l.trim()) { i++; continue }
    var para = []; while (i < lines.length && lines[i].trim() && !/^(#{1,4}\s|\x60\x60\x60|\||\s*[-*]\s|\s*\d+\.\s)/.test(lines[i])) para.push(lines[i++])
    if (!para.length) para.push(lines[i++])
    out += '<p>' + inline(para.join(' ')) + '</p>'
  }
  return out
}

var data = null, cur = null, leaveOk = false, here = ''
function dirty() { return [].some.call(document.querySelectorAll('#page textarea.ed'), function (t) { return t.value !== t.defaultValue }) }
function count(rs) { return rs.reduce(function (n, s) { return n + s.rules.length }, 0) }

function nav(r) {
  var on = r.split('/')[0]
  function a(h, label, n, match) { return '<a href="#' + h + '" class="' + ((match || []).concat(h).indexOf(on) >= 0 ? 'on' : '') + '">' + label + '<span>' + (n == null ? '' : n) + '</span></a>' }
  var d = data || { people: [], watchers: [], rules: [], prompts: [], skills: [], services: [], docs: [] }
  $('#nav').innerHTML = '<a href="/">Back to inbox</a><div class="sec">Your setup</div>' +
    a('employees', 'Employees', d.people.length + d.watchers.length, ['employee']) + a('rules', 'Rules', count(d.rules)) +
    a('instructions', 'Instructions', d.prompts.filter(function (p) { return p.source !== 'default' }).length || '', ['instruction']) +
    a('skills', 'Skills', d.skills.length, ['skill']) + a('tools', 'Tools', d.services.length) + a('docs', 'Documentation', d.docs.length, ['doc'])
}
function bar(parts) { $('#bar').innerHTML = parts.map(function (p, i) { return i === parts.length - 1 ? '<b>' + esc(p[0]) + '</b>' : '<a href="#' + p[1] + '">' + esc(p[0]) + '</a><span>/</span>' }).join('') }
function setTell(what, ph) { cur = what; $('#tell').placeholder = ph || 'Tell the chief of staff what to change' }

var VIEW = {
  employees: function () {
    bar([['Employees']]); setTell('the employees', 'Tell the chief of staff who to hire or what to change')
    function row(p) {
      var state = p.off ? '<span class="tag off">Switched off</span>' : p.status === 'failed' ? '<span class="tag bad">Last run failed</span>' : '<span class="tag">On</span>'
      return '<a class="row" href="#employee/' + esc(p.name) + '"><span class="grow"><b>' + esc(p.title) + '</b><small class="clip">' + esc(p.does) + '</small></span><span class="sub">' + esc(p.starts.map(words)[0] || '') + '</span>' + state + '</a>'
    }
    return '<h2>Employees</h2><p class="about">Click someone to see their job, rules, tools and schedule.</p><div class="boxed">' + data.people.map(row).join('') + '</div>' +
      (data.watchers.length ? '<div class="h3">Automations</div><div class="boxed">' + data.watchers.map(row).join('') + '</div>' : '')
  },
  employee: async function (name) {
    var e = await get('/api/settings/employee/' + name); pageData = e
    bar([['Employees', 'employees'], [e.title]]); setTell('employee ' + e.title, 'Tell the chief of staff what to change about ' + e.title)
    return employeeHtml(e)
  },
  rules: function () {
    bar([['Rules']]); setTell('the rules', 'Tell the chief of staff which rule to add or change')
    var own = data.rules.filter(function (s) { return !/^Lead /.test(s.name) }), per = data.rules.filter(function (s) { return /^Lead /.test(s.name) })
    pageData = data.notes
    return '<h2>Rules</h2><p class="about">What your employees learned from you. Every new run follows them.</p><div class="acts" style="margin:0 0 6px"><button class="btn" data-act="undo">Undo last change</button></div>' +
      (own.length ? own.map(function (s) { return '<div class="h3">' + esc(s.name) + '</div>' + ruleBox(s.rules, '') }).join('') : '<div class="h3">General</div>' + ruleBox([], '')) +
      per.map(function (s) { var n = s.name.slice(5); return '<div class="h3">Only for ' + esc(n) + '</div>' + ruleBox(s.rules, n) }).join('') +
      '<div class="h3">How the chief talks to you</div><p class="hint">One rule per line, starting with a dash.</p>' + noteEd('voice') +
      '<div class="h3">What stays out of the inbox</div><p class="hint">Senders and examples the mail check skips.</p>' + noteEd('inbox')
  },
  instructions: function () {
    bar([['Instructions']]); setTell('the instructions', 'Tell the chief of staff how an employee should behave')
    return '<h2>Instructions</h2><p class="about">The exact text your employees get. Change one and the next run follows it.</p><div class="boxed">' + data.prompts.map(function (p) { return promptRow(p, '') }).join('') + '</div>'
  },
  instruction: async function (name, lead) {
    var p = await get('/api/settings/prompt/' + name + (lead ? '?lead=' + lead : '')); pageData = p
    bar([['Instructions', 'instructions'], [promptTitle(name) + (lead ? ' (' + lead + ')' : '')]]); setTell('the instruction "' + promptTitle(name) + '"' + (lead ? ' for ' + lead : ''))
    return '<h2>' + esc(promptTitle(name)) + '</h2><p class="about">' + esc(promptAbout(name)) + (lead ? ' This version is only for ' + esc(lead) + '.' : '') + '</p>' +
      '<div class="acts" style="margin:0 0 10px">' + sourceTag(p) + (p.note ? '<span class="sub">' + esc(p.note) + '</span>' : '') + '</div>' +
      '<p class="hint">Words in double braces are filled in automatically. Keep them.</p>' +
      '<textarea class="ed" id="ptext">' + esc(p.text) + '</textarea><div class="acts"><button class="btn go" data-act="savePrompt">Save</button>' +
      (p.source === 'default' ? '' : '<button class="btn" data-act="resetPrompt">Back to default</button>') + '</div>'
  },
  skills: function () {
    bar([['Skills']]); setTell('the skills', 'Tell the chief of staff what skill you want added or changed')
    var groups = {}; data.skills.forEach(function (s) { (groups[s.group] = groups[s.group] || []).push(s) })
    var names = Object.keys(groups)
    return '<h2>Skills</h2><p class="about">Step-by-step know-how. An employee opens a skill when a task fits it.</p>' + (names.length ? names.map(function (g, i) {
      var body = '<div class="boxed">' + groups[g].map(function (s) { return '<a class="row" href="#skill/' + encodeURIComponent(s.id) + '"><span class="grow"><b>' + esc(s.name) + '</b><small class="clip">' + esc(s.about) + '</small></span></a>' }).join('') + '</div>'
      return /^Plugin/.test(g) ? '<details><summary>' + esc(g) + ' (' + groups[g].length + ')</summary>' + body + '</details>' : '<div class="h3">' + esc(g) + '</div>' + body
    }).join('') : '<div class="none">No skills yet.</div>')
  },
  skill: async function (id) {
    var s = await get('/api/settings/skill/' + encodeURIComponent(id)); pageData = s
    bar([['Skills', 'skills'], [s.name]]); setTell('the skill ' + s.name, 'Tell the chief of staff what to change about this skill')
    return '<h2>' + esc(s.name) + '</h2><p class="about">' + esc(s.about) + '</p><div class="acts" style="margin:0 0 10px"><span class="tag">' + esc(s.group) + '</span></div>' +
      (s.editable ? '<textarea class="ed" id="stext">' + esc(s.text) + '</textarea><div class="acts"><button class="btn go" data-act="saveSkill">Save</button></div>' : '<p class="hint">This skill comes with the software, so you cannot edit it here. Ask the chief for your own version.</p><div class="md">' + md(s.text) + '</div>')
  },
  tools: function () {
    bar([['Tools']]); setTell('the tools', 'Tell the chief of staff which tool to connect or who may use it')
    var all = data.people.concat(data.watchers)
    function users(svc) { var n = pretty(svc); return all.filter(function (p) { return p.tools.indexOf(n) >= 0 }).map(function (p) { return p.title }) }
    return '<h2>Tools</h2><p class="about">Everything connected to this server.</p>' + NOT_LOCKED +
      '<div class="h3">Connected services</div><div class="boxed">' + (data.services.length ? data.services.map(function (s) { var u = users(s); return '<div class="row"><span class="grow"><b>' + esc(pretty(s)) + '</b><small class="clip">' + (u.length ? esc('Listed for ' + u.join(', ')) : 'Not listed for anyone') + '</small></span></div>' }).join('') : '<div class="none">Nothing connected.</div>') + '</div>' +
      (data.commands.length ? '<div class="h3">Extra programs</div><div class="boxed">' + data.commands.map(function (c) { return '<div class="row">' + esc(c.replace(/^(npm|uv):/, '')) + '</div>' }).join('') + '</div>' : '')
  },
  docs: function () {
    bar([['Documentation']]); setTell('the documentation', 'Ask the chief of staff anything about your setup')
    return '<h2>Documentation</h2><p class="about">How the whole setup works.</p><div class="boxed">' + (data.docs.map(function (d) { return '<a class="row" href="#doc/' + esc(d.file) + '"><span class="grow">' + esc(d.title) + '</span></a>' }).join('') || '<div class="none">No documentation on this server yet.</div>') + '</div>'
  },
  doc: async function (file) {
    var d = await get('/api/settings/doc/' + file)
    var title = (data.docs.filter(function (x) { return x.file === file })[0] || {}).title || file
    bar([['Documentation', 'docs'], [title]]); setTell('the documentation page ' + title, 'Ask the chief of staff about this page')
    return '<div class="md">' + md(d.text) + '</div>'
  }
}
var pageData = null
var NOT_LOCKED = '<div class="warnbox">Tool lists are not locked yet: every employee can use everything connected to this server. A list says what an employee is meant to use.</div>'
function pretty(s) { return s.replace(/[-_]mcp$/, '').replace(/^./, function (c) { return c.toUpperCase() }) }
function promptRow(p, lead) {
  return '<a class="row" href="#instruction/' + esc(p.name) + (lead ? '/' + esc(lead) : '') + '"><span class="grow"><b>' + esc(promptTitle(p.name)) + '</b><small class="clip">' + esc(promptAbout(p.name)) + '</small></span>' + sourceTag(p) + '</a>'
}
function ruleBox(rules, lead) {
  return '<div class="boxed">' + rules.map(function (r) {
    return '<div class="row" data-rule="' + esc(r.id) + '" data-lead="' + esc(lead) + '"><span class="grow">' + esc(r.text) + '</span><button class="link" data-act="editRule">Edit</button><button class="link" data-act="removeRule">Remove</button></div>'
  }).join('') + '<div class="addrow"><input class="f" placeholder="Add a rule in your own words" data-add="' + esc(lead) + '"><button class="btn" data-act="addRule">Add</button></div></div>'
}
function noteEd(k) { return '<textarea class="ed short" data-note="' + k + '">' + esc(data.notes[k].text) + '</textarea><div class="acts"><button class="btn" data-act="saveNote" data-k="' + k + '">Save</button></div>' }

function employeeHtml(e) {
  var h = '<h2>' + esc(e.title) + '</h2><p class="about">' + esc(e.does) + '</p><div class="acts" style="margin:-8px 0 8px">' +
    (e.off ? '<span class="tag off">Switched off</span><button class="btn" data-act="power" data-on="1">Switch on</button>' : '<span class="tag">On</span><button class="btn" data-act="power" data-on="">Switch off</button>') + '</div>'
  h += '<div class="h3">Job<button class="btn act" data-act="editJob" id="jobbtn">Edit</button></div><div id="job"><div class="md">' + md(e.job) + '</div></div>'
  h += '<div class="h3">Rules only for ' + esc(e.title) + '</div>' + ruleBox(e.own, e.name)
  var n = count(e.shared)
  if (n) h += '<details><summary>' + n + ' rules every employee follows</summary><div class="boxed">' + e.shared.map(function (s) { return s.rules.map(function (r) { return '<div class="row"><span class="grow">' + esc(r.text) + '</span></div>' }).join('') }).join('') + '</div><p class="hint" style="margin-top:6px"><a href="#rules">Change these under Rules</a></p></details>'
  if (e.kind === 'lead') {
    var main = ROLE_PROMPTS[e.role] || ROLE_PROMPTS.lead
    var rows = e.prompts.filter(function (p) { return main.indexOf(p.name) >= 0 || p.source === 'lead ' + e.name })
    h += '<div class="h3">Instructions</div><p class="hint">Changing one here changes it for ' + esc(e.title) + ' only.</p><div class="boxed">' + rows.map(function (p) { return promptRow(p, e.name) }).join('') + '</div>'
  }
  h += '<div class="h3">Tools</div>' + NOT_LOCKED + toolsHtml(e)
  h += '<div class="h3">Schedule</div><div class="boxed">' + e.schedules.map(function (s, i) {
    return '<div class="row" data-sched="' + i + '"><span class="grow">' + esc(words(s.when)) + '</span>' + (s.change ? '<button class="link" data-act="editSched">Change</button>' : '') + '</div>'
  }).join('') + '</div>'
  if (e.kind === 'lead') h += '<div class="h3">Budget</div><p class="hint">How many background tasks ' + esc(e.title) + ' may start per day.</p><div class="acts" style="margin:0"><input class="f" id="budget" type="number" min="0" max="99" style="width:80px" value="' + esc(e.budget) + '"><button class="btn" data-act="saveBudget">Save</button></div>'
  return h
}
function toolsHtml(e) {
  function on(s) { return e.tools.some(function (t) { return t === 'mcp__' + s || t.indexOf('mcp__' + s + '__') === 0 }) }
  var other = e.tools.filter(function (t) { return !e.services.some(function (s) { return t === 'mcp__' + s || t.indexOf('mcp__' + s + '__') === 0 }) })
  return '<div class="chips">' + e.services.map(function (s) { return '<button class="chip' + (on(s) ? ' on' : '') + '" data-act="toggleTool" data-s="' + esc(s) + '">' + esc(pretty(s)) + '</button>' }).join('') + '</div>' +
    (other.length ? '<p class="hint" style="margin:12px 0 6px">Other permissions</p><div class="chips">' + other.map(function (t) { return '<button class="chip on" data-act="dropTool" data-t="' + esc(t) + '" title="Click to remove">' + esc(t) + ' &times;</button>' }).join('') + '</div>' : '')
}

async function show(force) {
  var h = location.hash.slice(1) || 'employees'
  if (!force && dirty() && !leaveOk && h !== here) { leaveOk = true; toast('You have unsaved text. Save it, or click again to leave without saving.'); history.replaceState(null, '', '#' + here); return }
  leaveOk = false
  var keep = force ? $('.doc').scrollTop : 0
  try {
    if (!data || force) data = await get('/api/settings')
    var parts = h.split('/').map(decodeURIComponent), fn = VIEW[parts[0]] || VIEW.employees
    var html = await fn(parts[1], parts[2])
    $('#page').innerHTML = html; here = h; nav(parts[0]); $('.doc').scrollTop = keep
  } catch (err) { $('#page').innerHTML = '<div class="none">' + esc(err.message) + '</div>' }
}
window.addEventListener('hashchange', function () { show() })

function route() { return here.split('/').map(decodeURIComponent) }
var empUrl = function (what) { return '/api/settings/employee/' + route()[1] + '/' + what }
async function apply(p, done) { var r = await p; if (r) { toast(done); await show(true) } return r }
function ruleOf(b) { return b.closest('[data-rule]') }
var A = {
  editJob: function () { $('#jobbtn').style.display = 'none'; $('#job').innerHTML = '<textarea class="ed" id="jobtext">' + esc(pageData.job) + '</textarea><div class="acts"><button class="btn go" data-act="saveJob">Save</button><button class="btn" data-act="cancel">Cancel</button></div>'; $('#jobtext').focus() },
  cancel: function () { [].forEach.call(document.querySelectorAll('#page textarea.ed'), function (t) { t.value = t.defaultValue }); show(true) },
  saveJob: function () { apply(post(empUrl('job'), { text: $('#jobtext').value, version: pageData.version }), 'Saved. The next run follows it.') },
  power: function (b) { apply(post(empUrl('power'), { on: !!b.dataset.on }), b.dataset.on ? 'Switched on.' : 'Switched off.') },
  saveBudget: function () { apply(post(empUrl('budget'), { budget: $('#budget').value }), 'Saved.') },
  toggleTool: function (b) {
    var s = b.dataset.s, was = pageData.tools.filter(function (t) { return !(t === 'mcp__' + s || t.indexOf('mcp__' + s + '__') === 0) })
    apply(post(empUrl('tools'), { entries: b.classList.contains('on') ? was : was.concat('mcp__' + s) }), 'Saved.')
  },
  dropTool: function (b) { apply(post(empUrl('tools'), { entries: pageData.tools.filter(function (t) { return t !== b.dataset.t }) }), 'Removed.') },
  addRule: function (b) { var i = b.parentNode.querySelector('input'); if (i.value.trim()) rule({ action: 'add', text: i.value, lead: i.dataset.add }, 'Rule added. Every new run follows it.') },
  removeRule: function (b) { rule({ action: 'remove', id: ruleOf(b).dataset.rule }, 'Rule removed.') },
  editRule: function (b) {
    var row = ruleOf(b), t = row.querySelector('.grow').textContent
    row.innerHTML = '<input class="f grow" value="' + esc(t) + '"><button class="btn go" data-act="saveRule">Save</button><button class="link" data-act="cancel">Cancel</button>'
    row.querySelector('input').focus()
  },
  saveRule: function (b) { var row = ruleOf(b); rule({ action: 'edit', id: row.dataset.rule, lead: row.dataset.lead, text: row.querySelector('input').value }, 'Rule changed.') },
  undo: function () { rule({ action: 'undo' }, 'Last change undone.') },
  saveNote: function (b) { var k = b.dataset.k, t = document.querySelector('[data-note="' + k + '"]'); apply(post('/api/settings/note/' + k, { text: t.value, version: data.notes[k].version }), 'Saved.') },
  savePrompt: function () { var r = route(); apply(post('/api/settings/prompt/' + r[1] + (r[2] ? '?lead=' + r[2] : ''), { text: $('#ptext').value, version: pageData.version }), 'Saved. The next run follows it.') },
  resetPrompt: function (b) {
    if (!b.dataset.sure) { b.dataset.sure = '1'; b.textContent = 'Sure? Your text moves to the archive'; b.classList.add('warn'); return }
    var r = route(); apply(post('/api/settings/prompt/' + r[1] + '/reset' + (r[2] ? '?lead=' + r[2] : '')), 'Back to the default.')
  },
  saveSkill: function () { apply(post('/api/settings/skill/' + encodeURIComponent(route()[1]), { text: $('#stext').value, version: pageData.version }), 'Saved.') },
  editSched: function (b) {
    var row = b.closest('[data-sched]'), s = pageData.schedules[+row.dataset.sched], cur = s.change, m = cur.mode === 'schedule' ? /^(\d+) (\d+) \* \* (\*|1-5)$/.exec(cur.value) : null, e = cur.mode === 'every' ? /^(\d+)([mh])$/.exec(cur.value) : null
    var mode = m ? (m[3] === '*' ? 'day' : 'week') : e ? (e[2] === 'm' ? 'min' : 'hour') : 'custom'
    var val = m ? ('0' + m[2]).slice(-2) + ':' + ('0' + m[1]).slice(-2) : e ? e[1] : cur.value
    row.innerHTML = '<select class="f" data-m>' + [['day', 'Every day at'], ['week', 'Every weekday at'], ['min', 'Every ... minutes'], ['hour', 'Every ... hours'], ['custom', 'Custom timing']].map(function (o) { return '<option value="' + o[0] + '"' + (o[0] === mode ? ' selected' : '') + '>' + o[1] + '</option>' }).join('') + '</select><input class="f" data-v value="' + esc(val) + '" style="width:130px"><span class="grow"></span><button class="btn go" data-act="saveSched" data-n="' + esc(s.name) + '">Save</button><button class="link" data-act="cancel">Cancel</button>'
  },
  saveSched: function (b) {
    var row = b.closest('[data-sched]'), mode = row.querySelector('[data-m]').value, v = row.querySelector('[data-v]').value.trim(), t = /^(\d{1,2}):(\d{2})$/.exec(v), body = { automation: b.dataset.n }
    if (mode === 'day' || mode === 'week') { if (!t) return toast('Write a time like 08:30.'); body.mode = 'schedule'; body.value = +t[2] + ' ' + +t[1] + ' * * ' + (mode === 'day' ? '*' : '1-5') }
    else if (mode === 'min' || mode === 'hour') { if (!/^\d+$/.test(v)) return toast('Write a number.'); body.mode = 'every'; body.value = v + (mode === 'min' ? 'm' : 'h') }
    else { body.mode = /^\d+[mhd]$/.test(v) ? 'every' : 'schedule'; body.value = v }
    apply(post(empUrl('schedule'), body), 'Schedule changed.')
  }
}
function rule(body, done) { return apply(post('/api/settings/rules', body), done) }
document.addEventListener('click', function (e) { var b = e.target.closest('[data-act]'); if (b && A[b.dataset.act]) { e.preventDefault(); A[b.dataset.act](b) } })
document.addEventListener('keydown', function (e) { if (e.key === 'Enter' && e.target.matches('input[data-add]')) { e.preventDefault(); A.addRule(e.target.nextElementSibling) } })

var waiting = false
async function tell() {
  var ta = $('#tell'), text = ta.value.trim(); if (!text || waiting) return
  var mark = ''; try { var was = (await get('/api/chief')).messages; mark = JSON.stringify(was[was.length - 1] || '') } catch (e) {}
  if (!await post('/api/chief/say', { text: '(In Settings, looking at ' + cur + ') ' + text })) return
  ta.value = ''; ta.rows = 1; waiting = true
  var s = $('#said'); s.style.display = 'block'; s.textContent = 'The chief of staff is on it.'
  var started = Date.now()
  ;(async function poll() {
    var c = null; try { c = await get('/api/chief') } catch (e) {}
    var last = c && c.messages[c.messages.length - 1]
    if (last && last.who === 'chief' && !c.typing && JSON.stringify(last) !== mark) {
      waiting = false; s.innerHTML = '<b>Chief of staff:</b> ' + esc(last.text)
      if (!dirty()) show(true)
      return
    }
    if (Date.now() - started > 320000) { waiting = false; s.textContent = 'No answer yet. The reply will be in your chat with the chief.'; return }
    setTimeout(poll, 2500)
  })()
}
$('#tell').addEventListener('keydown', function (e) { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); tell() } })
$('#tell').addEventListener('input', function (e) { e.target.rows = Math.min(5, e.target.value.split('\n').length) })
show()
</script>
</body>
</html>
`
