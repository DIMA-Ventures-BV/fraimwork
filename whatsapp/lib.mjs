// Pure gateway rules: who may reach Claude, who Claude may write to, which files may leave.
// No WhatsApp or network imports, so tests can load this file directly.
import { readFileSync, renameSync, writeFileSync } from 'node:fs'
import { realpath } from 'node:fs/promises'
import path from 'node:path'

// The WhatsApp encryption library prints whole session objects, private keys included, with
// console.info. Console output keeps text and error messages; every object is hidden.
function safeLogArg(arg) {
  if (arg instanceof Error) return `${arg.name}: ${arg.message}`
  if (arg === null || typeof arg !== 'object' && typeof arg !== 'function') return arg
  return '[hidden]'
}

export function guardConsole(target = console) {
  for (const method of ['log', 'info', 'warn', 'error', 'debug', 'trace']) {
    const write = target[method].bind(target)
    target[method] = (...args) => write(...args.map(safeLogArg))
  }
  for (const method of ['dir', 'dirxml', 'table']) {
    const write = target.log.bind(target)
    target[method] = () => write('[hidden]')
  }
}

// Messages that arrived while the gateway was away come as 'append'. They count when they are
// recent; anything older than the window would be an answer to a question nobody remembers.
export function readsUpsert(type, timestamp, nowSeconds, windowSeconds) {
  if (type === 'notify') return true
  return type === 'append' && timestamp > 0 && nowSeconds - timestamp <= windowSeconds
}

export const reconnectDelay = (attempt) => Math.min(3000 * 2 ** Math.max(0, attempt), 60000)

// Down for this long with nothing to wait for: only a fresh start of the process helps.
export function givesUp({ downSince, waitingForQr, loggedOut, now, limitMs }) {
  return Boolean(downSince) && !waitingForQr && !loggedOut && now - downSince > limitMs
}

// Messages nobody listens for yet. On disk, so a restart of the gateway does not lose them.
export class SavedQueue {
  constructor(file, limit, onError = () => {}) {
    Object.assign(this, { file, limit, onError, items: [] })
    try {
      const saved = JSON.parse(readFileSync(file, 'utf8'))
      if (Array.isArray(saved)) this.items = saved.slice(-limit)
    } catch (err) {
      if (err.code !== 'ENOENT') onError(err)
    }
  }

  get length() { return this.items.length }

  save() {
    try {
      writeFileSync(`${this.file}.tmp`, JSON.stringify(this.items), { mode: 0o600 })
      renameSync(`${this.file}.tmp`, this.file)
    } catch (err) {
      this.onError(err)
    }
  }

  push(event) {
    this.items.push(event)
    if (this.items.length > this.limit) this.items.shift()
    this.save()
  }

  drain() {
    const out = this.items
    this.items = []
    this.save()
    return out
  }
}

export const digits = (value) => String(value || '').replace(/\D/g, '').replace(/^00/, '')

export function parseAllowlist(owner, allow) {
  return new Set([owner, ...String(allow || '').split(',')].map(digits).filter(Boolean))
}

export function phoneOf(jid) {
  return jid && jid.endsWith('@s.whatsapp.net') ? digits(jid.split('@')[0].split(':')[0]) : ''
}

export function senderPhone(key) {
  const candidates = [key.remoteJid, key.remoteJidAlt, key.participant, key.participantAlt, key.senderPn]
  for (const jid of candidates) {
    const phone = phoneOf(jid)
    if (phone) return phone
  }
  return ''
}

export const isGroupOrBroadcast = (jid) => jid.endsWith('@g.us') || jid === 'status@broadcast'

// The sender's phone when an inbound message may reach Claude, '' when it must be dropped.
export function allowedSender(key, allow) {
  if (!key || key.fromMe || !key.remoteJid || isGroupOrBroadcast(key.remoteJid)) return ''
  const phone = senderPhone(key)
  return phone && allow.has(phone) ? phone : ''
}

