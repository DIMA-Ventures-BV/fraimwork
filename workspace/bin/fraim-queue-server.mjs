// The web server: the shipped pages and the routes they use.
import crypto from 'node:crypto'
import fs from 'node:fs'
import http from 'node:http'
import path from 'node:path'
import { createSettings } from './fraim-settings.mjs'
import {
  HOME, MEDIA_TYPES, UsageError, allItems, itemDir, now, promptText, rank, readItem, readText, readThread, runtimeEnv,
  token, tool, usage, writeThread,
} from './fraim-queue-store.mjs'
import { createApi } from './fraim-queue-api.mjs'
import { decide, setPriority } from './fraim-queue-approve.mjs'
import { dismissThread, restoreThread, sayInThread, tellContact } from './fraim-queue-threads.mjs'
import {
  active, agentScreen, agentSend, askChatAgent, employees, ownerChat, inboxRows, member, team, threadDetail,
} from './fraim-queue-views.mjs'

function sameToken(a, b) {
  const x = Buffer.from(String(a || ''))
  const y = Buffer.from(String(b || ''))
  return x.length === y.length && crypto.timingSafeEqual(x, y)
}

function cookieToken(req) {
  const m = /(?:^|;\s*)fraim_queue=([^;]+)/.exec(req.headers.cookie || '')
  return m ? m[1] : ''
}

function send(res, code, body, type = 'application/json') {
  res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer' })
  res.end(type === 'application/json' ? JSON.stringify(body) : body)
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = ''
    req.on('data', (c) => {
      data += c
      if (data.length > 100000) reject(new Error('request too large'))
    })
    req.on('end', () => {
      try { resolve(data ? JSON.parse(data) : {}) } catch { reject(new Error('invalid JSON')) }
    })
  })
}

