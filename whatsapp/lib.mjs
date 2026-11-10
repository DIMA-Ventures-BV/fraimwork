// Pure gateway rules: who may reach Claude, who Claude may write to, which files may leave.
// No WhatsApp or network imports, so tests can load this file directly.
import { realpath } from 'node:fs/promises'
import path from 'node:path'

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

// The chat a reply goes to. Only chats an allowed sender wrote from, or allowed numbers.
export function resolveChat(body, knownChats, allow) {
  const jid = body.chat_id ? String(body.chat_id) : body.to ? `${digits(body.to)}@s.whatsapp.net` : ''
  if (!jid) throw httpError(400, 'chat_id or to is required')
  const phone = phoneOf(jid)
  if (!knownChats.has(jid) && !(phone && allow.has(phone))) {
    throw httpError(403, 'recipient is not on the allowlist')
  }
  return jid
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
