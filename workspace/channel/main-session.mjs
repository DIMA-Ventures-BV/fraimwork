// Every Claude started in ~/fraim loads this channel, also a short automation run. The gateway
// hands each waiting message to whoever connects first, and only main can act on it, so only
// the Claude started with the channel flag may read messages.
import { readFileSync } from 'node:fs'

export const hasChannelFlag = (cmdline) => cmdline.includes('server:whatsapp')

export function startedByMainSession(ppid = process.ppid) {
  try {
    return hasChannelFlag(readFileSync(`/proc/${ppid}/cmdline`, 'utf8'))
  } catch {
    return false
  }
}
