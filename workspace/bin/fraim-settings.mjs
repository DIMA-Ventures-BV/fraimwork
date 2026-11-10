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

  const allRules = () => parseRules(run('fraim-brain', ['show']).out)

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

