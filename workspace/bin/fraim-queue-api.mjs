// /api/v1: raw fields for a screen someone else builds, on another address if they like.
// The contract is fraim-queue-openapi.json; a test holds it to ROUTES. See docs/api.md.
import fs from 'node:fs'
import path from 'node:path'
import {
  AUTOS, KINDS, QUEUE, Refused, STATES, THREADS, UsageError, allItems, allThreads, promptText, isLead, mediaFile, rank,
  readChat, readItem, readText, readThread, roleOf, validId, validThread,
} from './fraim-queue-store.mjs'
import { addItem, decide } from './fraim-queue-approve.mjs'
import { sayInThread, tellContact } from './fraim-queue-threads.mjs'
import { active, header, lastStatus, run } from './fraim-queue-views.mjs'
import { allows, findToken, originListed, stillValid } from './fraim-queue-tokens.mjs'

const MAX_BODY = 65536
const MAX_TEXT = 4000
const MAX_STREAMS = 32
const SCHEMA = new URL('./fraim-queue-openapi.json', import.meta.url)

class Problem extends Error {
  constructor(status, code, message) {
    super(message)
    Object.assign(this, { status, code })
  }
}
const bad = (message) => new Problem(400, 'bad_request', message)

function identify(req, isPageCookie) {
  const auth = req.headers.authorization
  if (auth !== undefined) {
    const m = /^Bearer ([\w-]{1,256})$/i.exec(auth)
    const token = m && findToken(m[1])
    if (!token) throw new Problem(401, 'unauthorized', 'unknown or removed token')
    return { token, from: `app-${token.name}`, via: `api:${token.name}`, source: `app ${token.name}` }
  }
  if (isPageCookie(req)) return { cookie: true, from: 'owner', via: 'page', source: 'page' }
  throw new Problem(401, 'unauthorized', 'send Authorization: Bearer TOKEN')
}

export function readJson(req, max = MAX_BODY) {
  return new Promise((resolve, reject) => {
    const tooLarge = () => reject(new Problem(413, 'too_large', `a request is at most ${max} bytes`))
    if (Number(req.headers['content-length']) > max) return tooLarge()
    const chunks = []
    let size = 0
    req.on('data', (c) => {
      size += c.length
      if (size > max) return tooLarge()
      chunks.push(c)
    })
    req.on('error', reject)
    req.on('end', () => {
      if (size > max) return
      let body = {}
      try { if (size) body = JSON.parse(Buffer.concat(chunks).toString()) } catch { return reject(bad('invalid JSON')) }
      if (!body || typeof body !== 'object' || Array.isArray(body)) return reject(bad('the body must be a JSON object'))
      resolve(body)
    })
  })
}

function string(body, key, max) {
  const v = body[key]
  if (v == null) return ''
  if (typeof v !== 'string') throw bad(`${key} must be a string`)
  if (v.length > max) throw bad(`${key} is at most ${max} characters`)
  return v
}

function requiredText(body) {
  const text = string(body, 'text', MAX_TEXT).trim()
  if (!text) throw bad('text is required')
  return text
}

function paged(url, key, rows) {
  const number = (name, fallback, max) => {
    const raw = url.searchParams.get(name)
    if (raw == null) return fallback
    const n = /^\d{1,7}$/.test(raw) ? Number(raw) : NaN
    if (!(n <= max)) throw bad(`${name} must be a number up to ${max}`)
    return n
  }
  const limit = number('limit', 50, 200)
  const offset = number('offset', 0, 9999999)
  if (limit < 1) throw bad('limit must be at least 1')
  return { [key]: rows.slice(offset, offset + limit), total: rows.length, limit, offset }
}

function listItems({ url }) {
  const state = url.searchParams.get('state')
  if (state != null && !STATES.includes(state)) throw bad(`state must be one of ${STATES.join(', ')}`)
  return [200, paged(url, 'items', rank(allItems().filter((i) => !state || i.state === state)))]
}

