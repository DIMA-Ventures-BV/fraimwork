// What the settings page and the CLI show: the team, who works now, conversations and the
// chief's chat. The API in fraim-queue-api.mjs has raw fields.
import { execFile, spawn } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import {
  AUTOS, AUTO_STATE, GOALS, HOME, LEADS, allItems, allThreads, readChat, readText, readThread, runtimeEnv,
  theChatAgent, theContact, tool, validId, validThread,
} from './fraim-queue-store.mjs'

export function header(text) {
  const out = {}
  const lines = text.split('\n')
  if (lines[0] !== '---') return out
  for (const l of lines.slice(1)) {
    if (l === '---') break
    const m = /^\s*([a-z_]+)\s*:\s*(.*?)\s*(?:\s#.*)?$/.exec(l)
    if (m) out[m[1]] = m[2].replace(/^"(.*)"$/, '$1')
  }
  return out
}

export function lastStatus(name) {
  const dir = path.join(AUTO_STATE, name)
  const paused = fs.existsSync(path.join(dir, 'paused'))
  const raw = readText(path.join(dir, 'last_status'), 500).trim()
  const m = /^(\w+)\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2})\s*(.*)$/.exec(raw)
  let status = m ? m[1] : 'never'
  if (status === 'silent' || status === 'skipped') status = 'ok'
  if (paused) status = 'paused'
  return { status, last: m ? m[2] : '', detail: m && m[1] === 'failed' ? m[3] : '' }
}

function leadRuns(dir, count) {
  let files = []
  try { files = fs.readdirSync(dir).filter((f) => /^\d{8}-\d{6}\.md$/.test(f)).sort().reverse().slice(0, count) } catch {}
  return files.map((f) => {
    const m = /^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})/.exec(f)
    // The run log ends with the inbox notes the run read (for the lead's own history); the owner
    // sees only the answer.
    const text = readText(path.join(dir, f), 4000).split('\n--- inbox this run read ---')[0].trim()
    return { text, time: `${m[1]}-${m[2]}-${m[3]} ${m[4]}:${m[5]}` }
  })
}

export function team() {
  const leads = []
  const automations = []
  let chief = null
  const contact = theContact()
  let names = []
  try { names = fs.readdirSync(AUTOS).filter((n) => !n.startsWith('_') && !n.startsWith('.')).sort() } catch {}
  for (const name of names) {
    const h = header(readText(path.join(AUTOS, name, 'automation.md'), 4000))
    if (!Object.keys(h).length && !fs.existsSync(path.join(AUTOS, name, 'automation.md'))) continue
    const when = h.schedule ? `schedule ${h.schedule}` : h.every ? `every ${h.every}` : h.trigger ? h.trigger : 'by hand'
    const base = { name, title: displayName(h.lead || name), when, description: (h.description || '').replace(/^Lead [a-z0-9-]+:\s*/, ''), off: /^(false|no|off|0)$/i.test(h.enabled || ''), ...lastStatus(name) }
    if (!h.lead) { automations.push(base); continue }
    const role = h.lead === contact ? 'chief' : 'lead'
    leads.push({ ...base, lead: h.lead, role })
    if (h.lead === contact) chief = { name: h.lead, title: displayName(h.lead), schedule: h.schedule || '', ...leadRuns(path.join(LEADS, h.lead, 'runs'), 1)[0] }
  }
  return { chief, leads, automations }
}

// --- active agents: who works right now --------------------------------------------------
// Interactive Claudes (the main chat, goals, coding sessions) come from herdr when it is
// installed; headless lead and automation runs come from the fraim-auto run locks.

// Never blocks the page server: other requests go on while herdr or hc answers.
export function run(cmd, args, timeout = 8000) {
  return new Promise((resolve) => {
    execFile(tool(cmd), args, { encoding: 'utf8', timeout, env: runtimeEnv(), maxBuffer: 4 << 20 }, (err, stdout) => resolve(err ? null : stdout))
  })
}

