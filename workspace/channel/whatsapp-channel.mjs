#!/usr/bin/env node
// Claude Code channel: forwards WhatsApp messages from the fraim gateway into the
// Claude session, exposes reply tools, and relays permission prompts to the owner.
import { execFile, execFileSync } from 'node:child_process'
import { readFileSync, realpathSync } from 'node:fs'
import { homedir } from 'node:os'
import path from 'node:path'
import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js'
import { z } from 'zod'
import { sessionCommandArgs } from './goal-command.mjs'
import { withContext } from './context.mjs'
import { Unanswered, lastAnswer } from './unanswered.mjs'
import { parseVerdict } from './verdict.mjs'
import { startedByMainSession } from './main-session.mjs'
import { inOrder, withTranscript } from './voice.mjs'

function loadEnvFile(file) {
  const out = {}
  try {
    for (const line of readFileSync(file, 'utf8').split('\n')) {
      const m = /^([A-Z_][A-Z0-9_]*)=(.*)$/.exec(line)
      if (!m) continue
      let value = m[2]
      if (value.startsWith("'") && value.endsWith("'")) value = value.slice(1, -1)
      out[m[1]] = value.replace(/\\(.)/g, '$1')
    }
  } catch {}
  return out
}

const env = { ...loadEnvFile('/etc/fraim/runtime.env'), ...process.env }
const GATEWAY = env.FRAIM_GATEWAY_URL
const TOKEN = env.FRAIM_GATEWAY_TOKEN
const OWNER = (env.WHATSAPP_OWNER || '').replace(/\D/g, '')
const VIEW_URL = env.FRAIM_BROWSER_VIEW_URL || 'the browser view'
const HOME = homedir()
const SHARED_ROOTS = { [path.join(HOME, 'fraim')]: 'fraim', [path.join(HOME, 'pc')]: 'pc' }

// Chats the owner wrote from; only these may run session_command.
const ownerChats = new Set()
// Messages without an answer on WhatsApp yet; they get a reminder into the session.
const unanswered = new Unanswered({ after: Number(env.FRAIM_REPLY_REMIND_MS) || 180000 })

const log = (...parts) => process.stderr.write(`[whatsapp-channel] ${parts.join(' ')}\n`)

// The owner's writing style for WhatsApp (fraim-style). Read per message, so a change
// applies to the next message; the rules go along only when they changed.
function replyStyle() {
  try {
    return execFileSync('fraim-style', ['prompt', 'whatsapp'], { encoding: 'utf8', timeout: 5000 }).trim()
  } catch {
    return ''
  }
}
let sentStyle = replyStyle()

// The owner can change this text: fraim-prompt own whatsapp.
function channelInstructions() {
  let display = ''
  try { display = execFileSync('fraim-lead', ['display'], { encoding: 'utf8', timeout: 5000 }).trim() } catch {}
  try {
    return execFileSync('fraim-prompt', ['render', 'whatsapp', '--set', `view_url=${VIEW_URL}`, '--set', `display=${display}`], { encoding: 'utf8', timeout: 5000 }).trim()
  } catch {
    return 'WhatsApp messages arrive as <channel source="whatsapp" chat_id="...">. Answer with the reply tool and pass the chat_id from the tag.'
  }
}

// The one WhatsApp conversation with the owner (fraim-relay log): the chief's pushes, the
// owner's messages and these replies, so every voice of the server knows what was said.
function logLine(who, chatId, text) {
  execFile('fraim-relay', ['log', who, '--chat', String(chatId || ''), '--', String(text || '')], { timeout: 10000 }, (err) => {
    if (err) log('could not log the conversation:', err.message)
  })
}

// What goes with every owner message: the conversation so far and the decisions that wait,
// so a "yes" or "unclear" is read against what the owner saw, never against old memory.
function ownerContext() {
  try {
    return execFileSync('fraim-relay', ['context'], { encoding: 'utf8', timeout: 10000 }).trim()
  } catch {
    return ''
  }
}

