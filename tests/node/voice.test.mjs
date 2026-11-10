// Voice messages on WhatsApp: which messages count as audio, and what Claude reads for them.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { audioOf } from '../../whatsapp/lib.mjs'
import { inOrder, withTranscript } from '../../workspace/channel/voice.mjs'

const voice = { type: 'message', text: '', voice: '~/fraim/inbox/memo.ogg' }

test('a voice note and an audio file sent as a document count as audio', () => {
  const note = { mimetype: 'audio/ogg; codecs=opus', ptt: true }
  const file = { mimetype: 'audio/mp4', fileName: 'memo.m4a' }
  assert.equal(audioOf({ audioMessage: note }), note)
  assert.equal(audioOf({ documentMessage: file }), file)
})

test('other messages do not count as audio', () => {
  assert.equal(audioOf({ conversation: 'hi' }), null)
  assert.equal(audioOf({ imageMessage: { mimetype: 'image/jpeg' } }), null)
  assert.equal(audioOf({ documentMessage: { mimetype: 'application/pdf' } }), null)
  assert.equal(audioOf({ documentMessage: {} }), null)
})

test('a message without audio stays the same and is never transcribed', async () => {
  const event = { type: 'message', text: 'hello' }
  const out = await withTranscript(event, () => assert.fail('transcribed a text message'))
  assert.equal(out.text, 'hello')
})

test('the transcript becomes the text and names the audio file', async () => {
  const out = await withTranscript(voice, async (file) => {
    assert.equal(file, '~/fraim/inbox/memo.ogg')
    return 'bel de drukker morgen'
  })
  assert.match(out.text, /bel de drukker morgen/)
  assert.match(out.text, /transcribed/i)
  assert.match(out.text, /~\/fraim\/inbox\/memo\.ogg/)
})

test('a caption on the audio stays with the transcript', async () => {
  const out = await withTranscript({ ...voice, text: 'for the printer' }, async () => 'bel de drukker')
  assert.match(out.text, /for the printer/)
  assert.match(out.text, /bel de drukker/)
})

test('a failed transcription still reaches Claude and asks the sender to type it', async () => {
  const out = await withTranscript(voice, async () => { throw new Error('no memory') })
  assert.match(out.text, /could not be transcribed/i)
  assert.match(out.text, /ask the sender to type/i)
  assert.match(out.text, /~\/fraim\/inbox\/memo\.ogg/)
})

test('audio without words says so', async () => {
  const out = await withTranscript(voice, async () => '  \n')
  assert.match(out.text, /no speech/i)
})

test('messages are handled one at a time, in the order they came', async () => {
  const run = inOrder(() => {})
  const seen = []
  let release
  const slow = new Promise((resolve) => { release = resolve })
  run(async () => { await slow; seen.push('voice') })
  const last = run(async () => { seen.push('text') })
  await new Promise((resolve) => setImmediate(resolve))
  assert.deepEqual(seen, [])
  release()
  await last
  assert.deepEqual(seen, ['voice', 'text'])
})

test('a failing message is reported and the next one still runs', async () => {
  const errors = []
  const run = inOrder((err) => errors.push(err.message))
  run(async () => { throw new Error('broken') })
  let ran = false
  await run(async () => { ran = true })
  assert.deepEqual(errors, ['broken'])
  assert.equal(ran, true)
})
