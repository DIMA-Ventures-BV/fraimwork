// One shape for every way a message reaches the server or leaves it. A channel is one entry in
// CHANNELS plus a small service next to it (the WhatsApp gateway, the mail sender in the google
// container). See docs/channels.md.
//
//   fraim-channels list                 every channel and how it is doing
//   fraim-channels check CHANNEL        exit 1 when a channel that should work does not
//   fraim-channels seen CHANNEL ID      exit 0 the first time, 10 for a repeat
//   fraim-channels listen [--once]      run the triggers that were switched on; none by default
import { execFile } from 'node:child_process'
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'

const STALE_MS = 10 * 60 * 1000
const CLAIMS_KEPT_MS = 30 * 24 * 3600 * 1000
const DUPLICATE = 10

const stateDir = () => path.join(process.env.HOME || '/home/claude', '.local/state/fraim/channels')

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

// target: who an answer goes to, worked out from the conversation and never from an agent.
// reply:  what the service needs to send one approved text.
// inbound: the channel reports through POST /events. A new message starts nothing by itself:
//          trigger names what runs, and without one nobody follows the channel.
export const CHANNELS = [
  {
    id: 'email',
    word: 'email',
    module: 'google',
    base: (env) => env.FRAIM_REPLY_MAIL_URL || 'http://google:8001',
    conversation: (key) => /^gmail:([\w-]{6,64})$/.exec(key)?.[1],
    async target(threadId, _thread, call) {
      const who = await call('/who', { thread_id: threadId })
      return { to: who.to, name: who.name || who.to, subject: who.subject, gmail_thread: threadId }
    },
    reply: (r) => ({ thread_id: r.gmail_thread, to: r.to, text: r.text }),
    status: (env, call) => call('/status', {}),
    healthy: (s, now) => !s.signed_in || (Boolean(s.last_check) && now - s.last_check * 1000 < STALE_MS),
    describe: (s) => (s.signed_in ? `signed in, new mail by ${s.mode === 'push' ? 'Google push' : 'a check every 30 seconds'}` : 'not signed in'),
    inbound: true,
    trigger: (env) => env.FRAIM_MAIL_AUTOMATION || '',
    // Only the Thread IDs go to the agent. The automation judges the mail and reads it as data.
    handoff(events, { env, run, log }) {
      const name = env.FRAIM_MAIL_AUTOMATION
      if (!fs.existsSync(path.join(env.HOME || '', 'fraim/automations', name, 'automation.md'))) {
        log(`new mail, but there is no automation ${name} to read it`)
        return Promise.resolve()
      }
      const threads = [...new Set(events.map((e) => e.thread))].filter((t) => /^[\w-]{6,64}$/.test(t || ''))
      if (!threads.length) return Promise.resolve()
      return run('fraim-auto', ['run', name, '--input', threads.join(' ')])
    },
  },
  {
    id: 'whatsapp',
    word: 'WhatsApp',
    module: 'whatsapp',
    base: (env) => env.FRAIM_GATEWAY_URL,
    conversation: (key) => /^whatsapp:(\d{8,15})$/.exec(key)?.[1],
    async target(phone, thread, call) {
      await call('/reply/check', { to: phone })
      return { to: phone, name: thread.who || `+${phone}`, subject: '' }
    },
    reply: (r) => ({ to: r.to, text: r.text }),
    status: (env) => request(`${env.FRAIM_GATEWAY_URL}/status`, { method: 'GET', token: env.FRAIM_GATEWAY_TOKEN }),
    healthy: (s) => Boolean(s.connected),
    describe: (s) => (s.connected ? 'connected' : s.waitingForQr ? 'waiting for the phone to link' : 'not connected'),
  },
]

const channelById = (id) => CHANNELS.find((c) => c.id === id)
export const channelWord = (id) => channelById(id)?.word || id
const isOn = (c, env) => `,${env.FRAIM_MODULES || ''},`.includes(`,${c.module},`)

