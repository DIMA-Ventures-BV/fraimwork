// A WhatsApp swipe-reply: Claude reads which earlier message the sender means.
const MAX_QUOTE = 2000

const WHO = { server: 'your earlier message', sender: 'their own earlier message' }

async function spoken(quote, transcribe) {
  if (quote.kind !== 'audio' || !quote.file) return ''
  try {
    return (await transcribe(quote.file)).trim()
  } catch {
    return ''
  }
}

export async function withQuote(event, transcribe) {
  const quote = event.quote
  if (!quote) return event
  const said = (quote.text || await spoken(quote, transcribe)).slice(0, MAX_QUOTE)
  const parts = [`(This message replies to ${WHO[quote.from] || 'an earlier message'}`]
  if (said) parts.push(`: "${said}"`)
  if (quote.file) parts.push(`, with this file: ${quote.file}`)
  parts.push('. Read the message below as being about that.)')
  return { ...event, text: `${parts.join('')}\n${event.text || ''}` }
}
