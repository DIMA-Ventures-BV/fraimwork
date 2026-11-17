#!/usr/bin/env node
// The agent's own tools, as a minimal MCP server on stdio (newline-delimited JSON-RPC).
// The worker starts one per run with the run's id and reply target in the environment.
import { createInterface } from 'node:readline'
import { DatabaseSync } from 'node:sqlite'
import { openOutbox, makeDeliver } from './outbox.mjs'

const env = process.env

export const TOOLS = [
  {
    name: 'send',
    description:
      'Send a message to the owner. This is the only way the owner hears from you. ' +
      'Send only what the owner wants to know now. When nothing is worth saying, do not call it.',
    inputSchema: {
      type: 'object',
      properties: { text: { type: 'string', description: 'The message, in the owner\'s style from instructions.md' } },
      required: ['text'],
    },
  },
]

export function makeHandlers({ outbox, runId, chatId }) {
  return {
    async send({ text }) {
      const r = await outbox.send({ runId, chatId, text })
      if (r.status !== 'sent') throw new Error(`not delivered: ${r.error}`)
      return 'sent'
    },
  }
}

export async function handle(message, handlers) {
  const { id, method, params } = message
  const ok = (result) => ({ jsonrpc: '2.0', id, result })
  if (method === 'initialize') {
    return ok({
      protocolVersion: params?.protocolVersion || '2025-06-18',
      capabilities: { tools: {} },
      serverInfo: { name: 'agent', version: '1.0.0' },
    })
  }
  if (method === 'tools/list') return ok({ tools: TOOLS })
  if (method === 'tools/call') {
    const fn = handlers[params?.name]
    if (!fn) return ok({ content: [{ type: 'text', text: `unknown tool ${params?.name}` }], isError: true })
    try {
      const text = await fn(params.arguments || {})
      return ok({ content: [{ type: 'text', text: String(text) }] })
    } catch (err) {
      return ok({ content: [{ type: 'text', text: err.message }], isError: true })
    }
  }
  if (id === undefined) return null
  if (method === 'ping') return ok({})
  return { jsonrpc: '2.0', id, error: { code: -32601, message: `method not found: ${method}` } }
}

function main() {
  const db = new DatabaseSync(env.FRAIM_AGENT_DB)
  db.exec('PRAGMA busy_timeout = 5000;')
  const deliver = makeDeliver({
    gatewayUrl: env.FRAIM_GATEWAY_URL,
    gatewayToken: env.FRAIM_GATEWAY_TOKEN,
    ownerPhone: env.FRAIM_OWNER,
    logFile: env.FRAIM_AGENT_OUTBOX_LOG,
  })
  const outbox = openOutbox(db, { memoryDir: env.FRAIM_AGENT_MEMORY, deliver })
  const handlers = makeHandlers({ outbox, runId: env.FRAIM_AGENT_RUN, chatId: env.FRAIM_AGENT_REPLY_TO || null })
  const rl = createInterface({ input: process.stdin })
  rl.on('line', async (line) => {
    if (!line.trim()) return
    let message
    try {
      message = JSON.parse(line)
    } catch {
      return
    }
    const reply = await handle(message, handlers)
    if (reply) process.stdout.write(`${JSON.stringify(reply)}\n`)
  })
}

if (import.meta.url === `file://${process.argv[1]}`) main()