async function request(url, { method = 'POST', token, body, timeout = 25000 }) {
  const r = await fetch(url, {
    method,
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    ...(method === 'POST' ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(timeout),
  })
  const out = await r.json().catch(() => ({}))
  if (!r.ok) throw new Error(out.error || `the sender answered ${r.status}`)
  return out
}

function caller(channel, env, timeout) {
  const base = channel.base(env)
  if (!env.FRAIM_REPLY_TOKEN || !base) throw new Error('sending replies is not set up on this server; run fraim update')
  return (route, body) => request(`${base}${route}`, { token: env.FRAIM_REPLY_TOKEN, body, timeout })
}

// null when this conversation has nobody to answer.
export async function replyTarget(thread, env) {
  for (const channel of CHANNELS) {
    const id = channel.conversation(thread.key)
    if (id) return { channel: channel.id, ...await channel.target(id, thread, caller(channel, env)) }
  }
  return null
}

export function sendReply(reply, env) {
  const channel = channelById(reply.channel)
  if (!channel) throw new Error(`there is no channel ${reply.channel}`)
  return caller(channel, env)('/reply', channel.reply(reply))
}

function forgetOldClaims(folder, now) {
  const marker = path.join(folder, '.pruned')
  try {
    if (now - fs.statSync(marker).mtimeMs < 24 * 3600 * 1000) return
  } catch {}
  fs.writeFileSync(marker, '')
  for (const name of fs.readdirSync(folder)) {
    if (name === '.pruned') continue
    const file = path.join(folder, name)
    try {
      if (now - fs.statSync(file).mtimeMs > CLAIMS_KEPT_MS) fs.rmSync(file, { force: true })
    } catch {}
  }
}

// True the first time. One file per message, so two processes can never both win.
export function claim(channel, id, dir = stateDir(), now = Date.now()) {
  if (!id) return true
  const folder = path.join(dir, 'seen', channel.replace(/[^\w-]/g, '_'))
  fs.mkdirSync(folder, { recursive: true })
  const file = path.join(folder, crypto.createHash('sha256').update(String(id)).digest('hex').slice(0, 40))
  try {
    fs.closeSync(fs.openSync(file, 'wx'))
  } catch (err) {
    if (err.code === 'EEXIST') return false
    throw err
  }
  forgetOldClaims(folder, now)
  return true
}

function readCursor(file) {
  try {
    return Number.parseInt(fs.readFileSync(file, 'utf8'), 10) || 0
  } catch {
    return 0
  }
}

function saveCursor(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true })
  fs.writeFileSync(`${file}.tmp`, `${value}\n`)
  fs.renameSync(`${file}.tmp`, file)
}

function runner(log) {
  return (command, args) => new Promise((resolve) => {
    execFile(command, args, { timeout: 20 * 60 * 1000 }, (err) => {
      if (err) log(`${command} ${args[0]} failed: ${err.message}`)
      resolve()
    })
  })
}

// At least once: the cursor moves after the handoff, and claim() drops what comes back.
async function follow(channel, { env, log, once }) {
  const file = path.join(stateDir(), `${channel.id}.cursor`)
  const gapMs = once ? 0 : Number(env.FRAIM_CHANNEL_GAP_MS || 60000)
  const call = caller(channel, env, 40000)
  const run = runner(log)
  let reading = readCursor(file)
  let pending = []
  let lastHandoff = 0
  for (;;) {
    try {
      const out = await call('/events', { after: reading, wait: once ? 0 : 25 })
      const last = Number(out.last) || 0
      if (reading > last) {
        reading = 0
        saveCursor(file, 0)
        continue
      }
      pending.push(...(out.events || []))
      reading = pending.reduce((top, e) => Math.max(top, Number(e.seq) || 0), reading)
      if (pending.length && Date.now() - lastHandoff >= gapMs) {
        const fresh = pending.filter((e) => claim(channel.id, e.id))
        pending = []
        lastHandoff = Date.now()
        if (fresh.length) {
          const done = channel.handoff(fresh, { env, run, log })
          if (once) await done
        }
        saveCursor(file, reading)
      }
      if (once) return 0
    } catch (err) {
      log(`${channel.id}: ${err.message}`)
      if (once) return 1
      await new Promise((resolve) => setTimeout(resolve, 5000))
    }
  }
}

export async function listen({ once = false, env = runtimeEnv(), log = (line) => process.stderr.write(`fraim-channels: ${line}\n`) } = {}) {
  const sources = CHANNELS.filter((c) => c.inbound && isOn(c, env) && c.trigger(env))
  const results = await Promise.all(sources.map((channel) => follow(channel, { env, log, once })))
  return results.some(Boolean) ? 1 : 0
}

async function statusOf(channel, env) {
  if (!isOn(channel, env)) return { on: false, ok: true, text: 'off' }
  try {
    const status = await channel.status(env, caller(channel, env, 10000))
    return { on: true, ok: channel.healthy(status, Date.now()), text: channel.describe(status) }
  } catch (err) {
    return { on: true, ok: false, text: err.message }
  }
}

export async function main(args) {
  const [command, first, second] = args
  const env = runtimeEnv()
  if (command === 'seen' && first && second) return claim(first, second) ? 0 : DUPLICATE
  if (command === 'listen') return listen({ once: args.includes('--once'), env })
  if (command === 'list') {
    for (const channel of CHANNELS) {
      const s = await statusOf(channel, env)
      console.log(`${channel.id.padEnd(10)} ${s.ok ? (s.on ? 'ok' : '-') : 'FAIL'}  ${s.text}`)
    }
    return 0
  }
  if (command === 'check' && channelById(first)) {
    const s = await statusOf(channelById(first), env)
    if (!s.ok) console.error(`${first}: ${s.text}`)
    return s.ok ? 0 : 1
  }
  console.error('usage: fraim-channels list | check CHANNEL | seen CHANNEL ID | listen [--once]')
  return 2
}
