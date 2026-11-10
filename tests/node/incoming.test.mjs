// What a WhatsApp message contains: its text, its file, and the message it replies to.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { describeShare, mediaFileName, mediaOf, quotedOf, textOf, tooLarge } from '../../whatsapp/lib.mjs'
import { withQuote } from '../../workspace/channel/quote.mjs'
import { withVideo } from '../../workspace/channel/voice.mjs'

const ME = ['31611111111:12@s.whatsapp.net', '999:3@lid']

test('every kind of file counts as media', () => {
  const m = (mimetype) => ({ mimetype })
  assert.equal(mediaOf({ imageMessage: m('image/jpeg') }).kind, 'image')
  assert.equal(mediaOf({ videoMessage: m('video/mp4') }).kind, 'video')
  assert.equal(mediaOf({ ptvMessage: m('video/mp4') }).kind, 'video')
  assert.equal(mediaOf({ audioMessage: m('audio/ogg') }).kind, 'audio')
  assert.equal(mediaOf({ stickerMessage: m('image/webp') }).kind, 'sticker')
  assert.equal(mediaOf({ documentMessage: m('application/pdf') }).kind, 'document')
})

test('an audio or video file sent as a document is handled as audio or video', () => {
  assert.equal(mediaOf({ documentMessage: { mimetype: 'audio/mp4' } }).kind, 'audio')
  assert.equal(mediaOf({ documentMessage: { mimetype: 'video/mp4' } }).kind, 'video')
})

test('a message without a file has no media', () => {
  assert.equal(mediaOf({ conversation: 'hi' }), null)
})

test('text comes from the message or from the caption of any file', () => {
  assert.equal(textOf({ conversation: 'a' }), 'a')
  assert.equal(textOf({ extendedTextMessage: { text: 'b' } }), 'b')
  assert.equal(textOf({ imageMessage: { caption: 'c' } }), 'c')
  assert.equal(textOf({ documentMessage: { caption: 'd' } }), 'd')
  assert.equal(textOf({ videoMessage: { caption: 'e' } }), 'e')
  assert.equal(textOf({ ptvMessage: { caption: 'f' } }), 'f')
  assert.equal(textOf({ stickerMessage: {} }), '')
})

test('a shared contact, location or poll becomes text', () => {
  assert.match(describeShare({ contactMessage: { displayName: 'Daan', vcard: 'TEL:+316' } }), /Daan[\s\S]*TEL:\+316/)
  assert.match(describeShare({ contactsArrayMessage: { contacts: [{ displayName: 'A', vcard: 'x' }, { displayName: 'B', vcard: 'y' }] } }), /A[\s\S]*B/)
  assert.match(describeShare({ locationMessage: { degreesLatitude: 52.1, degreesLongitude: 4.3, name: 'Office' } }), /52\.1.*4\.3.*Office/)
  assert.match(describeShare({ liveLocationMessage: { degreesLatitude: 1.5, degreesLongitude: 2.5 } }), /1\.5.*2\.5/)
  assert.match(describeShare({ pollCreationMessageV3: { name: 'Lunch?', options: [{ optionName: 'Yes' }, { optionName: 'No' }] } }), /Lunch\?.*Yes.*No/)
  assert.equal(describeShare({ conversation: 'hi' }), '')
  assert.equal(describeShare({ reactionMessage: { text: 'x' } }), '')
})

