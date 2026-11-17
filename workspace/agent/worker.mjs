// The worker: the only reader of the inbox. It claims a batch, starts one run, and records how
// the run ended: it sent something, it stayed quiet, or it asked the owner (a deferred call).
import { randomUUID } from 'node:crypto'
import { openSync, closeSync, writeSync, readFileSync, unlinkSync } from 'node:fs'
import { buildPrompt, claudeArgs, runClaude as defaultRunClaude } from './run.mjs'

export function lock(path) {
  for (let i = 0; i < 2; i++) {
    try {
      const fd = openSync(path, 'wx')
      writeSync(fd, String(process.pid))
      closeSync(fd)
      return () => { try { unlinkSync(path) } catch {} }
    } catch (err) {
      if (err.code !== 'EEXIST') throw err
      const pid = Number(readFileSync(path, 'utf8'))
      if (pid && pid !== process.pid && alive(pid)) throw new Error(`another worker (pid ${pid}) holds ${path}`)
      unlinkSync(path)
    }
  }
  throw new Error(`could not take ${path}`)
}

function alive(pid) {
  try {
    process.kill(pid, 0)
    return true
  } catch (err) {
    return err.code === 'EPERM'
  }
}

export function outcomeOf(result, sent) {
  if (result?.stop_reason === 'tool_deferred') return 'asked'
  return sent > 0 ? 'sent' : 'quiet'
}

export function makeWorker({ inbox, sentBy, config, runClaude = defaultRunClaude, log = () => {} }) {
  async function runOnce() {
    const runId = randomUUID()
    const batch = inbox.claim(runId)
    if (!batch) return false
    const last = batch.events[batch.events.length - 1]
    const replyTo = last.payload?.chat_id || null
    const recent = !batch.session_id && replyTo ? inbox.recent(last.source, replyTo, config.recentMessages) : []
    const prompt = buildPrompt({ memoryDir: config.memoryDir, events: batch.events, recent })
    inbox.startRun(runId, batch.session_id)
    log(`run ${runId}: ${batch.events.length} event(s)${batch.session_id ? `, resumes ${batch.session_id}` : ''}`)

    const env = {
      ...process.env,
      ...config.claudeEnv,
      FRAIM_AGENT_RUN: runId,
      FRAIM_AGENT_REPLY_TO: replyTo || '',
    }
    const args = claudeArgs({
      prompt,
      sessionId: batch.session_id,
      systemPromptFile: config.systemPromptFile,
      mcpConfig: config.mcpConfig(env),
    })
    const { code, result, stderr } = await runClaude({
      bin: config.claudeBin, args, cwd: config.memoryDir, env, timeoutMs: config.runTimeoutMs,
    })

    const deferred = result?.stop_reason === 'tool_deferred'
    if (!result || (result.is_error && !deferred)) {
      inbox.release(runId)
      inbox.endRun(runId, { session_id: result?.session_id, outcome: 'failed', stop_reason: result?.stop_reason })
      log(`run ${runId} failed (exit ${code}): ${(result?.result || stderr || '').slice(0, 300)}`)
      return true
    }
    const outcome = outcomeOf(result, sentBy(runId))
    inbox.finish(runId, 'done')
    inbox.endRun(runId, {
      session_id: result.session_id,
      outcome,
      stop_reason: result.stop_reason,
      deferred: result.deferred_tool_use || null,
      cost_usd: result.total_cost_usd ?? null,
    })
    log(`run ${runId} ended: ${outcome}, session ${result.session_id}`)
    return true
  }

  let stopped = false
  async function loop() {
    inbox.recover(config.runTimeoutMs + 60_000)
    while (!stopped) {
      let worked = false
      try {
        worked = await runOnce()
      } catch (err) {
        log(`worker error: ${err.message}`)
      }
      if (!worked) await new Promise((r) => setTimeout(r, config.pollMs))
    }
  }

  return { runOnce, loop, stop: () => { stopped = true } }
}
