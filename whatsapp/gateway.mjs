// fraim WhatsApp gateway: one linked-device session, a sender allowlist, and a
// token-protected HTTP API on the internal Docker network.
//   GET  /health            no auth, for Docker
//   GET  /status            { connected, me, waitingForQr }
//   GET  /events            SSE stream of allowed inbound messages
//   POST /send              { chat_id | to, text }
//   POST /send-file         { chat_id | to, path: "fraim/..." | "pc/...", caption }
//   POST /reply             { to, text } an approved reply to a contact (REPLY_TOKEN, not GATEWAY_TOKEN)
//   POST /reply/check       { to } is this number a contact (REPLY_TOKEN)
//   POST /pair              { number } -> { code } pairing code for "Link with phone number"
//   GET  /qr.png            current linking QR code as PNG (404 when linked)
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import http from 'node:http'
import path from 'node:path'
import makeWASocket, {
  Browsers,
  DisconnectReason,
  downloadMediaMessage,
  fetchLatestBaileysVersion,
  useMultiFileAuthState,
} from 'baileys'
import pino from 'pino'
import QRCode from 'qrcode'
import qrcode from 'qrcode-terminal'
import {
  allowedSender,
  contactChat,
  contactSender,
  digits,
  httpError,
  isGroupOrBroadcast,
  parseAllowlist,
  parseContacts,
  resolveChat as resolveChatFor,
  resolveSharedPath,
} from './lib.mjs'

const PORT = Number(process.env.PORT || 8080)
const TOKEN = process.env.GATEWAY_TOKEN || ''
const AUTH_DIR = process.env.AUTH_DIR || '/data/auth'
const QR_FILE = '/data/qr.png'
// The gateway sees ~/fraim read-only; only its inbox is writable. downloads and inbox are
// separate volumes, mounted next to /fraim (a writable mount cannot sit inside a read-only one).
const ROOTS = { fraim: '/fraim', pc: '/pc', 'fraim/inbox': '/inbox', 'fraim/downloads': '/downloads' }
const INBOX = '/inbox'
const MAX_TEXT = 4000
const QUEUE_LIMIT = 100

const OWNER = digits(process.env.WHATSAPP_OWNER)
const ALLOW = parseAllowlist(OWNER, process.env.WHATSAPP_ALLOW)
const CONTACTS = parseContacts(process.env.WHATSAPP_CONTACTS)
const REPLY_TOKEN = process.env.REPLY_TOKEN || ''

const logger = pino({ level: process.env.LOG_LEVEL || 'info' })
const waLogger = logger.child({ module: 'baileys' })
waLogger.level = 'warn'

if (!TOKEN) {
  logger.fatal('GATEWAY_TOKEN is empty; refusing to start')
  process.exit(1)
}
for (const number of ALLOW) {
  if (number.startsWith('0') || number.length < 10 || number.length > 15) {
    logger.error({ number }, 'not an international number (use 31612345678, without + or 00); messages from it will never match')
  }
}
if (ALLOW.size === 0) logger.warn('WHATSAPP_OWNER and WHATSAPP_ALLOW are empty; every message is dropped')

let sock = null
let connected = false
let waitingForQr = false
const listeners = new Set()
const queue = []
const knownChats = new Set([...ALLOW].map((d) => `${d}@s.whatsapp.net`))
const lastQueuedNotice = new Map()

function unwrap(message) {
  let m = message
  while (m?.ephemeralMessage || m?.viewOnceMessage || m?.viewOnceMessageV2 || m?.documentWithCaptionMessage) {
    m = (m.ephemeralMessage || m.viewOnceMessage || m.viewOnceMessageV2 || m.documentWithCaptionMessage).message
  }
  return m || {}
}

function emit(event) {
  if (listeners.size === 0) {
    queue.push(event)
    if (queue.length > QUEUE_LIMIT) queue.shift()
    return false
  }
  const frame = `data: ${JSON.stringify(event)}\n\n`
  for (const res of listeners) res.write(frame)
  return true
}

const resolveChat = (body) => resolveChatFor(body, knownChats, ALLOW)

async function sendText(jid, text) {
  if (!connected) throw httpError(503, 'WhatsApp is not connected')
  for (let i = 0; i < text.length || i === 0; i += MAX_TEXT) {
    await sock.sendMessage(jid, { text: text.slice(i, i + MAX_TEXT) })
  }
}

const MIME = {
  '.pdf': 'application/pdf', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.webp': 'image/webp', '.gif': 'image/gif', '.txt': 'text/plain', '.md': 'text/markdown',
  '.csv': 'text/csv', '.json': 'application/json', '.zip': 'application/zip',
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.mp3': 'audio/mpeg', '.mp4': 'video/mp4',
}