export async function active() {
  const out = []
  const herd = await run('fraim-herdr', ['ls', '--json'])
  if (herd) {
    try {
      for (const a of JSON.parse(herd)) {
        if (!a || !a.name || a.kind === 'shell' || a.kind === 'service') continue
        out.push({ name: String(a.name), kind: String(a.kind || 'session'), status: String(a.status || 'none'), question: String(a.question || ''), cwd: String(a.cwd || ''), turn: String(a.turn || ''), live: true })
      }
    } catch {}
  }
  let names = []
  try { names = fs.readdirSync(AUTO_STATE) } catch {}
  for (const name of names) {
    if (!fs.existsSync(path.join(AUTO_STATE, name, 'lock'))) continue
    const h = header(readText(path.join(AUTOS, name, 'automation.md'), 4000))
    const since = (() => { try { return fs.statSync(path.join(AUTO_STATE, name, 'lock')).mtime.toISOString() } catch { return '' } })()
    out.push({ name, kind: h.lead ? 'lead' : 'automation', status: 'working', question: '', cwd: '', turn: since, live: true })
  }
  const order = { blocked: 0, working: 1, error: 2, idle: 3, done: 4, none: 5 }
  return out.sort((a, b) => (order[a.status] ?? 9) - (order[b.status] ?? 9) || a.name.localeCompare(b.name))
}

// The name people see is the display: line of the lead's brief; without one, its folder name.
function displayName(name) {
  const n = String(name || '')
  if (n === 'owner') return 'You'
  if (n === 'manual') return 'Fraim'
  if (/^goal /.test(n)) return 'A helper'
  if (/^automation /.test(n)) return displayName(n.slice(11))
  const own = header(readText(path.join(LEADS, n, 'lead.md'), 2000)).display
  if (own) return own
  if (n && n === theContact()) return 'Chief of staff'
  const plain = n.replace(/-/g, ' ')
  return plain ? plain.charAt(0).toUpperCase() + plain.slice(1) : 'Someone'
}

const leadArea = (name) => /^## Area\n+((?:[^\n#][^\n]*\n?)+)/m.exec(readText(path.join(LEADS, name, 'lead.md')))?.[1]?.trim() || ''

// What a tool entry is called on the page: mcp__linear__list_issues is Linear. Shell commands are not listed.
function toolNames(entries) {
  const names = entries.map((t) => /^mcp__([^_]+(?:_[^_]+)*?)(?:__|$)/.exec(t.trim())?.[1]).filter(Boolean).map((t) => t.replace(/[-_]mcp$/, ''))
  return [...new Set(names)].map((t) => t.charAt(0).toUpperCase() + t.slice(1)).sort()
}

// Everyone who works here, read from the files they are set up with.
export function employees() {
  const products = {}
  let repos = []
  try { repos = fs.readdirSync(path.join(HOME, 'fraim/projects')) } catch {}
  for (const repo of repos) {
    for (const l of readText(path.join(HOME, 'fraim/projects', repo, 'installed.tsv')).split('\n')) {
      const [kind, name] = l.split('\t')
      if (kind && name) products[`${kind}:${name}`] = repo
    }
  }
  const { leads, automations } = team()
  const people = leads.filter((m) => m.name === m.lead).map((m) => ({
    name: m.name, title: displayName(m.name), does: leadArea(m.name) || m.description, product: products[`lead:${m.name}`] || '',
    off: m.off || fs.existsSync(path.join(LEADS, m.name, 'paused')), status: m.status, last: m.last,
    starts: leads.filter((x) => x.lead === m.lead).map((x) => x.when),
    tools: toolNames(readText(path.join(LEADS, m.name, 'tools')).split('\n')),
  }))
  const watchers = automations.map((m) => ({
    name: m.name, title: displayName(m.name), does: m.description, product: products[`auto:${m.name}`] || '', off: m.off, status: m.status, last: m.last,
    starts: [m.when], tools: toolNames(String(header(readText(path.join(AUTOS, m.name, 'automation.md'), 4000)).tools || '').split(',')),
  }))
  return { people, watchers }
}

// Agent notes keep exact file names and logs after a line "Details:"; people read what is above it.
const spoken = (text) => String(text || '').split(/^Details:\s*$/m)[0].trim()

function workers() {
  const out = {}
  const add = (id, name) => { (out[id] ||= []).includes(name) || out[id].push(name) }
  let leads = []
  try { leads = fs.readdirSync(LEADS) } catch {}
  for (const n of leads) {
    for (const id of readText(path.join(LEADS, n, '.running/thread'), 200).split('\n')) if (validThread(id)) add(id, displayName(n))
  }
  let goals = []
  try { goals = fs.readdirSync(GOALS) } catch {}
  for (const g of goals) {
    const id = readText(path.join(GOALS, g, 'thread'), 40).trim()
    if (id && /^(running|starting|working)/.test(readText(path.join(GOALS, g, 'state'), 40))) add(id, 'A helper')
  }
  return out
}

