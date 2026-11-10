// The queue's files on disk: items and conversations, and the helpers every part of it shares.
import { execFileSync, spawn, spawnSync } from 'node:child_process'
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'

export const HOME = process.env.HOME || '/home/claude'
export const QUEUE = process.env.FRAIM_QUEUE_DIR || path.join(HOME, 'fraim/queue')
export const GOALS = process.env.FRAIM_GOALS_DIR || path.join(HOME, 'fraim/goals')
export const TOKEN_FILE = path.join(HOME, '.config/fraim/queue-token')
export const PORT = parseInt(process.env.FRAIM_QUEUE_PORT || '3109', 10)
export const KINDS = ['review', 'decision', 'idea', 'info', 'failed']
export const STATES = ['open', 'approved', 'rejected', 'dismissed']
export const ADVICE = ['approve', 'reject', 'dismiss']
export const MEDIA_TYPES = {
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp',
  '.webm': 'video/webm', '.mp4': 'video/mp4', '.mov': 'video/quicktime',
}

export class UsageError extends Error {}
export function usage(msg) { throw new UsageError(msg) }
export class Refused extends Error {}

// The page server answers one request at a time, so it never waits on a message to send: it
// starts fraim-notify and fraim-lead tell and moves on. The command line waits for them.
let SERVING = false
export function fire(cmd, args, env = process.env) {
  if (!SERVING) return void spawnSync(cmd, args, { env, stdio: 'ignore', timeout: 30000 })
  try {
    const child = spawn(cmd, args, { env, stdio: 'ignore' })
    child.on('error', () => {})
    const kill = setTimeout(() => child.kill(), 30000)
    child.on('exit', () => clearTimeout(kill))
  } catch {}
}
export const setServing = () => { SERVING = true }

export function runtimeEnv() {
  const env = {}
  try {
    for (const line of fs.readFileSync(process.env.FRAIM_RUNTIME_ENV || '/etc/fraim/runtime.env', 'utf8').split('\n')) {
      const m = line.match(/^([A-Z_]+)=(.*)$/)
      if (m) env[m[1]] = m[2].replace(/^'(.*)'$/, '$1').replace(/\\(.)/g, '$1')
    }
  } catch {}
  return { ...env, ...process.env }
}

// The command on PATH; otherwise the script next to this one (a checkout without an install).
export function tool(name) {
  for (const dir of (process.env.PATH || '').split(':')) {
    if (dir && fs.existsSync(path.join(dir, name))) return name
  }
  try {
    const sibling = path.join(path.dirname(fs.realpathSync(process.argv[1])), name)
    if (fs.existsSync(sibling)) return sibling
  } catch {}
  return name
}

export const now = () => new Date().toISOString().replace(/\.\d+Z$/, 'Z')
export const validId = (id) => /^q\d{1,6}$/.test(id)
export const itemDir = (id) => path.join(QUEUE, id)

export function readItem(id) {
  if (!validId(id)) usage(`'${id}' is not a queue id (q1, q2, ...)`)
  try {
    return JSON.parse(fs.readFileSync(path.join(itemDir(id), 'item.json'), 'utf8'))
  } catch {
    throw new Error(`no queue item ${id}`)
  }
}

export function writeItem(item) {
  const file = path.join(itemDir(item.id), 'item.json')
  fs.writeFileSync(`${file}.tmp`, JSON.stringify(item, null, 2) + '\n')
  fs.renameSync(`${file}.tmp`, file)
}

export function allItems() {
  let names = []
  try { names = fs.readdirSync(QUEUE) } catch { return [] }
  const out = []
  for (const name of names) {
    if (!validId(name)) continue
    try { out.push(JSON.parse(fs.readFileSync(path.join(QUEUE, name, 'item.json'), 'utf8'))) } catch {}
  }
  return out
}

// Open before closed; then priority 1 first; then the oldest first, so nothing waits forever.
export function rank(items) {
  return [...items].sort((a, b) => {
    const ao = a.state === 'open' ? 0 : 1
    const bo = b.state === 'open' ? 0 : 1
    if (ao !== bo) return ao - bo
    if (ao === 1) return (b.decided || '').localeCompare(a.decided || '')
    if (a.priority !== b.priority) return a.priority - b.priority
    return a.created.localeCompare(b.created) || parseInt(a.id.slice(1), 10) - parseInt(b.id.slice(1), 10)
  })
}

export function newId() {
  fs.mkdirSync(QUEUE, { recursive: true })
  const last = path.join(QUEUE, '.last')
  let n = 1
  try { n = parseInt(fs.readFileSync(last, 'utf8'), 10) + 1 || 1 } catch {}
  for (;;) {
    try {
      fs.mkdirSync(path.join(QUEUE, `q${n}`))
      break
    } catch (err) {
      if (err.code !== 'EEXIST') throw err
      n++
    }
  }
  fs.writeFileSync(last, `${n}\n`)
  return `q${n}`
}

export function copyMedia(dir, files, taken = []) {
  const names = []
  if (!files.length) return names
  fs.mkdirSync(path.join(dir, 'media'), { recursive: true })
  for (const file of files) {
    const ext = path.extname(file).toLowerCase()
    if (!MEDIA_TYPES[ext]) {
      process.stderr.write(`fraim-queue: skipped ${file}: only images and videos can be attached\n`)
      continue
    }
    if (!fs.statSync(file, { throwIfNoEntry: false })?.isFile()) {
      process.stderr.write(`fraim-queue: skipped ${file}: not a file\n`)
      continue
    }
    let name = path.basename(file).replace(/[^\w.-]/g, '_')
    while (names.includes(name) || taken.includes(name)) name = `1-${name}`
    fs.copyFileSync(file, path.join(dir, 'media', name))
    names.push(name)
  }
  return names
}

