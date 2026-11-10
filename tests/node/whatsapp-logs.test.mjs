// The WhatsApp encryption library prints session objects with their private keys. None may reach the logs.
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { test } from 'node:test'
import { guardConsole } from '../../whatsapp/lib.mjs'

function fakeConsole() {
  const lines = []
  const fake = {}
  for (const method of ['log', 'info', 'warn', 'error', 'debug', 'trace']) {
    fake[method] = (...args) => lines.push(args)
  }
  return { fake, lines }
}

test('console output never shows the objects the encryption library prints', () => {
  const { fake, lines } = fakeConsole()
  guardConsole(fake)

  const session = { currentRatchet: { ephemeralKeyPair: { privKey: Buffer.from('secret-key') } } }
  fake.info('Closing session:', session)
  fake.warn('Session already closed', session)
  fake.log(Buffer.from('secret-key'))
  fake.dir(session)
  fake.table([session])

  assert.doesNotMatch(JSON.stringify(lines), /privKey|ratchet|secret-key|115,101,99/i)
  assert.deepEqual(lines[0], ['Closing session:', '[hidden]'])
  assert.equal(lines.length, 5)
})

test('console output keeps text, numbers and error messages', () => {
  const { fake, lines } = fakeConsole()
  guardConsole(fake)

  fake.log('Scan this QR code', 3, null)
  fake.error(new TypeError('bad session'))

  assert.deepEqual(lines, [['Scan this QR code', 3, null], ['TypeError: bad session']])
})

test('the gateway turns the console guard on', async () => {
  const source = await readFile(new URL('../../whatsapp/gateway.mjs', import.meta.url), 'utf8')
  assert.match(source, /^guardConsole\(\)$/m)
})
