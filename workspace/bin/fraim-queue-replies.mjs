// Answering someone outside: an agent drafts, only the owner's yes sends.
import fs from 'node:fs'
import path from 'node:path'
import { allItems, itemDir, now, promptText, readItem, readThread, runtimeEnv, usage, writeItem } from './fraim-queue-store.mjs'
import { channelWord, replyTarget as channelTarget, sendReply } from './fraim-channels.mjs'
import { MAX_REPLY, addItem, closeSolved, notify, replySummary } from './fraim-queue-approve.mjs'
import { sayInThread } from './fraim-queue-threads.mjs'

// Who the answer goes to comes from the conversation itself, never from the agent.
async function replyTarget(t) {
  return await channelTarget(t, runtimeEnv()) || usage('only a mail or a WhatsApp conversation has someone to answer')
}

function draftText(item) {
  const r = item.reply
  return promptText('notice-reply-ready', { name: r.name, to: r.to, channel: channelWord(r.channel), text: r.text, need: item.need || '' })
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
    title: `Reply to ${reply.name}`, ask: `Send this ${channelWord(reply.channel)} to ${reply.name}?`, advise: 'approve', kind: 'decision',
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
    await sendReply(r, runtimeEnv())
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