test('a file name keeps only safe characters', () => {
  assert.equal(mediaFileName({ fileName: 'Offerte mei.pdf' }, 'T'), 'T-Offerte_mei.pdf')
  assert.doesNotMatch(mediaFileName({ fileName: 'x.$(rm -rf ~)' }, 'T'), /[$( ~]/)
  assert.doesNotMatch(mediaFileName({ fileName: '../../etc/passwd' }, 'T'), /\//)
})

test('a file without a name gets its extension from the file type', () => {
  assert.equal(mediaFileName({ mimetype: 'image/jpeg' }, 'T'), 'T-attachment.jpeg')
  assert.equal(mediaFileName({ mimetype: 'audio/ogg; codecs=opus' }, 'T'), 'T-attachment.ogg')
})

test('a file without a usable type still gets a name', () => {
  assert.equal(mediaFileName({}, 'T'), 'T-attachment.bin')
  assert.equal(mediaFileName({ mimetype: 'strange' }, 'T'), 'T-attachment.bin')
  assert.equal(mediaFileName({ mimetype: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }, 'T'), 'T-attachment.bin')
})

test('files above the limit are refused, also when WhatsApp gives the size as an object', () => {
  const big = { toString: () => String(600 * 1024 * 1024) }
  assert.equal(tooLarge({ fileLength: big }), true)
  assert.equal(tooLarge({ fileLength: 1000 }), false)
  assert.equal(tooLarge({}), false)
})

test('a message that is no reply has no quote', () => {
  assert.equal(quotedOf({ conversation: 'hi' }, ME), null)
  assert.equal(quotedOf({ extendedTextMessage: { text: 'hi', contextInfo: {} } }, ME), null)
})

test('a reply to a message from the server is recognised', () => {
  const inner = { extendedTextMessage: { text: 'ok', contextInfo: { stanzaId: 'A1', participant: '31611111111@s.whatsapp.net', quotedMessage: { conversation: 'Shall I merge?' } } } }
  const quote = quotedOf(inner, ME)
  assert.equal(quote.id, 'A1')
  assert.equal(quote.from, 'server')
  assert.equal(quote.text, 'Shall I merge?')
})

test('a reply to the server on a hidden number (lid) is recognised', () => {
  const inner = { extendedTextMessage: { text: 'ok', contextInfo: { participant: '999@lid', quotedMessage: { conversation: 'x' } } } }
  assert.equal(quotedOf(inner, ME).from, 'server')
})

test('a reply to the sender\'s own message is recognised', () => {
  const inner = { extendedTextMessage: { text: 'ok', contextInfo: { participant: '31622222222@s.whatsapp.net', quotedMessage: { conversation: 'x' } } } }
  assert.equal(quotedOf(inner, ME).from, 'sender')
})

test('a reply can sit on a photo or a file', () => {
  const inner = { imageMessage: { caption: 'this one', contextInfo: { quotedMessage: { conversation: 'which?' } } } }
  assert.equal(quotedOf(inner, ME).text, 'which?')
})

test('a reply to a photo carries the caption and the photo', () => {
  const photo = { imageMessage: { caption: 'invoice', mimetype: 'image/jpeg' } }
  const inner = { extendedTextMessage: { text: 'pay it', contextInfo: { quotedMessage: photo } } }
  const quote = quotedOf(inner, ME)
  assert.equal(quote.text, 'invoice')
  assert.equal(quote.message, photo)
})

const voiceNever = () => assert.fail('nothing to transcribe')

test('without a reply the text stays the same', async () => {
  const out = await withQuote({ text: 'hello' }, voiceNever)
  assert.equal(out.text, 'hello')
})

test('the reply says which message it belongs to and keeps the new text', async () => {
  const out = await withQuote({ text: 'ok', quote: { from: 'server', text: 'Shall I merge?' } }, voiceNever)
  assert.match(out.text, /your earlier message/i)
  assert.match(out.text, /Shall I merge\?/)
  assert.match(out.text, /ok$/)
})

test('a reply to the sender\'s own message names that', async () => {
  const out = await withQuote({ text: 'ok', quote: { from: 'sender', text: 'x' } }, voiceNever)
  assert.match(out.text, /their own earlier message/i)
})

test('a reply to a file names the file', async () => {
  const out = await withQuote({ text: 'pay it', quote: { from: 'sender', text: '', file: '~/fraim/inbox/a.jpeg', kind: 'image' } }, voiceNever)
  assert.match(out.text, /~\/fraim\/inbox\/a\.jpeg/)
})

test('a reply to a voice message carries its words', async () => {
  const out = await withQuote({ text: 'yes', quote: { from: 'sender', text: '', file: '~/fraim/inbox/a.ogg', kind: 'audio' } }, async () => 'bel de drukker')
  assert.match(out.text, /bel de drukker/)
})

test('a long quote is cut, so it cannot fill the conversation', async () => {
  const out = await withQuote({ text: 'ok', quote: { from: 'server', text: 'x'.repeat(10000) } }, voiceNever)
  assert.ok(out.text.length < 3000)
})

test('a message without a video stays the same', async () => {
  const out = await withVideo({ text: 'hello' }, voiceNever, voiceNever)
  assert.equal(out.text, 'hello')
})

test('a video gives its frames and its spoken words', async () => {
  const out = await withVideo({ text: 'look', video: '~/fraim/inbox/v.mp4' }, async () => 'de deur klemt', async () => ['/x/f1.jpg', '/x/f2.jpg'])
  assert.match(out.text, /look/)
  assert.match(out.text, /~\/fraim\/inbox\/v\.mp4/)
  assert.match(out.text, /\/x\/f1\.jpg.*\/x\/f2\.jpg/)
  assert.match(out.text, /de deur klemt/)
})

test('a video without sound still gives its frames', async () => {
  const out = await withVideo({ text: '', video: 'v.mp4' }, async () => { throw new Error('no audio') }, async () => ['/x/f1.jpg'])
  assert.match(out.text, /\/x\/f1\.jpg/)
  assert.match(out.text, /no spoken words/i)
})

test('a video without readable frames still names the file', async () => {
  const out = await withVideo({ text: '', video: 'v.mp4' }, async () => 'woorden', async () => { throw new Error('bad') })
  assert.match(out.text, /v\.mp4/)
  assert.match(out.text, /woorden/)
})