// Only what a question for the owner needs. Anything that could start work or count as a yes
// stays with the owner's own tools, so a write token can ask but never act.
function createItem({ body, who }) {
  const links = body.links ?? []
  if (!Array.isArray(links) || links.length > 20 || links.some((l) => typeof l !== 'string' || !/^https?:\/\//.test(l))) throw bad('links must be at most 20 http or https addresses')
  const why = body.why ?? []
  if (!Array.isArray(why) || why.length > 3 || why.some((w) => typeof w !== 'string')) throw bad('why must be at most 3 strings')
  const title = string(body, 'title', 200).trim()
  if (!title) throw bad('title is required')
  const kind = string(body, 'kind', 20) || 'review'
  if (!KINDS.includes(kind)) throw bad(`kind must be one of ${KINDS.join(', ')}`)
  const thread = string(body, 'thread', 10)
  if (thread) readThread(thread)
  return [201, addItem({
    title, kind, why, links, thread, priority: body.priority, source: who.source,
    ask: string(body, 'ask', 300), advise: string(body, 'advise', 20), need: string(body, 'need', 400),
    ifYes: string(body, 'if_yes', 400), ifNo: string(body, 'if_no', 400), summary: string(body, 'summary', 20000),
  })]
}

function media({ params, res }) {
  let name = ''
  try { name = decodeURIComponent(params.file) } catch {}
  const m = mediaFile(params.item, name)
  if (!m) throw new Problem(404, 'not_found', 'no such file')
  res.writeHead(200, { 'Content-Type': m.type, 'Content-Length': m.size, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' })
  fs.createReadStream(m.file).pipe(res)
}

const lastTouched = (t) => [t.changed, t.active].sort().at(-1) || ''

function listThreads({ url }) {
  const rows = allThreads().sort((a, b) => lastTouched(b).localeCompare(lastTouched(a)))
    .map(({ messages = [], comments = [], text: _text, details: _details, ...rest }) => ({ ...rest, message_count: messages.length, comment_count: comments.length }))
  return [200, paged(url, 'threads', rows)]
}

function getThread({ params }) {
  const t = readThread(params.thread)
  return [200, { ...t, chat: readChat(t.id), items: allItems().filter((i) => i.thread === t.id).map((i) => i.id) }]
}

// Words from an app are never the owner's own words, whatever its scope: the chief hears who wrote.
function say({ params, body, who }) {
  const text = requiredText(body)
  const t = readThread(params.thread)
  sayInThread(t.id, who.from, '', text)
  tellContact(t, who.from, who.cookie ? promptText('thread-owner', { text }) : promptText('thread-app', { app: who.token.name, text }))
  return [201, { ok: true, from: who.from }]
}

async function listAgents() {
  const live = await active()
  const names = new Set(live.map((a) => a.name))
  let dirs = []
  try { dirs = fs.readdirSync(AUTOS).filter((n) => !n.startsWith('_') && !n.startsWith('.')).sort() } catch {}
  const agents = dirs.flatMap((name) => {
    const text = readText(path.join(AUTOS, name, 'automation.md'), 4000)
    if (!text) return []
    const h = header(text)
    const { status, last, detail } = lastStatus(name)
    return [{
      name, kind: h.lead ? 'lead' : 'automation', lead: h.lead || '', role: h.lead ? roleOf(h.lead) : '', description: h.description || '',
      schedule: h.schedule || '', every: h.every || '', trigger: h.trigger || '', enabled: !/^(false|no|off|0)$/i.test(h.enabled || ''),
      status, last_run: last, detail, live: names.has(name),
    }]
  })
  const known = new Set(agents.map((a) => a.name))
  for (const a of live) if (!known.has(a.name)) agents.push({ name: a.name, kind: a.kind, status: a.status, question: a.question, cwd: a.cwd, live: true })
  return [200, { agents }]
}

async function tell({ params, body, who }) {
  const name = params.agent
  if (!isLead(name)) throw new Problem(404, 'not_found', `no agent ${name}`)
  const out = await run('fraim-lead', ['tell', name, '--from', who.from, '--', requiredText(body)], 15000)
  if (out == null) throw new Problem(502, 'agent_unreachable', `could not reach ${name}`)
  return [202, { ok: true, from: who.from }]
}

function events({ res, who, hub }) {
  if (hub.size() >= MAX_STREAMS) throw new Problem(503, 'too_many_streams', 'too many open event streams')
  res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store', 'X-Accel-Buffering': 'no', 'X-Content-Type-Options': 'nosniff' })
  hub.add(res, who)
}

// Writes come from other processes as well as this server, so the files are what is watched.
function snapshot() {
  const out = new Map()
  const scan = (dir, valid, kind, files) => {
    let names = []
    try { names = fs.readdirSync(dir) } catch {}
    for (const n of names) {
      if (!valid(n)) continue
      const stamp = files.map((f) => {
        const s = fs.statSync(path.join(dir, n, f), { throwIfNoEntry: false })
        return s ? `${s.mtimeMs}:${s.size}` : ''
      }).join(';')
      if (stamp.replace(/;/g, '')) out.set(`${kind} ${n}`, stamp)
    }
  }
  scan(QUEUE, validId, 'item', ['item.json'])
  scan(THREADS, validThread, 'thread', ['thread.json', 'chat.jsonl'])
  return out
}

function createHub() {
  const streams = new Set()
  let last = new Map()
  let timer = null
  let ticks = 0
  const stop = () => { clearInterval(timer); timer = null }
  const tick = () => {
    const next = snapshot()
    const changed = [...next].filter(([k, v]) => last.get(k) !== v).map(([k]) => k.split(' '))
    last = next
    ticks++
    for (const s of [...streams]) {
      if (s.who.token && !stillValid(s.who.token)) { s.res.end(); streams.delete(s); continue }
      for (const [kind, id] of changed) s.res.write(`event: ${kind}.changed\ndata: ${JSON.stringify({ id })}\n\n`)
      if (ticks % 25 === 0) s.res.write(': keep-alive\n\n')
    }
    if (!streams.size) stop()
  }
  return {
    size: () => streams.size,
    close: () => { if (timer) stop() },
    add(res, who) {
      if (!timer) {
        last = snapshot()
        timer = setInterval(tick, 1000)
        timer.unref()
      }
      const stream = { res, who }
      streams.add(stream)
      res.on('close', () => streams.delete(stream))
      res.write('event: ready\ndata: {}\n\n')
    },
  }
}

export const ROUTES = [
  { method: 'GET', path: '/api/v1/schema', scope: 'read', run: () => [200, JSON.parse(fs.readFileSync(SCHEMA, 'utf8'))] },
  { method: 'GET', path: '/api/v1/items', scope: 'read', run: listItems },
  { method: 'POST', path: '/api/v1/items', scope: 'write', run: createItem },
  { method: 'GET', path: '/api/v1/items/{item}', scope: 'read', run: ({ params }) => [200, readItem(params.item)] },
  { method: 'POST', path: '/api/v1/items/{item}/decide', scope: 'decide', run: ({ params, body, who }) => [200, decide(params.item, body.verdict, body.note, who.via, body.text)] },
  { method: 'GET', path: '/api/v1/items/{item}/media/{file}', scope: 'read', run: media },
  { method: 'GET', path: '/api/v1/threads', scope: 'read', run: listThreads },
  { method: 'GET', path: '/api/v1/threads/{thread}', scope: 'read', run: getThread },
  { method: 'POST', path: '/api/v1/threads/{thread}/say', scope: 'write', run: say },
  { method: 'GET', path: '/api/v1/agents', scope: 'read', run: listAgents },
  { method: 'POST', path: '/api/v1/agents/{agent}/messages', scope: 'write', run: tell },
  { method: 'GET', path: '/api/v1/events', scope: 'read', run: events },
]

const PARAM = { item: 'q\\d{1,6}', thread: 't\\d{1,6}', agent: '[a-z0-9][a-z0-9_-]{0,47}', file: '[^/]+' }
const compiled = ROUTES.map((r) => ({ ...r, re: new RegExp(`^${r.path.replace(/\{(\w+)\}/g, (_, n) => `(?<${n}>${PARAM[n]})`)}$`) }))

function classify(err) {
  if (err instanceof Problem) return [err.status, err.code, err.message]
  if (err instanceof UsageError) return [400, 'bad_request', err.message]
  if (err instanceof Refused) return [403, 'refused', err.message]
  if (/^no (queue item|conversation)/.test(err.message)) return [404, 'not_found', err.message]
  if (/is already /.test(err.message)) return [409, 'conflict', err.message]
  process.stderr.write(`fraim-queue: api: ${err.message}\n`)
  return [500, 'internal', 'internal error']
}

function preflight(req, res) {
  const origin = req.headers.origin
  if (origin && originListed(origin)) {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': origin, Vary: 'Origin', 'Access-Control-Allow-Methods': 'GET, POST',
      'Access-Control-Allow-Headers': 'Authorization, Content-Type', 'Access-Control-Max-Age': '600',
    })
  } else res.writeHead(204)
  res.end()
}

export function createApi({ isPageCookie, send }) {
  const hub = createHub()
  async function handle(req, res, url) {
    try {
      if (req.method === 'OPTIONS') return preflight(req, res)
      const who = identify(req, isPageCookie)
      const origin = req.headers.origin
      if (who.token && origin) {
        if (!who.token.origins.includes(origin)) throw new Problem(403, 'origin_not_allowed', 'this token does not list that origin')
        res.setHeader('Access-Control-Allow-Origin', origin)
        res.setHeader('Vary', 'Origin')
      }
      const route = compiled.find((r) => r.method === req.method && r.re.test(url.pathname))
      if (!route) throw new Problem(404, 'not_found', 'not found')
      if (who.token && !allows(who.token.scope, route.scope)) throw new Problem(403, 'insufficient_scope', `this needs a token with the ${route.scope} scope`)
      if (who.cookie && req.method === 'POST' && req.headers['x-fraim-queue'] !== '1') throw new Problem(403, 'missing_header', 'missing header')
      const body = req.method === 'POST' ? await readJson(req) : undefined
      const out = await route.run({ req, res, url, who, body, hub, params: route.re.exec(url.pathname).groups })
      if (out) send(res, out[0], out[1])
    } catch (err) {
      if (res.headersSent) return res.destroy()
      const [status, code, message] = classify(err)
      if (status === 401) {
        res.setHeader('WWW-Authenticate', 'Bearer')
        if (req.headers.origin && originListed(req.headers.origin)) {
          res.setHeader('Access-Control-Allow-Origin', req.headers.origin)
          res.setHeader('Vary', 'Origin')
        }
      }
      if (status === 413) {
        res.setHeader('Connection', 'close')
        res.on('finish', () => req.destroy())
      }
      send(res, status, { error: message, code })
    }
  }
  return { handle, close: hub.close }
}
