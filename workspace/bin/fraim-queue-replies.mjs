// Answering someone outside: an agent drafts, only the owner's yes sends.
import fs from 'node:fs'
import path from 'node:path'
import { allItems, itemDir, now, queueUrl, readItem, readThread, runtimeEnv, usage, writeItem } from './fraim-queue-store.mjs'
import { CHANNEL_WORD, MAX_REPLY, addItem, closeSolved, notify, replySummary } from './fraim-queue-approve.mjs'
import { sayInThread } from './fraim-queue-threads.mjs'

async function replyCall(channel, route, body) {
  const env = runtimeEnv()
  const base = channel === 'email' ? env.FRAIM_REPLY_MAIL_URL || 'http://google:8001' : env.FRAIM_GATEWAY_URL
  if (!env.FRAIM_REPLY_TOKEN || !base) throw new Error('sending replies is not set up on this server; run fraim update')
  const r = await fetch(`${base}${route}`, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${env.FRAIM_REPLY_TOKEN}` }, body: JSON.stringify(body), signal: AbortSignal.timeout(25000) })
  const out = await r.json().catch(() => ({}))
  if (!r.ok) throw new Error(out.error || `the sender answered ${r.status}`)
  return out
}

// Who the answer goes to comes from the conversation itself, never from the agent.
async function replyTarget(t) {
  const mail = /^gmail:([\w-]{6,64})$/.exec(t.key)
  if (mail) {
    const who = await replyCall('email', '/who', { thread_id: mail[1] })
    return { channel: 'email', to: who.to, name: who.name || who.to, subject: who.subject, gmail_thread: mail[1] }
  }
  const phone = /^whatsapp:(\d{8,15})$/.exec(t.key)
  if (phone) {
    await replyCall('whatsapp', '/reply/check', { to: phone[1] })
    return { channel: 'whatsapp', to: phone[1], name: t.who || `+${phone[1]}`, subject: '' }
  }
  usage('only a mail or a WhatsApp conversation has someone to answer')
}

export function draftText(item) {
  const r = item.reply
  return [`Reply ready for ${r.name} (${r.to}), by ${CHANNEL_WORD[r.channel]}. Nothing has gone out.`, '', r.text, '', ...(item.need ? [`Why: ${item.need}`] : []), 'Send it? You can change it in the inbox first:', queueUrl()].join('\n')
}

export async function draftReply(id, text, opts = {}) {
  if (process.env.FRAIM_GOAL) usage('a task does not answer people itself: tell the chief of staff what to say')
  const t = readThread(id)
  text = String(text || '').trim()
  if (!text) usage('reply needs the text of the answer (--file F or -- TEXT)')
  if (text.length > MAX_REPLY) usage(`a reply is at most ${MAX_REPLY} characters`)
  const reply = { ...await replyTarget(t), text, status: 'draft', error: '' }
  // One waiting answer per conversation: a new draft takes the place of the one before.
  for (const old of allItems()) {
    if (old.thread === t.id && old.state === 'open' && old.reply) closeSolved(old, 'a newer draft took its place', 'system')
  }
  const item = addItem({
    title: `Reply to ${reply.name}`, ask: `Send this ${CHANNEL_WORD[reply.channel]} to ${reply.name}?`, advise: 'approve', kind: 'decision',
    need: opts.need, ifYes: `${reply.name} receives exactly this text.`, ifNo: 'Nothing goes out.', summary: replySummary(reply),
    priority: opts.priority || 2, lead: opts.lead, source: opts.lead ? `lead ${opts.lead}` : 'chief', thread: t.id, reply, quiet: true,
  })
  notify(draftText(item), true)
  return item
}

// Runs once, for a card the owner approved. A failed send puts the question back; when the
// answer never came, the mail may be out, so a retry could send it twice and it stays closed.
export async function sendApproved(id) {
  const item = readItem(id)
  if (item.state !== 'approved' || item.reply?.status !== 'sending') throw new Error(`${id} is not an approved reply waiting to go out`)
  const claim = path.join(itemDir(id), '.sending')
  fs.mkdirSync(claim)
  const r = item.reply
  const finish = (changes, card = {}) => {
    const fresh = readItem(id)
    Object.assign(fresh, card)
    fresh.reply = { ...fresh.reply, ...changes }
    writeItem(fresh)
  }
  try {
    if (r.channel === 'email') await replyCall('email', '/reply', { thread_id: r.gmail_thread, to: r.to, text: r.text })
    else await replyCall('whatsapp', '/reply', { to: r.to, text: r.text })
  } catch (err) {
    if (err.name === 'TimeoutError') {
      finish({ status: 'unknown', error: 'no answer from the sender' })
      notify(`I do not know if your reply to ${r.name} went out: the sender did not answer. Check your sent messages before you send it again.`, true)
      return
    }
    fs.rmdirSync(claim)
    finish({ status: 'failed', error: err.message }, { state: 'open', decided: '', via: '' })
    notify(`Your reply to ${r.name} did not go out: ${err.message}. It waits in your inbox.`, true)
    return
  }
  finish({ status: 'sent', sent: now() })
  try { if (item.thread) sayInThread(item.thread, item.lead || 'manual', '', `Sent to ${r.name}:\n\n${r.text}`) } catch {}
  notify(`Your reply to ${r.name} went out.`)
}