const MEDIA_FIELDS = [
  ['imageMessage', 'image'],
  ['videoMessage', 'video'],
  ['ptvMessage', 'video'],
  ['audioMessage', 'audio'],
  ['stickerMessage', 'sticker'],
  ['documentMessage', 'document'],
]

// The file in a message and what kind it is. An audio or video file sent as a document counts
// as audio or video.
export function mediaOf(inner) {
  for (const [field, kind] of MEDIA_FIELDS) {
    const media = inner[field]
    if (!media) continue
    const type = String(media.mimetype || '')
    if (kind === 'document' && type.startsWith('audio/')) return { media, kind: 'audio' }
    if (kind === 'document' && type.startsWith('video/')) return { media, kind: 'video' }
    return { media, kind }
  }
  return null
}

export const MAX_FILE_MB = 500

// WhatsApp gives the size as a number or as a 64-bit object.
export function tooLarge(media) {
  return Number(String(media.fileLength ?? 0)) > MAX_FILE_MB * 1024 * 1024
}

const safeExtension = (ext) => (/^\.[A-Za-z0-9]{1,10}$/.test(ext) ? ext : '')

function typeExtension(mimetype) {
  const subtype = String(mimetype || '').split('/')[1]?.split(';')[0].trim() || ''
  return safeExtension(`.${subtype}`) || '.bin'
}

// The name in the inbox. Claude may paste this path into a shell, and the sender chose the
// original name, so only safe characters stay.
export function mediaFileName(media, stamp) {
  if (!media.fileName) return `${stamp}-attachment${typeExtension(media.mimetype)}`
  const name = path.basename(String(media.fileName))
  const ext = safeExtension(path.extname(name))
  const base = (ext ? name.slice(0, -ext.length) : name).replace(/[^\w.-]+/g, '_').slice(0, 100)
  return `${stamp}-${base}${ext || typeExtension(media.mimetype)}`
}

export function textOf(inner) {
  return inner.conversation
    || inner.extendedTextMessage?.text
    || inner.imageMessage?.caption
    || inner.documentMessage?.caption
    || inner.videoMessage?.caption
    || inner.ptvMessage?.caption
    || ''
}

function describeContact(contact) {
  return `[shared a contact: ${contact.displayName || 'no name'}]\n${contact.vcard || ''}`.trim()
}

function describeLocation(place) {
  const named = [place.name, place.address].filter(Boolean).join(', ')
  return `[shared a location: ${place.degreesLatitude}, ${place.degreesLongitude}${named ? ` (${named})` : ''}]`
}

// Things without a file or text that a sender can still share.
export function describeShare(inner) {
  if (inner.contactMessage) return describeContact(inner.contactMessage)
  if (inner.contactsArrayMessage) return (inner.contactsArrayMessage.contacts || []).map(describeContact).join('\n')
  const place = inner.locationMessage || inner.liveLocationMessage
  if (place) return describeLocation(place)
  const poll = inner.pollCreationMessage || inner.pollCreationMessageV2 || inner.pollCreationMessageV3
  if (poll) return `[shared a poll: ${poll.name}: ${(poll.options || []).map((o) => o.optionName).join(', ')}]`
  return ''
}

const userOf = (jid) => {
  const [user, domain] = String(jid || '').split('@')
  return `${user.split(':')[0]}@${domain}`
}

// The message this one replies to (a WhatsApp swipe-reply), or null. "server" means the sender
// replied to something the server wrote, "sender" to their own message, "" when WhatsApp did
// not say.
export function quotedOf(inner, me, normalize = (m) => m) {
  const info = Object.values(inner).find((part) => part?.contextInfo?.quotedMessage)?.contextInfo
  if (!info) return null
  const message = normalize(info.quotedMessage) || {}
  const mine = new Set(me.filter(Boolean).map(userOf))
  const from = !info.participant ? '' : mine.has(userOf(info.participant)) ? 'server' : 'sender'
  return { id: info.stanzaId || '', from, text: textOf(message) || describeShare(message), message }
}

