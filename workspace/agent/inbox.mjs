// The event inbox: one durable table per user, the source of truth for what the agent must do.
// Handlers only add events. Exactly one worker claims them, runs, and marks them done.
// A delivery that arrives twice (same source and source_id) is one event.
import { DatabaseSync } from 'node:sqlite'

const SCHEMA = `
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  source TEXT NOT NULL,
  source_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  payload TEXT NOT NULL DEFAULT '{}',
  session_id TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  attempts INTEGER NOT NULL DEFAULT 0,
  run_id TEXT,
  claimed_at INTEGER,
  created_at INTEGER NOT NULL,
  UNIQUE (source, source_id)
);
CREATE INDEX IF NOT EXISTS events_pending ON events (status, id);
CREATE TABLE IF NOT EXISTS runs (
  id TEXT PRIMARY KEY,
  session_id TEXT,
  outcome TEXT,
  stop_reason TEXT,
  deferred TEXT,
  cost_usd REAL,
  started_at INTEGER NOT NULL,
  ended_at INTEGER
);
`

export const MAX_ATTEMPTS = 3

export function openInbox(path, { now = Date.now } = {}) {
  const db = new DatabaseSync(path)
  db.exec('PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000;')
  db.exec(SCHEMA)

  const insert = db.prepare(
    `INSERT INTO events (source, source_id, kind, payload, session_id, created_at)
     VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (source, source_id) DO NOTHING`,
  )

  function add({ source, source_id, kind, payload = {}, session_id = null }) {
    if (!source || !source_id || !kind) throw new Error('source, source_id and kind are required')
    const r = insert.run(source, String(source_id), kind, JSON.stringify(payload), session_id, now())
    return { added: r.changes === 1, id: r.changes === 1 ? Number(r.lastInsertRowid) : null }
  }

  // The oldest pending event decides the batch: every pending event for the same session
  // (or, for new work, every pending event without a session) runs together.
  function claim(runId) {
    db.exec('BEGIN IMMEDIATE')
    try {
      const first = db.prepare(`SELECT session_id FROM events WHERE status = 'pending' ORDER BY id LIMIT 1`).get()
      if (!first) {
        db.exec('COMMIT')
        return null
      }
      const rows = first.session_id === null
        ? db.prepare(`SELECT * FROM events WHERE status = 'pending' AND session_id IS NULL ORDER BY id`).all()
        : db.prepare(`SELECT * FROM events WHERE status = 'pending' AND session_id = ? ORDER BY id`).all(first.session_id)
      const mark = db.prepare(
        `UPDATE events SET status = 'running', attempts = attempts + 1, run_id = ?, claimed_at = ? WHERE id = ?`,
      )
      for (const row of rows) mark.run(runId, now(), row.id)
      db.exec('COMMIT')
      return { session_id: first.session_id, events: rows.map(decode) }
    } catch (err) {
      db.exec('ROLLBACK')
      throw err
    }
  }

  function finish(runId, status) {
    db.prepare(`UPDATE events SET status = ? WHERE run_id = ? AND status = 'running'`).run(status, runId)
  }

  // A failed run puts its events back, until they have had MAX_ATTEMPTS tries.
  function release(runId) {
    db.prepare(
      `UPDATE events SET status = CASE WHEN attempts >= ? THEN 'failed' ELSE 'pending' END
       WHERE run_id = ? AND status = 'running'`,
    ).run(MAX_ATTEMPTS, runId)
  }

  // After a crash: events still marked running by a worker that is gone go back to pending.
  function recover(olderThanMs) {
    const stale = db.prepare(`SELECT DISTINCT run_id FROM events WHERE status = 'running' AND claimed_at < ?`)
      .all(now() - olderThanMs)
    for (const { run_id } of stale) release(run_id)
    return stale.length
  }

  function recent(source, chatId, limit = 10) {
    return db.prepare(
      `SELECT * FROM events WHERE source = ? AND status = 'done'
       AND json_extract(payload, '$.chat_id') = ? ORDER BY id DESC LIMIT ?`,
    ).all(source, chatId, limit).map(decode).reverse()
  }

  function startRun(runId, sessionId) {
    db.prepare(`INSERT INTO runs (id, session_id, started_at) VALUES (?, ?, ?)`).run(runId, sessionId, now())
  }

  function endRun(runId, { session_id = null, outcome, stop_reason = null, deferred = null, cost_usd = null }) {
    db.prepare(
      `UPDATE runs SET session_id = COALESCE(?, session_id), outcome = ?, stop_reason = ?, deferred = ?,
       cost_usd = ?, ended_at = ? WHERE id = ?`,
    ).run(session_id, outcome, stop_reason, deferred ? JSON.stringify(deferred) : null, cost_usd, now(), runId)
  }

  function counts() {
    const out = { pending: 0, running: 0, done: 0, failed: 0 }
    for (const r of db.prepare(`SELECT status, COUNT(*) AS n FROM events GROUP BY status`).all()) out[r.status] = r.n
    return out
  }

  return { db, add, claim, finish, release, recover, recent, startRun, endRun, counts, close: () => db.close() }
}

function decode(row) {
  return { ...row, payload: JSON.parse(row.payload) }
}
