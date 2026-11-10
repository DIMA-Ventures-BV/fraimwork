// Answering people outside: an agent drafts, and only the owner's yes sends the text they saw.
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { chmod, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises'
import http from 'node:http'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'
import { contactChat, contactSender, parseContacts } from '../../whatsapp/lib.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const bin = path.join(here, '../../workspace/bin/fraim-queue')
const run = promisify(execFile)
const until = async (check) => {
  for (let i = 0; i < 100; i++) {
    const out = await check()
    if (out) return out
    await new Promise((r) => setTimeout(r, 50))
  }
  throw new Error('timed out')
}

async function sender(t, answer = () => [200, { ok: true }]) {
  const calls = []
  const server = http.createServer((req, res) => {
    let raw = ''
    req.on('data', (c) => { raw += c })
    req.on('end', () => {
      calls.push({ route: req.url, auth: req.headers.authorization, body: JSON.parse(raw) })
      const [status, body] = req.url === '/who'
        ? [200, { name: 'Anna', to: 'anna@example.com', subject: 'Re: Login' }]
        : answer(req.url)
      res.writeHead(status, { 'Content-Type': 'application/json' })
      res.end(JSON.stringify(body))
    })
  })
  await new Promise((r) => server.listen(0, '127.0.0.1', r))
  t.after(() => server.close())
  return { calls, url: `http://127.0.0.1:${server.address().port}` }
}

async function setup(t, answer) {
  const home = await mkdtemp(path.join(tmpdir(), 'fraim-replies-'))
  await mkdir(path.join(home, 'bin'))
  const told = path.join(home, 'told')
  for (const f of ['fraim-lead', 'fraim-notify']) {
    await writeFile(path.join(home, 'bin', f), `#!/bin/sh\nprintf '%s\\n' "$*" >> ${told}\n`)
    await chmod(path.join(home, 'bin', f), 0o755)
  }
  await mkdir(path.join(home, 'fraim/leads/chief'), { recursive: true })
  await writeFile(path.join(home, 'fraim/leads/chief/lead.md'), '---\nrole: chief\n---\n')
  const { calls, url } = await sender(t, answer)
  const env = {
    PATH: `${path.join(home, 'bin')}:${process.env.PATH}`, HOME: home, FRAIM_RUNTIME_ENV: '/dev/null',
    FRAIM_REPLY_TOKEN: 'reply-secret', FRAIM_REPLY_MAIL_URL: url, FRAIM_GATEWAY_URL: url,
  }
  const cli = async (args, extra = {}) => (await run(process.execPath, [bin, ...args], { env: { ...env, ...extra } })).stdout.trim()
  const item = async (id) => JSON.parse(await cli(['show', id, '--json']))
  const put = (key, kind) => new Promise((resolve, reject) => {
    const child = execFile(process.execPath, [bin, 'thread', 'put', '--quiet'], { env }, (err, out) => (err ? reject(err) : resolve(out.trim())))
    child.stdin.end(JSON.stringify({ kind, key, title: 'Login', who: 'Anna' }))
  })
  const sent = () => calls.filter((c) => c.route === '/reply')
  return { home, cli, item, put, calls, sent, told }
}

test('nothing goes out before the yes, and the yes sends the text the owner saw', async (t) => {
  const { cli, item, put, calls, sent, told } = await setup(t)
  const thread = await put('gmail:chain0001', 'email')
  const id = await cli(['reply', thread, '--lead', 'chief', '--', 'Hello Anna'])
  assert.equal(sent().length, 0)

  const card = await item(id)
  assert.equal(card.state, 'open')
  assert.equal(card.reply.to, 'anna@example.com')
  assert.match(card.summary, /Hello Anna/)
  assert.match(await readFile(told, 'utf8'), /Hello Anna/)

  await cli(['approve', id])
  await until(() => sent().length === 1)
  assert.deepEqual(sent()[0].body, { thread_id: 'chain0001', to: 'anna@example.com', text: 'Hello Anna' })
  assert.equal(calls[0].auth, 'Bearer reply-secret')
  await until(async () => (await item(id)).reply.status === 'sent')
  assert.match(await cli(['thread', 'show', thread]), /Sent to Anna/)

  await assert.rejects(cli(['send-reply', id]), /not an approved reply/)
  assert.equal(sent().length, 1)
})

test('a run nobody watches cannot approve, and only an approved card can be sent', async (t) => {
  const { cli, put, sent } = await setup(t)
  const id = await cli(['reply', await put('gmail:chain0002', 'email'), '--', 'Hi'])
  await assert.rejects(cli(['approve', id], { FRAIM_HEADLESS: '1' }), /only the owner decides/)
  await assert.rejects(cli(['send-reply', id]), /not an approved reply/)
  assert.equal(sent().length, 0)
})

test('a yes on a reply is not a yes for anything else', async (t) => {
  const { cli, item, put } = await setup(t)
  const id = await cli(['reply', await put('gmail:chain0003', 'email'), '--', 'Hi'])
  await cli(['approve', id])
  await until(async () => (await item(id)).reply.status === 'sent')
  const other = await cli(['add', '--title', 'Spend money', '--ask', 'Ok?', '--on-approve', 'x', '--approved-by', id, '--quiet']).catch((e) => e)
  assert.equal((await item(String(other))).state, 'open')
})

test('a card cannot be turned into a reply from the command line', async (t) => {
  const { cli, item } = await setup(t)
  const id = await cli(['add', '--title', 'T', '--reply', 'x', '--quiet'])
  assert.equal((await item(id)).reply, undefined)
})

test('a task cannot draft, and a conversation without a person cannot be answered', async (t) => {
  const { cli, put } = await setup(t)
  const mail = await put('gmail:chain0004', 'email')
  await assert.rejects(cli(['reply', mail, '--', 'Hi'], { FRAIM_GOAL: 'g1' }), /a task does not answer/)
  await assert.rejects(cli(['reply', await put('linear:1', 'linear'), '--', 'Hi']), /only a mail or a WhatsApp/)
})

test('a new draft takes the place of the one that waits', async (t) => {
  const { cli, item, put } = await setup(t)
  const thread = await put('gmail:chain0005', 'email')
  const first = await cli(['reply', thread, '--', 'One'])
  const second = await cli(['reply', thread, '--', 'Two'])
  assert.equal((await item(first)).state, 'dismissed')
  assert.equal((await item(second)).state, 'open')
})

test('a refused send puts the question back with the reason', async (t) => {
  const { cli, item, put, told } = await setup(t, () => [409, { error: 'a newer mail changed the address' }])
  const id = await cli(['reply', await put('gmail:chain0006', 'email'), '--', 'Hi'])
  await cli(['approve', id])
  await until(async () => (await item(id)).reply.status === 'failed')
  const card = await item(id)
  assert.equal(card.state, 'open')
  assert.match(card.reply.error, /newer mail/)
  assert.match(await readFile(told, 'utf8'), /did not go out/)
})

test('a contact on WhatsApp becomes one conversation, and the answer goes to that number', async (t) => {
  const { cli, item, sent, told } = await setup(t)
  const thread = await cli(['thread', 'whatsapp', '--number', '31612345678', '--name', 'Bram', '--', 'Is it ready?'])
  assert.equal(await cli(['thread', 'whatsapp', '--number', '31612345678', '--name', 'Bram', '--', 'Hello?']), thread)
  const shown = await cli(['thread', 'show', thread])
  assert.match(shown, /Is it ready\?/)
  assert.match(shown, /Hello\?/)
  assert.match(await readFile(told, 'utf8'), /WhatsApp/)

  const id = await cli(['reply', thread, '--', 'Friday'])
  assert.equal((await item(id)).reply.to, '31612345678')
  await cli(['approve', id])
  await until(() => sent().length === 1)
  assert.deepEqual(sent()[0].body, { to: '31612345678', text: 'Friday' })
})

test('whatsapp rules: contacts are separate from the allowlist', () => {
  const contacts = parseContacts('+31 6 12345678,31687654321')
  const allow = new Set(['31611111111'])
  const key = (n) => ({ remoteJid: `${n}@s.whatsapp.net` })
  assert.equal(contactSender(key('31612345678'), allow, contacts), '31612345678')
  assert.equal(contactSender(key('31699999999'), allow, contacts), '')
  assert.equal(contactSender(key('31611111111'), allow, new Set(['31611111111'])), '')
  assert.equal(contactSender({ remoteJid: '123@g.us' }, allow, contacts), '')
  assert.equal(contactChat('31612345678', contacts), '31612345678@s.whatsapp.net')
  assert.throws(() => contactChat('31699999999', contacts), /not in WHATSAPP_CONTACTS/)
})
