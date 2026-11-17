#!/usr/bin/env node
// fraim-agent: the always-on agent of one space. One process: event sources write to the
// inbox, and one worker turns batches of events into Claude Code runs.
import { cpSync, existsSync, mkdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { openInbox } from './inbox.mjs'
import { openOutbox, makeDeliver } from './outbox.mjs'
import { makeWorker, lock } from './worker.mjs'
import { listen as listenWhatsApp } from './sources/whatsapp.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const env = process.env
const home = env.HOME || '/home/claude'

export function configFromEnv() {
  const stateDir = env.FRAIM_AGENT_STATE || join(home, '.local/state/fraim/agent')
  const memoryDir = env.FRAIM_AGENT_MEMORY || join(home, 'fraim/agent')
  const db = join(stateDir, 'inbox.db')
  const outboxLog = join(stateDir, 'outbox.log')
  return {
    stateDir,
    memoryDir,
    db,
    outboxLog,
    claudeBin: env.FRAIM_AGENT_CLAUDE || 'fraim-claude',
    systemPromptFile: join(here, 'agent.md'),
    pollMs: Number(env.FRAIM_AGENT_POLL_MS || 2000),
    runTimeoutMs: Number(env.FRAIM_AGENT_RUN_TIMEOUT_MS || 30 * 60 * 1000),
    recentMessages: 10,
    claudeEnv: {
      // fraim-claude adds no permission flags of its own; the run sets auto mode itself.
      FRAIM_PERMISSIONS: 'auto',
      FRAIM_AGENT: '1',
      FRAIM_NO_CAPACITY_WAIT: '1',
      // The article's memory files are the memory; Claude Code's own auto memory stays off.
      CLAUDE_CODE_DISABLE_AUTO_MEMORY: '1',
      FRAIM_AGENT_DB: db,
      FRAIM_AGENT_MEMORY: memoryDir,
      FRAIM_AGENT_OUTBOX_LOG: outboxLog,
    },
    mcpConfig: (runEnv) => ({
      mcpServers: {
        agent: {
          command: process.execPath,
          args: [join(here, 'tools.mjs')],
          env: Object.fromEntries(
            ['FRAIM_AGENT_DB', 'FRAIM_AGENT_MEMORY', 'FRAIM_AGENT_OUTBOX_LOG', 'FRAIM_AGENT_RUN', 'FRAIM_AGENT_REPLY_TO',
              'FRAIM_GATEWAY_URL', 'FRAIM_GATEWAY_TOKEN', 'FRAIM_OWNER']
              .filter((k) => runEnv[k]).map((k) => [k, runEnv[k]]),
          ),
        },
      },
    }),
  }
}

export function prepare(config) {
  mkdirSync(config.stateDir, { recursive: true })
  if (!existsSync(join(config.memoryDir, 'instructions.md'))) {
    cpSync(join(here, 'memory-template'), config.memoryDir, { recursive: true })
  }
}

async function main() {
  const config = configFromEnv()
  prepare(config)
  const log = (line) => console.error(`${new Date().toISOString()} ${line}`)
  const unlock = lock(join(config.stateDir, 'worker.lock'))
  const inbox = openInbox(config.db)
  const outbox = openOutbox(inbox.db, {
    memoryDir: config.memoryDir,
    deliver: makeDeliver({ gatewayUrl: env.FRAIM_GATEWAY_URL, gatewayToken: env.FRAIM_GATEWAY_TOKEN, ownerPhone: env.FRAIM_OWNER, logFile: config.outboxLog }),
  })
  const worker = makeWorker({ inbox, sentBy: outbox.sentBy, config, log })
  const abort = new AbortController()
  const stop = () => {
    worker.stop()
    abort.abort()
    unlock()
    process.exit(0)
  }
  process.on('SIGTERM', stop)
  process.on('SIGINT', stop)

  if (env.FRAIM_GATEWAY_URL && env.FRAIM_GATEWAY_TOKEN) {
    listenWhatsApp({ url: env.FRAIM_GATEWAY_URL, token: env.FRAIM_GATEWAY_TOKEN, inbox, log, signal: abort.signal })
  } else {
    log('no WhatsApp gateway configured; only other sources reach the inbox')
  }
  log(`agent started: inbox ${config.db}, memory ${config.memoryDir}`)
  await worker.loop()
}

if (import.meta.url === `file://${process.argv[1]}`) main()
