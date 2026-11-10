// Reading a Gmail chain into a conversation.
import { usage } from './fraim-queue-store.mjs'
import { announce, neverShow, putThread } from './fraim-queue-threads.mjs'

function person(from) {
  const m = /^\s*"?([^"<]*?)"?\s*<([^>]+)>/.exec(from || '')
  return m ? { name: m[1].trim() || m[2], address: m[2] } : { name: String(from || 'Someone').trim(), address: '' }
}

// What was written now and what is only quoted from earlier mails. When no quote is found, or the
// cut would leave nothing, the whole text stays.
function splitQuote(body) {
  const lines = String(body).split('\n')
  const start = lines.findIndex((l, i) => {
    const two = `${l} ${lines[i + 1] || ''}`
    return /^>/.test(l)
      || /^(On|Op)\s.+(wrote|schreef[^:]*):\s*$/i.test(l)
      || /^(On|Op)\s.+(wrote|schreef[^:]*):\s*$/i.test(two)
      || /^-{2,}\s*(Original Message|Oorspronkelijk bericht)/i.test(l)
      || (/^(From|Van):\s.+/.test(l) && lines.slice(i + 1, i + 4).some((x) => /^(Sent|Date|Verzonden|Datum):\s/.test(x)))
  })
  if (start < 0) return { text: String(body).trim(), quoted: '' }
  const text = lines.slice(0, start).join('\n').trim()
  return text ? { text, quoted: lines.slice(start).join('\n').trim() } : { text: String(body).trim(), quoted: '' }
}

function unforward(body) {
  const m = /^[-\s]*(?:Forwarded message|Doorgestuurd bericht|Begin forwarded message)[-\s:]*$/mi.exec(body)
  if (!m) return null
  const note = body.slice(0, m.index).trim()
  const rest = body.slice(m.index + m[0].length).replace(/^\n+/, '')
  const end = rest.indexOf('\n\n')
  const head = end < 0 ? rest : rest.slice(0, end)
  const get = (re) => re.exec(head)?.[1]?.trim() || ''
  const from = get(/^(?:From|Van):[ \t]*(.*)$/mi)
  if (!from) return null
  return { note, from, date: get(/^(?:Date|Datum|Sent|Verzonden):[ \t]*(.*)$/mi), to: get(/^(?:To|Aan):[ \t]*(.*)$/mi), body: end < 0 ? '' : rest.slice(end + 2) }
}

// Walled off in the page; this takes out what could still reach outside the frame.
function cleanHtml(html) {
  const out = String(html).replace(/<(script|style\s+type="text\/javascript")[\s\S]*?<\/\1>/gi, '').replace(/<(meta|base|link)\b[^>]*>/gi, '').trim()
  return out.length > 400000 ? '' : out
}

const isDesigned = (html) => (html.match(/<img\b/gi) || []).length >= 3 || (html.match(/<table\b/gi) || []).length >= 4

function parseGmailThread(text, html = '') {
  const parts = (s) => {
    const p = String(s).replace(/\r\n/g, '\n').split(/^=== Message \d+ ===$/m)
    return { head: p[0], bodies: p.slice(1).map((b) => {
      const raw = b.replace(/^\n+/, '')
      const end = raw.indexOf('\n\n')
      return { head: end < 0 ? raw : raw.slice(0, end), body: end < 0 ? '' : raw.slice(end + 2) }
    }) }
  }
  const t = parts(text)
  const h = parts(html)
  const subject = /^Subject:[ \t]*(.*)$/m.exec(t.head)?.[1]?.trim() || ''
  const messages = t.bodies.map((m, i) => {
    const get = (name) => {
      const v = new RegExp(`^${name}:[ \\t]*(.*)$`, 'm').exec(m.head)?.[1]?.trim() || ''
      return /^\[not present/.test(v) ? '' : v
    }
    const [body, attached = ''] = m.body.split(/^--- ATTACHMENTS ---$/m)
    const attachments = [...attached.matchAll(/^\d+\.\s+(.+?)\s+\(([^,)]+),\s*([^)]+)\)$/gm)].map((a) => ({ name: a[1], type: a[2], size: a[3] }))
    const fwd = unforward(body.trim())
    const sender = person(fwd ? fwd.from : get('From'))
    const { text: said, quoted } = splitQuote(fwd ? fwd.body : body)
    const page = cleanHtml((h.bodies[i]?.body || '').split(/^--- ATTACHMENTS ---$/m)[0])
    return {
      from: sender.name, address: sender.address, to: fwd ? fwd.to : get('To'), date: fwd?.date || get('Date'),
      forwardedBy: fwd ? person(get('From')).name : '', forwardNote: fwd?.note || '',
      text: said.slice(0, 40000), quoted: quoted.slice(0, 40000), html: page, designed: Boolean(page) && !fwd && !quoted && isDesigned(page), attachments,
    }
  })
  return { title: subject.replace(/^((re|fwd?|antw|aw)\s*:\s*)+/i, '').trim() || '(no subject)', who: messages[0]?.from || 'Someone', messages }
}

async function mcpCaller(url) {
  let session = ''
  let n = 0
  const rpc = async (method, params, note) => {
    const headers = { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream', ...(session ? { 'mcp-session-id': session } : {}) }
    const r = await fetch(url, { method: 'POST', headers, body: JSON.stringify({ jsonrpc: '2.0', method, params, ...(note ? {} : { id: ++n }) }), signal: AbortSignal.timeout(60000) })
    session = r.headers.get('mcp-session-id') || session
    if (note) return null
    const raw = await r.text()
    const data = raw.split('\n').filter((l) => l.startsWith('data:')).pop()
    return JSON.parse(data ? data.slice(5) : raw)
  }
  const init = await rpc('initialize', { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'fraim-queue', version: '1' } })
  await rpc('notifications/initialized', {}, true)
  const call = async (name, args) => {
    const out = await rpc('tools/call', { name, arguments: args })
    const text = out.result?.content?.[0]?.text
    if (out.error || out.result?.isError || typeof text !== 'string') throw new Error(`Gmail did not answer: ${out.error?.message || text || 'empty answer'}`)
    return text
  }
  call.account = init.result?.instructions?.match(/^Connected Google account: ([^\s/#?]+@[^\s/#?]+)$/m)?.[1]
  return call
}

// Path /u/0 is whichever account the browser signed in to first, so name the account when known.
const gmailUrl = (thread, account) => `https://mail.google.com/mail/u/${account || 0}/#all/${thread}`

export async function captureMail(gmailThread, quiet = false) {
  if (!/^[\w-]{6,64}$/.test(gmailThread || '')) usage('thread mail needs the Thread ID of the mail')
  const call = await mcpCaller(process.env.FRAIM_GOOGLE_MCP || 'http://google:8000/mcp')
  const text = await call('get_gmail_thread_content', { thread_id: gmailThread })
  const html = await call('get_gmail_thread_content', { thread_id: gmailThread, body_format: 'html' })
  const parsed = parseGmailThread(text, html)
  if (!parsed.messages.length) throw new Error('that mail chain has no messages')
  if (neverShow(parsed.messages.at(-1).address)) return { thread: null, isNew: false, news: false }
  const r = putThread({ kind: 'email', key: `gmail:${gmailThread}`, url: gmailUrl(gmailThread, call.account), ...parsed })
  if (r.news && !quiet) announce(r)
  return r
}