const RECENT = 15 * 60 * 1000
function threadState(t, open, working) {
  if (t.closed) return 'done'
  if (open.length) return 'need'
  if (working?.length) return 'work'
  if (!t.active) return 'new'
  return Date.now() - Math.max(Date.parse(t.changed) || 0, Date.parse(t.active) || 0) < RECENT ? 'work' : 'done'
}

function firstWords(text) {
  return (String(text || '').split('\n').find((l) => l.trim()) || '').trim().slice(0, 160)
}

export function inboxRows() {
  const items = allItems()
  const working = workers()
  const rows = allThreads().map((t) => {
    const mine = items.filter((i) => i.thread === t.id)
    const open = mine.filter((i) => i.state === 'open')
    const chat = readChat(t.id).at(-1)
    const last = t.messages.at(-1)
    const asker = open[0] && displayName(itemOwner(open[0]))
    return {
      id: t.id, kind: t.kind, title: t.title || '(no subject)', who: t.who || 'Someone',
      snippet: open[0] ? `${asker}: ${open[0].ask || open[0].title}` : chat ? `${displayName(chat.from)}: ${firstWords(spoken(chat.text))}` : firstWords(last?.text || t.text),
      time: [t.changed, t.active, ...mine.map((i) => i.created)].sort().at(-1),
      state: threadState(t, open, working[t.id]),
      closed: Boolean(t.closed),
      unread: !t.closed && t.changed > (t.seen || ''),
    }
  })
  const loose = items.filter((i) => !i.thread)
  const shown = [...loose.filter((i) => i.state === 'open'), ...loose.filter((i) => i.state !== 'open').sort((a, b) => b.decided.localeCompare(a.decided)).slice(0, 100)]
  for (const i of shown) {
    rows.push({ id: i.id, kind: 'item', title: i.title, who: displayName(itemOwner(i)), snippet: i.ask || i.need || firstWords(i.summary), time: i.state === 'open' ? i.created : i.decided, state: i.state === 'open' ? 'need' : 'done', unread: i.state === 'open' })
  }
  return rows.sort((a, b) => String(b.time).localeCompare(String(a.time)))
}

function itemOwner(i) {
  return i.lead || (/^automation /.test(i.source) ? i.source.slice(11) : i.source)
}

export function describeThread(id) {
  const t = readThread(id)
  const parts = [`${t.id}: ${t.title}`, `From ${t.who}, ${t.kind}`]
  for (const m of t.messages) parts.push('', `${m.from}${m.forwardedBy ? `, forwarded by ${m.forwardedBy}` : ''}, ${m.date}:`, m.text)
  if (t.text) parts.push('', t.text)
  for (const [k, v] of Object.entries(t.fields)) parts.push(`${k}: ${v}`)
  for (const c of t.comments) parts.push('', `${c.who}: ${c.text}`)
  if (t.details) parts.push('', t.details)
  const chat = readChat(id)
  if (chat.length) parts.push('', 'What the agents said so far:', ...chat.map((c) => `${c.from} to ${c.to || 'everyone'}: ${c.text}`))
  return parts.join('\n')
}

// --- the owner's chat in the app: the same conversation as WhatsApp ----------------------------

const RELAY = process.env.FRAIM_RELAY_DIR || path.join(HOME, 'fraim/relay')

export function ownerChat() {
  const items = allItems()
  const titles = Object.fromEntries(allThreads().map((t) => [t.id, t.title]))
  const lines = readText(path.join(RELAY, 'conversation.jsonl'), 4000000).split('\n').flatMap((l) => {
    try { return l ? [JSON.parse(l)] : [] } catch { return [] }
  })
  const messages = lines.slice(-200).map((m) => {
    const refs = new Map()
    for (const q of String(m.about || '').split(/\s+/).filter(validId)) {
      const item = items.find((i) => i.id === q)
      if (item) refs.set(item.thread || item.id, titles[item.thread] || item.title)
    }
    return { who: m.who === 'owner' ? 'owner' : 'chief', text: String(m.text || ''), time: String(m.time || ''), app: m.chat === 'app', refs: [...refs].slice(0, 3).map(([id, title]) => ({ id, title })) }
  })
  const agent = theChatAgent()
  return { exists: true, title: agent ? displayName(agent) : displayName('manual'), typing: fs.existsSync(path.join(RELAY, 'chat.lock')), messages }
}

// The answer takes longer than fire() allows, and the page does not wait for it.
export function askChatAgent(text) {
  const child = spawn(tool('fraim-relay'), ['chat', '--', text], { env: runtimeEnv(), stdio: 'ignore', detached: true })
  child.on('error', () => {})
  child.unref()
}