async function sendFile(jid, sharedPath, caption) {
  if (!connected) throw httpError(503, 'WhatsApp is not connected')
  const absolute = await resolveSharedPath(sharedPath, ROOTS)
  const data = await readFile(absolute)
  const fileName = path.basename(absolute)
  const mimetype = MIME[path.extname(fileName).toLowerCase()] || 'application/octet-stream'
  const content = mimetype.startsWith('image/') && mimetype !== 'image/gif'
    ? { image: data, caption }
    : { document: data, mimetype, fileName, caption }
  await sock.sendMessage(jid, content)
}

async function saveMedia(msg, inner) {
  const media = inner.imageMessage || inner.documentMessage || inner.audioMessage || inner.videoMessage
  if (!media) return null
  const buffer = await downloadMediaMessage(msg, 'buffer', {}, {
    logger: waLogger,
    reuploadRequest: sock.updateMediaMessage,
  })
  const ext = media.fileName
    ? path.extname(media.fileName)
    : `.${String(media.mimetype || 'bin').split('/')[1].split(';')[0]}`
  const base = media.fileName ? path.basename(media.fileName, ext).replace(/[^\w.-]+/g, '_') : 'attachment'
  const name = `${new Date().toISOString().replace(/[:.]/g, '-')}-${base}${ext}`
  await mkdir(INBOX, { recursive: true })
  await writeFile(path.join(INBOX, name), buffer)
  return `~/fraim/inbox/${name}`
}

async function onMessage(msg) {
  const key = msg.key || {}
  if (key.fromMe || !key.remoteJid || isGroupOrBroadcast(key.remoteJid)) return

  const contact = contactSender(key, ALLOW, CONTACTS)
  if (contact) {
    const said = unwrap(msg.message)
    emit({
      type: 'contact',
      id: key.id,
      sender: contact,
      name: msg.pushName || '',
      text: said.conversation || said.extendedTextMessage?.text || said.imageMessage?.caption || said.documentMessage?.caption || said.videoMessage?.caption || '[sent a file or a voice message]',
      ts: Number(msg.messageTimestamp || 0),
    })
    return
  }

  const phone = allowedSender(key, ALLOW)
  if (!phone) {
    logger.info({ jid: key.remoteJid }, 'dropped message from a sender not on the allowlist')
    return
  }
  knownChats.add(key.remoteJid)

  const inner = unwrap(msg.message)
  let text = inner.conversation || inner.extendedTextMessage?.text || ''
  const caption = inner.imageMessage?.caption || inner.documentMessage?.caption || inner.videoMessage?.caption
  if (caption) text = text ? `${text}\n${caption}` : caption

  try {
    const saved = await saveMedia(msg, inner)
    if (saved) text = `${text}\n[attachment saved to ${saved}]`.trim()
  } catch (err) {
    logger.warn({ err: err.message }, 'could not download attachment')
    text = `${text}\n[an attachment could not be downloaded]`.trim()
  }
  if (!text) return

  await sock.readMessages([key]).catch(() => {})
  const delivered = emit({
    type: 'message',
    id: key.id,
    chat_id: key.remoteJid,
    sender: phone,
    name: msg.pushName || '',
    text,
    ts: Number(msg.messageTimestamp || 0),
  })

  if (!delivered) {
    const last = lastQueuedNotice.get(key.remoteJid) || 0
    if (Date.now() - last > 10 * 60 * 1000) {
      lastQueuedNotice.set(key.remoteJid, Date.now())
      await sendText(key.remoteJid, 'Claude is not running right now. Your message is queued and will be handled when it is back.').catch(() => {})
    }
  }
}

async function connect() {
  const { state, saveCreds } = await useMultiFileAuthState(AUTH_DIR)
  const { version } = await fetchLatestBaileysVersion().catch(() => ({ version: undefined }))

  sock = makeWASocket({
    auth: state,
    version,
    logger: waLogger,
    browser: Browsers.ubuntu('fraim'),
    markOnlineOnConnect: false,
    syncFullHistory: false,
  })

  sock.ev.on('creds.update', saveCreds)

  sock.ev.on('connection.update', ({ connection, lastDisconnect, qr }) => {
    if (qr) {
      waitingForQr = true
      logger.info('Scan this QR code: WhatsApp Business > Settings > Linked devices > Link a device')
      qrcode.generate(qr, { small: true }, (code) => process.stdout.write(`\n${code}\n`))
      QRCode.toFile(QR_FILE, qr, { width: 512, margin: 2 }).catch((err) =>
        logger.warn({ err: err.message }, 'could not write QR PNG'))
    }
    if (connection === 'open') {
      connected = true
      waitingForQr = false
      rm(QR_FILE, { force: true }).catch(() => {})
      logger.info({ me: sock.user?.id }, 'WhatsApp connected')
    }
    if (connection === 'close') {
      connected = false
      const code = lastDisconnect?.error?.output?.statusCode
      if (code === DisconnectReason.loggedOut) {
        logger.error('WhatsApp logged this device out. Run "fraim whatsapp relink" and scan a new QR code.')
        return
      }
      logger.warn({ code }, 'WhatsApp connection closed; reconnecting')
      setTimeout(() => connect().catch((err) => logger.error({ err: err.message }, 'reconnect failed')), 3000)
    }
  })

  sock.ev.on('messages.upsert', async ({ messages, type }) => {
    if (type !== 'notify') return
    for (const msg of messages) {
      await onMessage(msg).catch((err) => logger.error({ err: err.message }, 'message handling failed'))
    }
  })
}

