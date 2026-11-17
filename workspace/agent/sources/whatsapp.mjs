// WhatsApp in: the gateway's event stream becomes inbox events. This only writes events;
// the worker decides what happens. The message id dedups a delivery that arrives twice.

export function toEvent(msg) {
  if (msg?.type !== 'message' || !msg.id) return null
  const payload = {
    chat_id: msg.chat_id,
    sender: msg.sender,
    name: msg.name || '',
    text: msg.text || '',
  }
  for (const key of ['group', 'addressed', 'quote', 'voice', 'video', 'files', 'ts']) {
    if (msg[key] !== undefined) payload[key] = msg[key]
  }
  return { source: 'whatsapp', source_id: msg.id, kind: 'message', payload }
}

export function* frames(buffer) {
  let end
  let rest = buffer
  while ((end = rest.indexOf('\n\n')) !== -1) {
    const frame = rest.slice(0, end)
    rest = rest.slice(end + 2)
    const data = frame.split('\n').filter((l) => l.startsWith('data:')).map((l) => l.slice(5).trimStart()).join('\n')
    yield { data, rest }
  }
}

export async function listen({ url, token, inbox, log = () => {}, signal }) {
  let delay = 1000
  while (!signal?.aborted) {
    try {
      const res = await fetch(`${url}/events`, { headers: { Authorization: `Bearer ${token}` }, signal })
      if (!res.ok || !res.body) throw new Error(`events stream returned ${res.status}`)
      log('whatsapp: connected to gateway')
      delay = 1000
      const decoder = new TextDecoder()
      let buffer = ''
      for await (const chunk of res.body) {
        buffer += decoder.decode(chunk, { stream: true })
        for (const { data, rest } of frames(buffer)) {
          buffer = rest
          if (!data) continue
          try {
            const event = toEvent(JSON.parse(data))
            if (event) inbox.add(event)
          } catch (err) {
            log(`whatsapp: could not read an event: ${err.message}`)
          }
        }
      }
      throw new Error('events stream closed')
    } catch (err) {
      if (signal?.aborted) return
      log(`whatsapp: ${err.message}; retrying in ${Math.round(delay / 1000)}s`)
      await new Promise((r) => setTimeout(r, delay))
      delay = Math.min(delay * 2, 30000)
    }
  }
}