export function queueUrl() {
  const env = runtimeEnv()
  const start = parseInt(String(env.FRAIM_PREVIEW_PORTS || '3100-3109').split('-')[0], 10)
  const port = start + (PORT - 3100)
  let token = ''
  try { token = fs.readFileSync(TOKEN_FILE, 'utf8').trim() } catch {}
  const query = token ? `/?t=${token}` : '/'
  if (env.FRAIM_PREVIEW_HOST) return `http://${env.FRAIM_PREVIEW_HOST}:${port}${query}`
  const mode = env.FRAIM_ACCESS_MODE || ''
  if (mode === 'tailscale') return `http://${env.FRAIM_HOSTNAME || 'fraim'}:${port}${query}`
  if (mode === 'local') return `http://localhost:${port}${query}`
  return `on the laptop: fraim queue open${env.FRAIM_SPACE && env.FRAIM_SPACE !== 'main' ? ` --space ${env.FRAIM_SPACE}` : ''}`
}

export const AUTOS = process.env.FRAIM_AUTOMATIONS_DIR || path.join(HOME, 'fraim/automations')
export const AUTO_STATE = process.env.FRAIM_AUTO_STATE_DIR || path.join(HOME, '.local/state/fraim/automations')
export const LEADS = process.env.FRAIM_LEADS_DIR || path.join(HOME, 'fraim/leads')

export function roleOf(lead) {
  const res = spawnSync(tool('fraim-authority'), ['role-of', lead], { encoding: 'utf8', timeout: 10000, env: { ...process.env, FRAIM_LEADS_DIR: LEADS } })
  return res.status === 0 ? res.stdout.trim() : ''
}

export const isChief = (lead) => roleOf(lead) === 'chief'

// A note in the lead's inbox that wakes it now (fraim-lead tell).
export function tellLead(lead, from, text, thread = '') {
  if (!/^[a-z0-9][a-z0-9-]{0,39}$/.test(lead) || !fs.existsSync(path.join(LEADS, lead, 'lead.md'))) return
  fire('fraim-lead', ['tell', lead, '--from', from, ...(thread ? ['--thread', thread] : []), '--', text])
}

export function readText(file, max = 20000) {
  try { return fs.readFileSync(file, 'utf8').slice(0, max) } catch { return '' }
}

export const THREADS = process.env.FRAIM_THREADS_DIR || path.join(HOME, 'fraim/threads')
export const validThread = (id) => /^t\d{1,6}$/.test(id)

export function readThread(id) {
  if (!validThread(id)) usage(`'${id}' is not a conversation id (t1, t2, ...)`)
  try {
    return JSON.parse(fs.readFileSync(path.join(THREADS, id, 'thread.json'), 'utf8'))
  } catch {
    throw new Error(`no conversation ${id}`)
  }
}

export function writeThread(t) {
  const file = path.join(THREADS, t.id, 'thread.json')
  fs.writeFileSync(`${file}.tmp`, JSON.stringify(t, null, 2) + '\n')
  fs.renameSync(`${file}.tmp`, file)
}

export function allThreads() {
  let names = []
  try { names = fs.readdirSync(THREADS) } catch { return [] }
  const out = []
  for (const name of names) {
    if (!validThread(name)) continue
    try { out.push(JSON.parse(fs.readFileSync(path.join(THREADS, name, 'thread.json'), 'utf8'))) } catch {}
  }
  return out
}

export function newThreadId() {
  fs.mkdirSync(THREADS, { recursive: true })
  const last = path.join(THREADS, '.last')
  let n = 1
  try { n = parseInt(fs.readFileSync(last, 'utf8'), 10) + 1 || 1 } catch {}
  for (;;) {
    try {
      fs.mkdirSync(path.join(THREADS, `t${n}`))
      break
    } catch (err) {
      if (err.code !== 'EEXIST') throw err
      n++
    }
  }
  fs.writeFileSync(last, `${n}\n`)
  return `t${n}`
}

export function readChat(id) {
  return readText(path.join(THREADS, id, 'chat.jsonl'), 2000000).split('\n').flatMap((l) => {
    try { return l ? [JSON.parse(l)] : [] } catch { return [] }
  })
}

export function theChief() {
  try { return fs.readdirSync(LEADS).find((n) => isChief(n)) || '' } catch { return '' }
}

// What an agent is told is a file the owner can change. A broken setup still passes the facts on.
export function promptText(name, values) {
  try {
    return execFileSync(tool('fraim-prompt'), ['render', name, ...Object.entries(values).flatMap(([k, v]) => ['--set', `${k}=${v}`])], { encoding: 'utf8', timeout: 10000, stdio: ['ignore', 'pipe', 'ignore'] }).trim()
  } catch {
    return Object.values(values).join(' ')
  }
}

export function token() {
  try {
    const t = fs.readFileSync(TOKEN_FILE, 'utf8').trim()
    if (t) return t
  } catch {}
  const t = crypto.randomBytes(24).toString('base64url')
  fs.mkdirSync(path.dirname(TOKEN_FILE), { recursive: true, mode: 0o700 })
  fs.writeFileSync(TOKEN_FILE, `${t}\n`, { mode: 0o600 })
  return t
}