export function createServer(secret = token()) {
  const settings = createSettings({ employees, team, tool, runtimeEnv, send, readBody })
  const api = createApi({ isPageCookie: (req) => sameToken(cookieToken(req), secret), send })
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://queue')
    try {
      if (url.pathname === '/health') return send(res, 200, { ok: true })
      if (url.pathname.startsWith('/api/v1/')) return await api.handle(req, res, url)
      if (url.searchParams.has('t')) {
        if (!sameToken(url.searchParams.get('t'), secret)) return send(res, 403, 'Wrong link. Ask Claude for the queue link again.', 'text/plain')
        res.writeHead(303, {
          Location: '/',
          'Set-Cookie': `fraim_queue=${secret}; HttpOnly; SameSite=Strict; Path=/; Max-Age=31536000`,
        })
        return res.end()
      }
      if (!sameToken(cookieToken(req), secret)) {
        return send(res, 401, 'Open the queue with the link that includes ?t=. Ask Claude: "give me my queue link".', 'text/plain')
      }
      if (req.method === 'GET' && url.pathname === '/') return send(res, 200, uiPage('inbox', url.searchParams.has('builtin')), 'text/html; charset=utf-8')
      if (await settings.handle(req, res, url)) return
      if (req.method === 'GET' && url.pathname === '/team') return send(res, 200, uiPage('team', url.searchParams.has('builtin')), 'text/html; charset=utf-8')
      if (req.method === 'GET' && url.pathname === '/settings') return send(res, 200, uiPage('settings', url.searchParams.has('builtin')), 'text/html; charset=utf-8')
      if (req.method === 'GET' && /^\/p\/[a-z0-9][a-z0-9-]{0,39}$/.test(url.pathname)) {
        const extra = uiPage(url.pathname.slice(3))
        return extra.trim() ? send(res, 200, extra, 'text/html; charset=utf-8') : send(res, 404, { error: 'no such page' })
      }
      if (req.method === 'GET' && url.pathname === '/api/chief') return send(res, 200, ownerChat())
      if (req.method === 'POST' && url.pathname === '/api/chief/say') {
        if (req.headers['x-fraim-queue'] !== '1') return send(res, 403, { error: 'missing header' })
        const text = String((await readBody(req)).text || '').trim()
        if (!text) usage('write a message first')
        askChatAgent(text)
        return send(res, 200, { ok: true })
      }
      if (req.method === 'GET' && url.pathname === '/api/employees') return send(res, 200, employees())
      if (req.method === 'GET' && url.pathname === '/api/threads') return send(res, 200, inboxRows())
      const conv = /^\/api\/threads\/([tq]\d{1,6})(?:\/(seen|say|dismiss|restore))?$/.exec(url.pathname)
      if (conv && req.method === 'GET' && !conv[2]) return send(res, 200, threadDetail(conv[1]))
      if (conv && req.method === 'POST' && conv[2]) {
        if (req.headers['x-fraim-queue'] !== '1') return send(res, 403, { error: 'missing header' })
        const t = readThread(conv[1])
        if (conv[2] === 'dismiss' || conv[2] === 'restore') {
          if (conv[2] === 'dismiss') dismissThread(t)
          else restoreThread(t)
          return send(res, 200, { ok: true })
        }
        if (conv[2] === 'seen') {
          t.seen = now()
          writeThread(t)
          return send(res, 200, { ok: true })
        }
        const text = String((await readBody(req)).text || '').trim()
        if (!text) usage('write a message first')
        sayInThread(t.id, 'owner', '', text)
        tellContact(t, 'owner', promptText('thread-owner', { text }))
        return send(res, 200, { ok: true })
      }
      if (req.method === 'GET' && url.pathname === '/api/items') {
        const all = url.searchParams.get('all') === '1'
        return send(res, 200, rank(allItems().filter((i) => all || i.state === 'open')))
      }
      if (req.method === 'GET' && url.pathname === '/api/team') return send(res, 200, team())
      if (req.method === 'GET' && url.pathname === '/api/active') return send(res, 200, await active())
      const who = /^\/api\/member\/([a-z0-9][a-z0-9_-]{0,47})$/.exec(url.pathname)
      if (who && req.method === 'GET') {
        const m = member(who[1])
        return m ? send(res, 200, m) : send(res, 404, { error: 'no such lead or automation' })
      }
      const agent = /^\/api\/active\/([a-z0-9][a-z0-9_-]{0,47})\/(screen|send)$/.exec(url.pathname)
      if (agent && req.method === 'GET' && agent[2] === 'screen') return send(res, 200, await agentScreen(agent[1]))
      if (agent && req.method === 'POST' && agent[2] === 'send') {
        if (req.headers['x-fraim-queue'] !== '1') return send(res, 403, { error: 'missing header' })
        return send(res, 200, await agentSend(agent[1], (await readBody(req)).text))
      }
      const media = /^\/media\/(q\d{1,6})\/([^/]+)$/.exec(url.pathname)
      if (req.method === 'GET' && media) {
        const item = readItem(media[1])
        const name = decodeURIComponent(media[2])
        if (!item.media.includes(name)) return send(res, 404, { error: 'no such file' })
        const file = path.join(itemDir(item.id), 'media', name)
        const type = MEDIA_TYPES[path.extname(name).toLowerCase()] || 'application/octet-stream'
        res.writeHead(200, { 'Content-Type': type, 'Content-Length': fs.statSync(file).size, 'Cache-Control': 'private, max-age=3600' })
        return fs.createReadStream(file).pipe(res)
      }
      const action = /^\/api\/items\/(q\d{1,6})\/(decide|priority)$/.exec(url.pathname)
      if (req.method === 'POST' && action) {
        // A custom header: a form on another site cannot send it, so no cross-site posts.
        if (req.headers['x-fraim-queue'] !== '1') return send(res, 403, { error: 'missing header' })
        const body = await readBody(req)
        if (action[2] === 'priority') return send(res, 200, setPriority(action[1], body.priority))
        return send(res, 200, decide(action[1], body.verdict, body.note, 'page', body.text))
      }
      return send(res, 404, { error: 'not found' })
    } catch (err) {
      const code = err instanceof UsageError ? 400 : /^no queue item|already/.test(err.message) ? 409 : 500
      return send(res, code, { error: err.message })
    }
  })
  server.on('close', api.close)
  return server
}

// The pages are files the owner's chief can change (fraim-ui): the owner's file wins, and
// ?builtin=1 always shows the default, so a broken page can never lock the owner out.
const UI_DEFAULTS = process.env.FRAIM_UI_DEFAULTS || (() => {
  const checkout = process.argv[1] ? path.join(path.dirname(fs.realpathSync(process.argv[1])), '..', 'ui') : ''
  return checkout && fs.existsSync(checkout) ? checkout : '/etc/fraim/ui'
})()
const UI_OWNER = process.env.FRAIM_UI_DIR || path.join(HOME, 'fraim/ui')
const UI_MAX = 8000000

function uiPage(name, builtin) {
  if (!builtin) {
    const own = readText(path.join(UI_OWNER, `${name}.html`), UI_MAX)
    if (own.trim()) return own
  }
  return readText(path.join(UI_DEFAULTS, `${name}.html`), UI_MAX)
}