async function readJson(req) {
  let raw = ''
  for await (const chunk of req) {
    raw += chunk
    if (raw.length > 1_000_000) throw httpError(413, 'body too large')
  }
  try {
    return JSON.parse(raw || '{}')
  } catch {
    throw httpError(400, 'invalid JSON')
  }
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://gateway')
  const reply = (status, body) => {
    res.writeHead(status, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify(body))
  }

  if (url.pathname === '/health') return reply(200, { ok: true })
  const replyRoute = url.pathname === '/reply' || url.pathname === '/reply/check'
  const allowed = replyRoute ? Boolean(REPLY_TOKEN) && req.headers.authorization === `Bearer ${REPLY_TOKEN}` : req.headers.authorization === `Bearer ${TOKEN}`
  if (!allowed) return reply(401, { error: 'unauthorized' })

  try {
    if (req.method === 'POST' && replyRoute) {
      const body = await readJson(req)
      const jid = contactChat(body.to, CONTACTS)
      if (url.pathname === '/reply') {
        if (!body.text) throw httpError(400, 'text is required')
        await sendText(jid, String(body.text))
      }
      return reply(200, { ok: true })
    }
    if (req.method === 'GET' && url.pathname === '/status') {
      return reply(200, { connected, waitingForQr, me: sock?.user?.id || null, queued: queue.length, listeners: listeners.size })
    }
    if (req.method === 'GET' && url.pathname === '/events') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' })
      res.write(': connected\n\n')
      listeners.add(res)
      while (queue.length) res.write(`data: ${JSON.stringify(queue.shift())}\n\n`)
      const ping = setInterval(() => res.write(': ping\n\n'), 25000)
      req.on('close', () => {
        clearInterval(ping)
        listeners.delete(res)
      })
      return
    }
    if (req.method === 'POST' && url.pathname === '/send') {
      const body = await readJson(req)
      if (!body.text) throw httpError(400, 'text is required')
      await sendText(resolveChat(body), String(body.text))
      return reply(200, { ok: true })
    }
    if (req.method === 'GET' && url.pathname === '/qr.png') {
      if (connected) throw httpError(409, 'already linked')
      const png = await readFile(QR_FILE).catch(() => null)
      if (!png) throw httpError(404, 'no QR code yet; try again in a few seconds')
      res.writeHead(200, { 'Content-Type': 'image/png' })
      return res.end(png)
    }
    if (req.method === 'POST' && url.pathname === '/pair') {
      const body = await readJson(req)
      const number = digits(body.number)
      if (!number) throw httpError(400, 'number is required (the agent phone number, digits only)')
      if (connected || sock?.authState?.creds?.registered) throw httpError(409, 'already linked')
      for (let i = 0; i < 30 && !waitingForQr; i++) await new Promise((r) => setTimeout(r, 500))
      if (!sock) throw httpError(503, 'WhatsApp socket is not ready; try again')
      const code = await sock.requestPairingCode(number)
      return reply(200, { code: code?.match(/.{1,4}/g)?.join('-') ?? code })
    }
    if (req.method === 'POST' && url.pathname === '/send-file') {
      const body = await readJson(req)
      await sendFile(resolveChat(body), body.path, String(body.caption || ''))
      return reply(200, { ok: true })
    }
    return reply(404, { error: 'not found' })
  } catch (err) {
    return reply(err.status || 500, { error: err.message })
  }
})

server.listen(PORT, '0.0.0.0', () => logger.info({ port: PORT, allowlist: ALLOW.size }, 'gateway listening'))
connect().catch((err) => {
  logger.fatal({ err: err.message }, 'could not start WhatsApp')
  process.exit(1)
})

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    server.close()
    sock?.end?.(undefined)
    process.exit(0)
  })
}
