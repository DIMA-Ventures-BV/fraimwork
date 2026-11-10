// What today's screens show: the team, who works now, inbox rows and the chief's chat. Words
// on these views are for the shipped pages; the API in fraim-queue-api.mjs has raw fields.
import { execFile, spawn } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import {
  AUTOS, AUTO_STATE, GOALS, HOME, LEADS, allItems, allThreads, isChief, readChat, readItem, readText, readThread,
  runtimeEnv, theChief, tool, usage, validId, validThread,
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

function latestRun(dir) {
  return leadRuns(dir, 1)[0] || null
}

function automationRuns(dir, count) {
  let names = []
  try { names = fs.readdirSync(dir).filter((f) => /^\d{4}-\d{2}-\d{2}T/.test(f)).sort().reverse().slice(0, count) } catch {}
  return names.map((n) => {
    const m = /^(\d{4}-\d{2}-\d{2})T(\d{2})\D?(\d{2})/.exec(n)
    return { text: readText(path.join(dir, n, 'output.md'), 4000).trim(), time: m ? `${m[1]} ${m[2]}:${m[3]}` : n }
  })
}

export function team() {
  const leads = []
  const automations = []
  let chief = null
  let names = []
  try { names = fs.readdirSync(AUTOS).filter((n) => !n.startsWith('_') && !n.startsWith('.')).sort() } catch {}
  for (const name of names) {
    const h = header(readText(path.join(AUTOS, name, 'automation.md'), 4000))
    if (!Object.keys(h).length && !fs.existsSync(path.join(AUTOS, name, 'automation.md'))) continue
    const when = h.schedule ? `schedule ${h.schedule}` : h.every ? `every ${h.every}` : h.trigger ? h.trigger : 'by hand'
    const base = { name, title: displayName(h.lead || name), when, description: (h.description || '').replace(/^Lead [a-z0-9-]+:\s*/, ''), off: /^(false|no|off|0)$/i.test(h.enabled || ''), ...lastStatus(name) }
    if (!h.lead) { automations.push(base); continue }
    const role = isChief(h.lead) ? 'chief' : 'lead'
    leads.push({ ...base, lead: h.lead, role })
    if (role === 'chief') chief = { name: h.lead, title: displayName(h.lead), schedule: h.schedule || '', ...(latestRun(path.join(LEADS, h.lead, 'runs')) || {}) }
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

// The steps of a headless run (claude -p --output-format stream-json), as lines a person reads:
// what Claude wrote and each tool it used, newest last.
const TOOL_ARG = ['command', 'file_path', 'path', 'pattern', 'url', 'query', 'description', 'prompt', 'skill']
export function transcript(jsonl) {
  const out = []
  for (const raw of String(jsonl || '').split('\n')) {
    let e
    try { e = JSON.parse(raw) } catch { continue }
    if (!e || typeof e !== 'object') continue
    if (e.type === 'assistant') {
      for (const c of e.message?.content || []) {
        if (c.type === 'text' && c.text?.trim()) out.push(c.text.trim())
        if (c.type === 'tool_use') {
          const i = c.input || {}
          const k = TOOL_ARG.find((key) => typeof i[key] === 'string' && i[key])
          const arg = k ? String(i[k]).replace(/\s+/g, ' ').slice(0, 160) : ''
          out.push(`> ${c.name}${arg ? `: ${arg}` : ''}`)
        }
      }
    } else if (e.type === 'result') {
      out.push(e.is_error ? `Stopped with an error: ${String(e.result || '').slice(0, 400)}` : `Done.${e.result ? `\n\n${String(e.result).slice(0, 4000)}` : ''}`)
    }
  }
  return out.slice(-120).join('\n\n')
}

// The live log of a lead or automation run: while it works, the file it writes now; after,
// the log of its last run.
export function runLog(name) {
  const h = header(readText(path.join(AUTOS, name, 'automation.md'), 4000))
  if (!Object.keys(h).length) return null
  const newest = (dir, re) => { try { return fs.readdirSync(dir).filter((f) => re.test(f)).sort().at(-1) } catch { return undefined } }
  if (h.lead) {
    if (!/^[a-z0-9][a-z0-9-]{0,39}$/.test(h.lead)) return null
    const dir = path.join(LEADS, h.lead)
    const live = path.join(dir, '.running/live.jsonl')
    if (fs.existsSync(live)) return live
    const f = newest(path.join(dir, 'runs'), /^\d{8}-\d{6}\.md\.jsonl$/)
    return f ? path.join(dir, 'runs', f) : ''
  }
  const runs = path.join(AUTOS, name, 'runs')
  const f = newest(runs, /^\d{4}-\d{2}-\d{2}T/)
  return f && fs.existsSync(path.join(runs, f, 'log.jsonl')) ? path.join(runs, f, 'log.jsonl') : ''
}

// The steps of a run for the lead page: what Claude said and did, in the words a person uses.
const TOOL_WORD = { Bash: 'Ran', Read: 'Read', Write: 'Wrote', Edit: 'Changed', Grep: 'Searched', Glob: 'Looked for', WebFetch: 'Opened', WebSearch: 'Searched the web', Task: 'Asked a helper', Agent: 'Asked a helper', Skill: 'Used skill' }
export function runSteps(jsonl) {
  const out = []
  for (const raw of String(jsonl || '').split('\n')) {
    let e
    try { e = JSON.parse(raw) } catch { continue }
    if (e?.type !== 'assistant') continue
    for (const c of e.message?.content || []) {
      if (c.type === 'text' && c.text?.trim()) out.push({ say: c.text.trim().slice(0, 600) })
      if (c.type === 'tool_use') {
        const i = c.input || {}
        const k = ['description', ...TOOL_ARG].find((key) => typeof i[key] === 'string' && i[key])
        out.push({ did: TOOL_WORD[c.name] || `Used ${String(c.name).split('__').at(-1)}`, what: k ? String(i[k]).replace(/\s+/g, ' ').slice(0, 160) : '' })
      }
    }
  }
  return out
}

// All the page shows for one lead or automation: what it is for, what it does now, what it found.
export function member(name) {
  if (!validAgent(name)) usage('not a lead or automation name')
  const text = readText(path.join(AUTOS, name, 'automation.md'), 4000)
  if (!text) return null
  const h = header(text)
  const lead = /^[a-z0-9][a-z0-9-]{0,39}$/.test(h.lead || '') ? h.lead : ''
  const area = lead ? /^## Area\n+((?:[^\n#][^\n]*\n?)+)/m.exec(readText(path.join(LEADS, lead, 'lead.md'))) : null
  const lock = path.join(AUTO_STATE, name, 'lock')
  const running = fs.existsSync(lock)
  const log = running ? runLog(name) : ''
  let since = ''
  try { since = fs.statSync(lock).mtime.toISOString() } catch {}
  return {
    name, running, since,
    about: area ? area[1].trim() : (h.description || '').replace(/^Lead [a-z0-9-]+:\s*/, ''),
    steps: log ? runSteps(readText(log, 4000000)).slice(-40).reverse() : [],
    runs: lead ? leadRuns(path.join(LEADS, lead, 'runs'), 10) : automationRuns(path.join(AUTOS, name, 'runs'), 10),
  }
}

export async function active() {
  const out = []
  const herd = await run('fraim-herdr', ['ls', '--json'])
  if (herd) {
    try {
      for (const a of JSON.parse(herd)) {
        if (!a || !a.name || a.kind === 'shell') continue
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

export const validAgent = (n) => /^[a-z0-9][a-z0-9_-]{0,47}$/.test(n)

export async function agentScreen(name) {
  if (!validAgent(name)) usage('not an agent name')
  if (fs.existsSync(path.join(AUTO_STATE, name, 'lock'))) {
    const log = runLog(name)
    if (log != null) return { name, text: log ? transcript(readText(log, 4000000)) : '' }
  }
  const text = /^g\d+$/.test(name) ? await run('fraim-goal', ['read', name]) : await run('hc', ['read', name, '--lines', '80'])
  return { name, text: text == null ? '' : text.slice(-20000) }
}

export async function agentSend(name, text) {
  if (!validAgent(name)) usage('not an agent name')
  text = String(text || '').trim()
  if (!text) usage('write a message first')
  const r = /^g\d+$/.test(name) ? await run('fraim-goal', ['send', name, text], 15000)
    : /^s\d+$/.test(name) ? await run('fraim-sessions', ['send', name, text], 15000) : null
  if (r == null) throw new Error(`could not send to ${name}; only goals (g1) and sessions (s1) take messages`)
  return { ok: true }
}

// The name people see is the display: line of the lead's brief; without one, its folder name.
export function displayName(name) {
  const n = String(name || '')
  if (n === 'owner') return 'You'
  if (n === 'manual') return 'Fraim'
  if (/^goal /.test(n)) return 'A helper'
  if (/^automation /.test(n)) return displayName(n.slice(11))
  const own = header(readText(path.join(LEADS, n, 'lead.md'), 2000)).display
  if (own) return own
  if (isChief(n)) return 'Chief of staff'
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

const ANSWER = { approved: 'Yes, go ahead.', dismissed: 'No, leave it.', rejected: 'No.' }
const REPLY_ANSWER = { approved: 'Send it.', dismissed: 'Do not send it.', rejected: 'Not like this.' }
function itemChat(i) {
  const ask = { time: i.created, from: displayName(itemOwner(i)), to: 'You', item: { id: i.id, title: i.title, ask: i.ask, need: i.need, if_yes: i.if_yes, advise: i.advise, state: i.state, reply: i.reply } }
  if (i.state === 'open') return [ask]
  return [ask, { time: i.decided, from: 'You', to: displayName(itemOwner(i)), text: `${(i.reply ? REPLY_ANSWER : ANSWER)[i.state] || ''}${i.note ? ` ${i.note}` : ''}`.trim() }]
}

export function threadDetail(id) {
  if (validId(id)) {
    const i = readItem(id)
    return { id: i.id, kind: 'item', title: i.title, who: displayName(itemOwner(i)), text: i.summary, created: i.created, links: i.links, media: i.media, fields: {}, messages: [], comments: [], chat: itemChat(i), working: [] }
  }
  const t = readThread(id)
  const { seen: _seen, ...shown } = t
  const said = readChat(id).map((c) => ({ time: c.time, from: displayName(c.from), to: c.to ? displayName(c.to) : '', text: spoken(c.text) }))
  const items = allItems().filter((i) => i.thread === id)
  const chat = [...said, ...items.flatMap(itemChat)].sort((a, b) => String(a.time).localeCompare(String(b.time)))
  return { ...shown, links: [], media: [], chat, working: workers()[id] || [] }
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

// --- the chat with the chief of staff: the same conversation as WhatsApp ---------------------

const RELAY = process.env.FRAIM_RELAY_DIR || path.join(HOME, 'fraim/relay')

export function chiefChat() {
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
  return { exists: Boolean(theChief()), title: displayName(theChief()), typing: fs.existsSync(path.join(RELAY, 'chat.lock')), messages }
}

// A chief's answer takes longer than fire() allows, and the page does not wait for it.
export function askChief(text) {
  const child = spawn(tool('fraim-relay'), ['chat', '--', text], { env: runtimeEnv(), stdio: 'ignore', detached: true })
  child.on('error', () => {})
  child.unref()
}
