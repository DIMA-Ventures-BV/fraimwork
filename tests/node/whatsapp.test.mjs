// WhatsApp safety rules: the allowlist, reply targets, file sharing and owner-only approvals.
import assert from 'node:assert/strict'
import { mkdir, mkdtemp, readFile, realpath, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { test } from 'node:test'
import {
  addressesMe,
  allowedSender,
  groupSender,
  guardConsole,
  parseAllowlist,
  parseGroups,
  resolveChat,
  resolveSharedPath,
} from '../../whatsapp/lib.mjs'
import { parseVerdict } from '../../workspace/channel/verdict.mjs'

const OWNER = '31612345678'
const allow = parseAllowlist('+31 6 1234 5678', '0049 151 1234 5678, ,447700900123')
const jid = (n) => `${n}@s.whatsapp.net`

test('allowlist normalizes the owner and extra numbers and drops blanks', () => {
  assert.deepEqual([...allow].sort(), ['31612345678', '447700900123', '4915112345678'])
  assert.equal(parseAllowlist('', '').size, 0)
})

test('messages from allowed numbers pass, with the sender phone', () => {
  assert.equal(allowedSender({ remoteJid: jid(OWNER) }, allow), OWNER)
  assert.equal(allowedSender({ remoteJid: `${OWNER}:12@s.whatsapp.net` }, allow), OWNER)
})

test('messages from LID chats pass only through the real phone number', () => {
  assert.equal(allowedSender({ remoteJid: '123456789@lid', senderPn: jid(OWNER) }, allow), OWNER)
  assert.equal(allowedSender({ remoteJid: '123456789@lid', senderPn: jid('31699999999') }, allow), '')
  assert.equal(allowedSender({ remoteJid: '123456789@lid' }, allow), '')
})

test('strangers, groups, broadcasts and own messages are dropped', () => {
  assert.equal(allowedSender({ remoteJid: jid('31699999999') }, allow), '')
  assert.equal(allowedSender({ remoteJid: '1203630@g.us', participant: jid(OWNER) }, allow), '')
  assert.equal(allowedSender({ remoteJid: 'status@broadcast', participant: jid(OWNER) }, allow), '')
  assert.equal(allowedSender({ remoteJid: jid(OWNER), fromMe: true }, allow), '')
  assert.equal(allowedSender({}, allow), '')
  assert.equal(allowedSender(undefined, allow), '')
})

test('an empty allowlist drops everything', () => {
  assert.equal(allowedSender({ remoteJid: jid(OWNER) }, new Set()), '')
})

test('replies go only to allowed numbers or chats an allowed sender used', () => {
  const known = new Set(['123456789@lid'])
  assert.equal(resolveChat({ to: '+31 6 1234 5678' }, known, allow), jid(OWNER))
  assert.equal(resolveChat({ chat_id: '123456789@lid' }, known, allow), '123456789@lid')
  assert.throws(() => resolveChat({ to: '31699999999' }, known, allow), { status: 403 })
  assert.throws(() => resolveChat({ chat_id: '1203630@g.us' }, known, allow), { status: 403 })
  assert.throws(() => resolveChat({}, known, allow), { status: 400 })
})

test('shared files resolve inside their root and nowhere else', async () => {
  const base = await realpath(await mkdtemp(path.join(tmpdir(), 'fraim-wa-')))
  const roots = { fraim: path.join(base, 'fraim'), pc: path.join(base, 'pc'), 'fraim/inbox': path.join(base, 'inbox') }
  await mkdir(path.join(roots.fraim, 'docs'), { recursive: true })
  await mkdir(roots.pc, { recursive: true })
  await mkdir(roots['fraim/inbox'], { recursive: true })
  await writeFile(path.join(roots.fraim, 'docs', 'a.pdf'), 'x')
  await writeFile(path.join(roots['fraim/inbox'], 'b.png'), 'x')
  await writeFile(path.join(base, 'secret.env'), 'x')
  await symlink(path.join(base, 'secret.env'), path.join(roots.fraim, 'link.env'))

  assert.equal(await resolveSharedPath('fraim/docs/a.pdf', roots), path.join(roots.fraim, 'docs', 'a.pdf'))
  assert.equal(await resolveSharedPath('fraim/inbox/b.png', roots), path.join(roots['fraim/inbox'], 'b.png'))

  for (const bad of ['fraim/../secret.env', 'fraim/link.env', 'fraim/inbox/../../secret.env', 'fraim/missing']) {
    await assert.rejects(resolveSharedPath(bad, roots), { status: 404 }, bad)
  }
  for (const bad of ['/etc/passwd', 'etc/passwd', 'fraim', '__proto__/x', 'constructor/x', '']) {
    await assert.rejects(resolveSharedPath(bad, roots), { status: 400 }, bad)
  }
})

test('only the owner can answer a permission prompt', () => {
  const owner = { sender: OWNER }
  assert.deepEqual(parseVerdict({ ...owner, text: 'yes abcde' }, OWNER), { request_id: 'abcde', behavior: 'allow' })
  assert.deepEqual(parseVerdict({ ...owner, text: ' Y ABCDE ' }, OWNER), { request_id: 'abcde', behavior: 'allow' })
  assert.deepEqual(parseVerdict({ ...owner, text: 'no abcde' }, OWNER), { request_id: 'abcde', behavior: 'deny' })

  assert.equal(parseVerdict({ sender: '447700900123', text: 'yes abcde' }, OWNER), null)
  assert.equal(parseVerdict({ sender: '', text: 'yes abcde' }, ''), null)
  assert.equal(parseVerdict({ text: 'yes abcde' }, ''), null)
})

test('a permission answer must be exactly yes/no plus a request id', () => {
  for (const text of ['yes', 'yes abcdef', 'yes abcd', 'yes abcle', 'sure abcde', 'yes abcde please', 'yesabcde']) {
    assert.equal(parseVerdict({ sender: OWNER, text }, OWNER), null, text)
  }
})

const GROUP = '120363012345@g.us'

test('groups stay closed until listed, and only allowed members reach Claude there', () => {
  const open = parseGroups(` ${GROUP}, nonsense`)
  assert.equal(groupSender({ remoteJid: GROUP, participant: jid(OWNER) }, allow, parseGroups('')), '')
  assert.equal(groupSender({ remoteJid: GROUP, participant: jid(OWNER) }, allow, open), OWNER)
  assert.equal(groupSender({ remoteJid: GROUP, participant: '999@lid', participantAlt: jid('447700900123') }, allow, open), '447700900123')
  assert.equal(groupSender({ remoteJid: GROUP, participant: jid('31699999999') }, allow, open), '')
  assert.equal(groupSender({ remoteJid: GROUP, participant: jid(OWNER), fromMe: true }, allow, open), '')
  assert.equal(groupSender({ remoteJid: '1203639999@g.us', participant: jid(OWNER) }, allow, open), '')
  assert.equal(groupSender({ remoteJid: '1203639999@g.us', participant: jid(OWNER) }, allow, parseGroups('all')), OWNER)
  assert.equal(groupSender({ remoteJid: 'status@broadcast', participant: jid(OWNER) }, allow, parseGroups('all')), '')
})

test('a group message is addressed when it mentions the server or replies to it', () => {
  const me = ['31600000000:4@s.whatsapp.net', '555:4@lid']
  assert.equal(addressesMe({ extendedTextMessage: { contextInfo: { mentionedJid: ['555@lid'] } } }, me), true)
  assert.equal(addressesMe({ extendedTextMessage: { contextInfo: { mentionedJid: [jid(OWNER)] } } }, me), false)
  assert.equal(addressesMe({ conversation: 'hi' }, me, { from: 'server' }), true)
  assert.equal(addressesMe({ conversation: 'hi' }, me), false)
})

test('replies may go to an open group, never to a closed one', () => {
  assert.equal(resolveChat({ chat_id: GROUP }, new Set(), allow, parseGroups(GROUP)), GROUP)
  assert.equal(resolveChat({ chat_id: '1203639999@g.us' }, new Set(), allow, parseGroups('all')), '1203639999@g.us')
  assert.throws(() => resolveChat({ chat_id: '1203639999@g.us' }, new Set(), allow, parseGroups(GROUP)), { status: 403 })
})
