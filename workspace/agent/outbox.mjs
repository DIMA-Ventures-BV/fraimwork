// The outbox: what the agent tells the owner. A plain send is enough for now; every message
// is kept in the outbox table and in reported.md, so the next run knows what was said.
import { appendFileSync } from 'node:fs'
import { join } from 'node:path'

const SCHEMA = `
CREATE TABLE IF NOT EXISTS outbox (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT,
  chat_id TEXT,
  text TEXT NOT NULL,
  status TEXT NOT NULL,
  error TEXT,
  created_at INTEGER NOT NULL
);
`

export function openOutbox(db, { memoryDir, deliver, now = Date.now }) {
  db.exec(SCHEMA)
  const insert = db.prepare(
    `INSERT INTO outbox (run_id, chat_id, text, status, error, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
  )

  async function send({ runId = null, chatId = null, text }) {
    if (!text || !String(text).trim()) throw new Error('text is required')
    let status = 'sent'
    let error = null
    try {
      await deliver({ chatId, text: String(text) })
    } catch (err) {
      status = 'failed'
      error = err.message
    }
    insert.run(runId, chatId, String(text), status, error, now())
    if (status === 'sent') {
      const line = `- ${new Date(now()).toISOString().slice(0, 16)} ${String(text).replace(/\s*\n\s*/g, ' / ')}\n`
      appendFileSync(join(memoryDir, 'reported.md'), line)
    }
    return { status, error }
  }

  function sentBy(runId) {
    return db.prepare(`SELECT COUNT(*) AS n FROM outbox WHERE run_id = ? AND status = 'sent'`).get(runId).n
  }

  return { send, sentBy }
}

// Where a message goes: the WhatsApp gateway when one is configured, else a local log file
// (local trials and tests).
export function makeDeliver({ gatewayUrl, gatewayToken, ownerPhone, logFile }) {
  if (gatewayUrl && gatewayToken) {
    return async ({ chatId, text }) => {
      const body = chatId ? { chat_id: chatId, text } : { to: ownerPhone, text }
      const res = await fetch(`${gatewayUrl}/send`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${gatewayToken}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      })
      if (!res.ok) throw new Error(`gateway answered ${res.status}`)
    }
  }
  return async ({ chatId, text }) => {
    appendFileSync(logFile, `${JSON.stringify({ at: new Date().toISOString(), chatId, text })}\n`)
  }
}