export function httpError(status, message) {
  return Object.assign(new Error(message), { status })
}

export function parseContacts(value) {
  return new Set(String(value || '').split(',').map(digits).filter(Boolean))
}

// A contact is someone outside the owner may answer. Their messages become conversations in the
// inbox and never reach Claude as a chat. Someone on the allowlist stays a normal sender.
export function contactSender(key, allow, contacts) {
  if (!key || key.fromMe || !key.remoteJid || isGroupOrBroadcast(key.remoteJid)) return ''
  const phone = senderPhone(key)
  return phone && !allow.has(phone) && contacts.has(phone) ? phone : ''
}

// The chat an approved reply goes to. Only numbers the owner listed as contacts.
export function contactChat(to, contacts) {
  const phone = digits(to)
  if (!phone) throw httpError(400, 'to is required')
  if (!contacts.has(phone)) throw httpError(403, 'this number is not in WHATSAPP_CONTACTS')
  return `${phone}@s.whatsapp.net`
}

// The chat a reply goes to. Only chats an allowed sender wrote from, allowed numbers, or groups
// the owner opened (WHATSAPP_GROUPS).
export function resolveChat(body, knownChats, allow, groups = parseGroups('')) {
  const jid = body.chat_id ? String(body.chat_id) : body.to ? `${digits(body.to)}@s.whatsapp.net` : ''
  if (!jid) throw httpError(400, 'chat_id or to is required')
  const phone = phoneOf(jid)
  if (!knownChats.has(jid) && !(phone && allow.has(phone)) && !groupOpen(jid, groups)) {
    throw httpError(403, 'recipient is not on the allowlist')
  }
  return jid
}

// WHATSAPP_GROUPS: group ids (1203630...@g.us) the server listens in, or "all" for every group
// it is a member of. Empty: no group reaches Claude.
export function parseGroups(value) {
  const parts = String(value || '').split(',').map((p) => p.trim()).filter(Boolean)
  return {
    all: parts.some((p) => p.toLowerCase() === 'all'),
    ids: new Set(parts.filter((p) => p.endsWith('@g.us'))),
  }
}

export const groupOpen = (jid, groups) =>
  String(jid || '').endsWith('@g.us') && (groups.all || groups.ids.has(String(jid)))

// The sender's phone when a group message may reach Claude: an open group, and a member who is
// on the allowlist. Everyone else in the group stays unheard.
export function groupSender(key, allow, groups) {
  if (!key || key.fromMe || !groupOpen(key.remoteJid, groups)) return ''
  for (const jid of [key.participant, key.participantAlt, key.senderPn]) {
    const phone = phoneOf(jid)
    if (phone) return allow.has(phone) ? phone : ''
  }
  return ''
}

// True when a group message is meant for the server: it @mentions the server, or it replies to
// something the server wrote.
export function addressesMe(inner, me, quote) {
  if (quote?.from === 'server') return true
  const mine = new Set(me.filter(Boolean).map(userOf))
  const mentioned = Object.values(inner).flatMap((part) => part?.contextInfo?.mentionedJid || [])
  return mentioned.some((jid) => mine.has(userOf(jid)))
}

// Maps "fraim/..." or "pc/..." to a real file inside one of the roots. Symlinks and ".."
// that lead outside the root are refused.
export async function resolveSharedPath(sharedPath, roots) {
  const parts = String(sharedPath).split('/')
  const twoLevel = `${parts[0]}/${parts[1]}`
  const [root, rest] = Object.hasOwn(roots, twoLevel)
    ? [roots[twoLevel], parts.slice(2)]
    : [Object.hasOwn(roots, parts[0]) ? roots[parts[0]] : undefined, parts.slice(1)]
  if (!root || rest.length === 0) throw httpError(400, 'path must start with fraim/ or pc/')
  const absolute = await realpath(path.join(root, ...rest)).catch(() => null)
  if (!absolute || !absolute.startsWith(root + path.sep)) throw httpError(404, 'file not found')
  return absolute
}
