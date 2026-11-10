// Conversations: what came in, and what the agents and the owner say about it.
import fs from 'node:fs'
import path from 'node:path'
import {
  HOME, THREADS, allItems, allThreads, fire, newThreadId, now, promptText, readText, readThread, theChief, usage, writeThread,
} from './fraim-queue-store.mjs'
import { decide } from './fraim-queue-approve.mjs'

// One thing, one conversation: the same key (a mail chain, a Linear issue, an error) lands in the
// same conversation. news is true when there is something new to read; a repeat of an error
// only raises its count.
export function putThread(data) {
  const key = String(data.key || '').slice(0, 200)
  let t = key ? allThreads().find((x) => x.key === key) : null
  const isNew = !t
  if (isNew) {
    t = { id: newThreadId(), kind: String(data.kind || 'other'), key, title: '', who: '', url: '', text: '', details: '', fields: {}, messages: [], comments: [], stats: null, created: now(), changed: now(), active: '', seen: '' }
  }
  const before = JSON.stringify([t.messages.length, t.comments.length, t.text])
  for (const [k, max] of [['title', 200], ['who', 200], ['url', 500], ['text', 40000], ['details', 20000]]) {
    if (data[k] != null) t[k] = String(data[k]).slice(0, max)
  }
  if (data.fields && typeof data.fields === 'object') t.fields = { ...t.fields, ...data.fields }
  if (Array.isArray(data.messages)) t.messages = data.messages
  if (Array.isArray(data.comments)) t.comments = data.comments.slice(0, 200)
  if (data.hit) {
    const n = Number(data.hit) || 1
    t.stats = { count: (t.stats?.count || 0) + n, first: t.stats?.first || now(), last: now() }
  }
  const news = isNew || before !== JSON.stringify([t.messages.length, t.comments.length, t.text])
  if (news) {
    t.changed = now()
    delete t.closed
  }
  writeThread(t)
  return { thread: t, isNew, news }
}

export function sayInThread(id, from, to, text) {
  const t = readThread(id)
  fs.appendFileSync(path.join(THREADS, id, 'chat.jsonl'), `${JSON.stringify({ time: now(), from: String(from), to: String(to || ''), text: String(text).slice(0, 4000) })}\n`)
  t.active = now()
  writeThread(t)
}

// What does not belong in the inbox, in a file the owner can read and change. "never:" lines keep
// a sender out for good; "not relevant:" lines are examples the mail check learns from.
const RULES = path.join(HOME, 'fraim/inbox-rules.md')
const RULES_HEAD = '# What does not belong in the inbox. Change this file as you like.\n# never: an address or @domain that is kept out for good\n# not relevant: a mail you marked, an example for the mail check\n'

export function addRule(line) {
  const clean = String(line).replace(/\s+/g, ' ').trim().slice(0, 200)
  const old = readText(RULES, 200000) || RULES_HEAD
  const lines = old.split('\n').filter(Boolean)
  if (!lines.includes(`- ${clean}`)) lines.push(`- ${clean}`)
  const head = lines.filter((l) => !l.startsWith('- '))
  fs.writeFileSync(RULES, `${[...head, ...lines.filter((l) => l.startsWith('- ')).slice(-300)].join('\n')}\n`)
  return clean
}

function removeRule(line) {
  const old = readText(RULES, 200000)
  if (old) fs.writeFileSync(RULES, old.split('\n').filter((l) => l !== `- ${line}`).join('\n'))
}

export function neverShow(address) {
  const a = String(address || '').toLowerCase()
  if (!a) return false
  return readText(RULES, 200000).split('\n').some((l) => {
    const m = /^- never:\s*(\S+)/i.exec(l)
    return m && (a === m[1].toLowerCase() || (m[1].startsWith('@') && a.endsWith(m[1].toLowerCase())))
  })
}

// The owner's "Not relevant": gone from the list, questions about it closed, and the mail check learns.
export function dismissThread(t) {
  for (const i of allItems().filter((x) => x.thread === t.id && x.state === 'open')) decide(i.id, 'dismissed', 'Not relevant', 'page')
  const last = t.messages.at(-1)
  const rule = addRule(`not relevant: ${last?.from || t.who}${last?.address ? ` <${last.address}>` : ''}, "${t.title}"`)
  t.closed = { by: 'owner', time: now(), rule }
  writeThread(t)
  if (t.active) tellChief(t, 'owner', promptText('thread-closed', { title: t.title }))
}

export function restoreThread(t) {
  if (t.closed?.rule) removeRule(t.closed.rule)
  delete t.closed
  writeThread(t)
}

// An agent closes what needs no work. What still waits for the owner stays.
export function closeThread(id, from, reason) {
  const t = readThread(id)
  const why = String(reason || '').trim()
  if (!why) usage('thread close needs --reason')
  if (allItems().some((i) => i.thread === id && i.state === 'open')) throw new Error('this conversation still needs the owner')
  sayInThread(id, from || 'chief', '', why)
  const fresh = readThread(id)
  fresh.closed = { by: String(from || 'chief'), time: now() }
  writeThread(fresh)
}

export function tellChief(thread, from, text) {
  const chief = theChief()
  if (chief) fire('fraim-lead', ['tell', chief, '--from', from, '--thread', thread.id, '--', text])
}

const SOURCE_WORD = { email: 'email', whatsapp: 'WhatsApp message', linear: 'Linear issue', error: 'website problem' }
export function announce({ thread, isNew }) {
  tellChief(thread, thread.kind, promptText('thread-new', { is_new: isNew ? '1' : '', what: SOURCE_WORD[thread.kind] || thread.kind, who: thread.messages.at(-1)?.from || thread.who || 'someone', title: thread.title, id: thread.id }))
}

// A contact wrote on WhatsApp. Each number is one conversation, and the message never reaches a
// Claude as a chat: the chief reads it as data, like a mail.
export function addWhatsApp(number, name, text) {
  const phone = String(number || '').replace(/\D/g, '')
  if (!/^\d{8,15}$/.test(phone)) usage('thread whatsapp needs --number with the phone number')
  if (!String(text || '').trim()) usage('thread whatsapp needs the text of the message')
  const key = `whatsapp:${phone}`
  const who = String(name || '').trim() || `+${phone}`
  const before = allThreads().find((t) => t.key === key)
  const message = { from: who, address: `+${phone}`, to: '', date: now(), text: String(text).slice(0, 40000), quoted: '', html: '', designed: false, attachments: [] }
  const r = putThread({ kind: 'whatsapp', key, title: `WhatsApp from ${who}`, who, messages: [...(before?.messages || []), message].slice(-200) })
  if (r.news) announce(r)
  return r
}
