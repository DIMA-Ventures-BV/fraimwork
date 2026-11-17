#!/usr/bin/env node
// A stand-in for `claude -p` in agent tests. It records its arguments, and when the prompt
// contains "SAY:<text>" it calls the send tool through the MCP server from --mcp-config.
// "DEFER" ends like a deferred tool call, "FAIL" ends with an error.
import { spawn } from 'node:child_process'
import { appendFileSync } from 'node:fs'

const args = process.argv.slice(2)
const value = (flag) => { const i = args.indexOf(flag); return i === -1 ? null : args[i + 1] }
const prompt = value('-p') || ''
if (process.env.FAKE_CLAUDE_LOG) appendFileSync(process.env.FAKE_CLAUDE_LOG, `${JSON.stringify({ args, cwd: process.cwd() })}\n`)
const session = value('--resume') || 'sess-new-1'
const out = (o) => process.stdout.write(JSON.stringify({ type: 'result', session_id: session, total_cost_usd: 0.01, ...o }))

if (prompt.includes('FAIL')) { out({ subtype: 'error_during_execution', is_error: true, result: 'boom' }); process.exit(1) }
if (prompt.includes('DEFER')) {
  out({ subtype: 'success', is_error: false, result: '', stop_reason: 'tool_deferred',
    deferred_tool_use: { id: 'toolu_1', name: 'mcp__agent__ask_owner', input: { question: 'ok?' } } })
  process.exit(0)
}
const say = prompt.match(/SAY:([^\n<]+)/)
if (!say) { out({ subtype: 'success', is_error: false, result: 'nothing to say', stop_reason: 'end_turn' }); process.exit(0) }

const server = JSON.parse(value('--mcp-config')).mcpServers.agent
const child = spawn(server.command, server.args, { env: { ...process.env, ...server.env }, stdio: ['pipe', 'pipe', 'inherit'] })
let buf = ''
const waiting = new Map()
child.stdout.on('data', (d) => {
  buf += d
  let i
  while ((i = buf.indexOf('\n')) !== -1) {
    const msg = JSON.parse(buf.slice(0, i)); buf = buf.slice(i + 1)
    waiting.get(msg.id)?.(msg); waiting.delete(msg.id)
  }
})
const call = (id, method, params) => new Promise((r) => { waiting.set(id, r); child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`) })
await call(1, 'initialize', { protocolVersion: '2025-06-18' })
const r = await call(2, 'tools/call', { name: 'send', arguments: { text: say[1].trim() } })
child.kill()
out({ subtype: 'success', is_error: false, result: r.result.content[0].text, stop_reason: 'end_turn' })