async function gateway(route, body) {
  const res = await fetch(`${GATEWAY}${route}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  const text = await res.text()
  if (!res.ok) throw new Error(`gateway ${route} failed (${res.status}): ${text}`)
  return text
}

function toSharedPath(file) {
  const absolute = realpathSync(path.resolve(HOME, 'fraim', file))
  for (const [root, name] of Object.entries(SHARED_ROOTS)) {
    if (absolute === root || absolute.startsWith(root + path.sep)) {
      return `${name}/${path.relative(root, absolute)}`
    }
  }
  throw new Error('only files under ~/fraim or ~/pc can be sent')
}

const mcp = new Server(
  { name: 'whatsapp', version: '0.1.0' },
  {
    capabilities: {
      experimental: { 'claude/channel': {}, 'claude/channel/permission': {} },
      tools: {},
    },
    instructions: channelInstructions() + (sentStyle ? `\n\n${sentStyle}` : ''),
  },
)

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'reply',
      description: 'Send a WhatsApp text message to a chat',
      inputSchema: {
        type: 'object',
        properties: {
          chat_id: { type: 'string', description: 'chat_id from the incoming <channel> tag' },
          text: { type: 'string', description: 'Message text' },
        },
        required: ['chat_id', 'text'],
      },
    },
    {
      name: 'send_file',
      description: 'Send a file from ~/fraim or ~/pc to a WhatsApp chat',
      inputSchema: {
        type: 'object',
        properties: {
          chat_id: { type: 'string', description: 'chat_id from the incoming <channel> tag' },
          path: { type: 'string', description: 'Absolute path, or a path relative to ~/fraim' },
          caption: { type: 'string', description: 'Optional caption' },
        },
        required: ['chat_id', 'path'],
      },
    },
    {
      name: 'session_command',
      description:
        'Run a Claude Code command in this always-on session after the current reply: clear (start fresh), compact (summarize the conversation, optional focus), or model (opus, sonnet, haiku, default). Only when the owner asks.',
      inputSchema: {
        type: 'object',
        properties: {
          command: { type: 'string', enum: ['clear', 'compact', 'model'] },
          argument: { type: 'string', description: 'compact: optional focus text; model: opus, sonnet, haiku or default' },
          chat_id: { type: 'string', description: 'chat_id of the owner message that asked for it (owner="yes")' },
        },
        required: ['command', 'chat_id'],
      },
    },
  ],
}))

mcp.setRequestHandler(CallToolRequestSchema, async (req) => {
  const args = req.params.arguments ?? {}
  try {
    if (req.params.name === 'reply') {
      await gateway('/send', { chat_id: String(args.chat_id), text: String(args.text) })
      unanswered.answered(args.chat_id)
      if (ownerChats.has(String(args.chat_id))) logLine('me', args.chat_id, args.text)
      return { content: [{ type: 'text', text: 'sent' }] }
    }
    if (req.params.name === 'send_file') {
      const shared = toSharedPath(String(args.path))
      await gateway('/send-file', { chat_id: String(args.chat_id), path: shared, caption: args.caption ?? '' })
      unanswered.answered(args.chat_id)
      return { content: [{ type: 'text', text: `sent ${shared}` }] }
    }
    if (req.params.name === 'session_command') {
      if (!ownerChats.has(String(args.chat_id ?? ''))) {
        throw new Error('session_command only runs for a WhatsApp chat where the owner wrote; pass that chat_id')
      }
      const result = await runTool('fraim-session-command', sessionCommandArgs(args))
      if (!result.ok) throw new Error(result.err || 'the command could not be queued')
      return { content: [{ type: 'text', text: result.out }] }
    }
    throw new Error(`unknown tool: ${req.params.name}`)
  } catch (err) {
    return { isError: true, content: [{ type: 'text', text: String(err.message ?? err) }] }
  }
})

const PermissionRequestSchema = z.object({
  method: z.literal('notifications/claude/channel/permission_request'),
  params: z.object({
    request_id: z.string(),
    tool_name: z.string(),
    description: z.string(),
    input_preview: z.string(),
  }),
})

mcp.setNotificationHandler(PermissionRequestSchema, async ({ params }) => {
  if (!OWNER) return
  // Never truncate: the approver must see the whole command. The gateway splits long text.
  const text = [
    `*Approval needed:* ${params.tool_name}`,
    params.description,
    '',
    params.input_preview,
    '',
    `Reply *yes ${params.request_id}* or *no ${params.request_id}*`,
  ].join('\n')
  try {
    await gateway('/send', { to: OWNER, text })
  } catch (err) {
    log('could not relay permission request:', err.message)
  }
})

// Reopening a closed session waits for Claude Code to start (up to 90 seconds).
function runTool(command, args, timeout = 30000) {
  return new Promise((resolve) => {
    execFile(command, args, { timeout }, (err, stdout, stderr) => {
      resolve({ ok: !err, out: String(stdout || '').trim(), err: String(stderr || err?.message || '').trim() })
    })
  })
}

// A long memo on a small server takes minutes; the engine waits up to 2 minutes for memory.
const TRANSCRIBE_TIMEOUT_MS = 17 * 60 * 1000

async function transcribe(file) {
  const result = await runTool('fraim-transcribe', [file], TRANSCRIBE_TIMEOUT_MS)
  if (result.ok) return result.out
  log('could not transcribe a voice message:', result.err)
  throw new Error(result.err)
}

async function handleEvent(event) {
  if (event.type === 'contact') {
    event = await withTranscript(event, transcribe)
    execFile('fraim-queue', ['thread', 'whatsapp', '--number', String(event.sender), '--name', String(event.name || ''), '--', String(event.text || '')], { timeout: 30000 }, (err) => {
      if (err) process.stderr.write(`fraim-channel: could not save a message from a contact: ${err.message}\n`)
    })
    return
  }
  if (event.type !== 'message') return
  const verdict = parseVerdict(event, OWNER)
  if (verdict) {
    await mcp.notification({ method: 'notifications/claude/channel/permission', params: verdict })
    return
  }
  event = await withTranscript(event, transcribe)
  const fromOwner = Boolean(OWNER) && event.sender === OWNER
  if (fromOwner) ownerChats.add(event.chat_id)
  let content = event.text || '(empty message)'
  if (fromOwner) {
    content = withContext(content, ownerContext())
    logLine('owner', event.chat_id, event.text || '(empty message)')
  }
  const style = replyStyle()
  if (style !== sentStyle) {
    content += `\n\n(The owner changed the reply style. ${style || 'No style rules now: answer as you normally would.'})`
    sentStyle = style
  }
  await mcp.notification({
    method: 'notifications/claude/channel',
    params: {
      content,
      meta: {
        chat_id: event.chat_id,
        sender: event.sender,
        name: event.name || '',
        message_id: event.id,
        owner: event.sender === OWNER ? 'yes' : 'no',
      },
    },
  })
  unanswered.received(event.chat_id, event.text, event.name)
}

// The herdr terminal this session runs in (the always-on session is "main").
const TERMINAL = env.FRAIM_TERMINAL || 'main'

async function sessionState() {
  const r = await runTool('hc', ['get', TERMINAL, '--json'], 10000)
  try { return JSON.parse(r.out)?.status?.state || '' } catch { return '' }
}

// After the reminders, the bridge sends what Claude wrote on its screen, so the owner always
// hears back. Without readable text it says the message arrived and is being looked at.
async function sendFallback(r) {
  const screen = await runTool('hc', ['read', TERMINAL, '--lines', '300'], 10000)
  const answer = screen.ok ? lastAnswer(screen.out) : ''
  const text = answer || 'Your message arrived, but my answer did not come through. I am looking at it now.'
  await gateway('/send', { chat_id: r.chatId, text })
  log(`sent the ${answer ? 'answer from the screen' : 'fallback line'} to ${r.chatId}`)
  if (!answer) {
    await mcp.notification({
      method: 'notifications/claude/channel',
      params: { content: `The WhatsApp bridge could not find your answer to "${r.text}" and told the owner you are looking at it. Answer now with the reply tool.`, meta: { chat_id: r.chatId, sender: 'fraim', name: 'reminder', message_id: '', owner: 'no' } },
    })
  }
}

let checking = false
setInterval(async () => {
  if (checking || !unanswered.pending()) return
  checking = true
  try {
    const busy = (await sessionState()) === 'working'
    for (const r of unanswered.due(Date.now(), busy)) {
      try {
        if (r.fallback) {
          await sendFallback(r)
          continue
        }
        log(`no answer yet for a message in ${r.chatId}; reminder ${r.reminded}`)
        await mcp.notification({
          method: 'notifications/claude/channel',
          params: { content: r.content, meta: { chat_id: r.chatId, sender: 'fraim', name: 'reminder', message_id: '', owner: 'no' } },
        })
      } catch (err) {
        log('could not remind or send the fallback:', err.message)
      }
    }
  } finally {
    checking = false
  }
}, 15000).unref()

const inTurn = inOrder((err) => log('could not handle event:', err.message))

async function listen() {
  let delay = 1000
  for (;;) {
    try {
      const res = await fetch(`${GATEWAY}/events`, { headers: { Authorization: `Bearer ${TOKEN}` } })
      if (!res.ok || !res.body) throw new Error(`events stream returned ${res.status}`)
      log('connected to gateway')
      delay = 1000
      const decoder = new TextDecoder()
      let buffer = ''
      for await (const chunk of res.body) {
        buffer += decoder.decode(chunk, { stream: true })
        let end
        while ((end = buffer.indexOf('\n\n')) !== -1) {
          const frame = buffer.slice(0, end)
          buffer = buffer.slice(end + 2)
          const data = frame
            .split('\n')
            .filter((line) => line.startsWith('data:'))
            .map((line) => line.slice(5).trimStart())
            .join('\n')
          if (!data) continue
          try {
            const event = JSON.parse(data)
            // An approval never waits behind a voice message that is being transcribed.
            if (parseVerdict(event, OWNER)) await handleEvent(event)
            else inTurn(() => handleEvent(event))
          } catch (err) {
            log('could not handle event:', err.message)
          }
        }
      }
      throw new Error('events stream closed')
    } catch (err) {
      log(`${err.message}; retrying in ${Math.round(delay / 1000)}s`)
      await new Promise((resolve) => setTimeout(resolve, delay))
      delay = Math.min(delay * 2, 30000)
    }
  }
}

await mcp.connect(new StdioServerTransport())

if (!GATEWAY || !TOKEN) {
  log('FRAIM_GATEWAY_URL or FRAIM_GATEWAY_TOKEN is missing; channel is idle')
} else if (!startedByMainSession()) {
  log('not the main session; WhatsApp messages stay for main')
} else {
  listen()
}
