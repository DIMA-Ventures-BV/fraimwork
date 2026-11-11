// The web server: the settings page, the owner's own pages (/p/NAME) and /api/v1.
// Questions reach the owner in chat, so there is no inbox page.
import crypto from 'node:crypto'
import fs from 'node:fs'
import http from 'node:http'
import path from 'node:path'
import { createSettings } from './fraim-settings.mjs'
import { HOME, UsageError, readText, runtimeEnv, token, tool, usage } from './fraim-queue-store.mjs'
import { createApi, readJson } from './fraim-queue-api.mjs'
import { askChatAgent, employees, ownerChat, team } from './fraim-queue-views.mjs'

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

const readBody = (req) => readJson(req, 100000)

export function createServer(secret = token()) {
  const settings = createSettings({ employees, team, tool, runtimeEnv, send, readBody })
  const api = createApi({ isPageCookie: (req) => sameToken(cookieToken(req), secret), send })
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://queue')
    try {
      if (url.pathname === '/health') return send(res, 200, { ok: true })
      if (url.pathname.startsWith('/api/v1/')) return await api.handle(req, res, url)
      if (url.searchParams.has('t')) {
        if (!sameToken(url.searchParams.get('t'), secret)) return send(res, 403, 'Wrong link. Ask the chief for your settings link again.', 'text/plain')
        res.writeHead(303, {
          Location: '/',
          'Set-Cookie': `fraim_queue=${secret}; HttpOnly; SameSite=Strict; Path=/; Max-Age=31536000`,
        })
        return res.end()
      }
      if (!sameToken(cookieToken(req), secret)) {
        return send(res, 401, 'Open the settings with the link that includes ?t=. Ask the chief: "give me my settings link".', 'text/plain')
      }
      if (req.method === 'GET' && url.pathname === '/') {
        res.writeHead(303, { Location: '/settings' })
        return res.end()
      }
      if (await settings.handle(req, res, url)) return
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
      return send(res, 404, { error: 'not found' })
    } catch (err) {
      const code = err.status || (err instanceof UsageError ? 400 : /^no queue item|already/.test(err.message) ? 409 : 500)
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
