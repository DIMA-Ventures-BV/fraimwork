// The inbox: conversations saved from the source, mail chains, and the agents' chat.
import assert from 'node:assert/strict'
import { execFile, execFileSync, spawn } from 'node:child_process'
import { chmod, mkdir, mkdtemp, writeFile } from 'node:fs/promises'
import fs from 'node:fs'
import http from 'node:http'
import net from 'node:net'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

const here = path.dirname(fileURLToPath(import.meta.url))
const bin = path.join(here, '../../workspace/bin/fraim-queue')

const freePort = () => new Promise((resolve) => {
  const s = net.createServer()
  s.listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => resolve(port)) })
})

const message = (n, from, body) => `=== Message ${n} ===\nFrom: ${from}\nDate: Tue, 10 Nov 2026 09:0${n}:00 +0100\nTo: Support <support@example.com>\nCc: [not present in Gmail response]\nMessage-ID: <m${n}@example.com>\n\n${body}\n\n`
const head = (subject, n) => `Thread ID: x\nSubject: ${subject}\nMessages: ${n}\n\n`

function fakeGmail(threads) {
  return http.createServer((req, res) => {
    let raw = ''
    req.on('data', (c) => { raw += c })
    req.on('end', () => {
      const m = JSON.parse(raw)
      if (m.id === undefined) { res.writeHead(202); return res.end() }
      let result = {}
      if (m.method === 'tools/call') {
        const t = threads[m.params.arguments.thread_id]
        const text = t ? (m.params.arguments.body_format === 'html' ? t.html || t.text : t.text) : ''
        result = t ? { content: [{ type: 'text', text }] } : { isError: true, content: [{ type: 'text', text: 'no such thread' }] }
      }
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'mcp-session-id': 's1' })
      res.end(`event: message\ndata: ${JSON.stringify({ jsonrpc: '2.0', id: m.id, result })}\n\n`)
    })
  })
}

test('a mail chain is one conversation, shown as it came in, with the agents talking next to it', async (t) => {
  const home = await mkdtemp(path.join(tmpdir(), 'fraim-threads-'))
  await mkdir(path.join(home, 'bin'))
  const told = path.join(home, 'told')
  await writeFile(path.join(home, 'bin/fraim-lead'), `#!/bin/sh\nprintf '%s\\n' "$*" >> ${told}\n`)
  await writeFile(path.join(home, 'bin/fraim-notify'), '#!/bin/sh\nexit 0\n')
  await writeFile(path.join(home, 'bin/fraim-herdr'), '#!/bin/sh\necho "[]"\n')
  const asked = path.join(home, 'asked')
  await writeFile(path.join(home, 'bin/fraim-relay'), `#!/bin/sh\nprintf '%s\\n' "$*" > ${asked}\n`)
  for (const f of ['fraim-lead', 'fraim-notify', 'fraim-herdr', 'fraim-relay']) await chmod(path.join(home, 'bin', f), 0o755)
  await mkdir(path.join(home, 'fraim/leads/chief'), { recursive: true })
  await mkdir(path.join(home, 'fraim/leads/mlv-platform'), { recursive: true })
  await writeFile(path.join(home, 'fraim/leads/chief/lead.md'), '---\nrole: chief\n---\n')
  await writeFile(path.join(home, 'fraim/leads/mlv-platform/lead.md'), '---\nrole: lead\ndisplay: Platform\n---\n## Area\nThe whole web app.\n')
  await writeFile(path.join(home, 'fraim/leads/mlv-platform/tools'), 'mcp__linear\nBash(git fetch:*)\nmcp__github-mcp__get_issue\n')
  await mkdir(path.join(home, 'fraim/automations/mlv-platform'), { recursive: true })
  await writeFile(path.join(home, 'fraim/automations/mlv-platform/automation.md'), '---\nschedule: "0 6 * * 1-5"\nlead: mlv-platform\n---\n')
  await mkdir(path.join(home, 'fraim/projects/shop'), { recursive: true })
  await writeFile(path.join(home, 'fraim/projects/shop/installed.tsv'), 'lead\tmlv-platform\tabc\n')
  await mkdir(path.join(home, 'fraim/prompts'))
  await writeFile(path.join(home, 'fraim/prompts/thread-owner.md'), 'The boss says: {{text}}\n')

  const quoted = 'Yes please.\n\nOn Tue, 10 Nov 2026 at 09:01, Support <support@example.com> wrote:\n> Which book?\n> Thanks'
  const threads = {
    chain0001: { text: head('Re: Re: Login', 2) + message(1, 'Anna de Vries <anna@example.com>', 'I cannot log in.') + message(2, '"Anna de Vries" <anna@example.com>', quoted) },
    forward01: { text: head('Fwd: Je inloglink', 1) + message(1, 'Daan <daan@example.com>', 'fyi\n\n---------- Forwarded message ---------\nFrom: Klant Een <klant@example.com>\nDate: Tue, Nov 10, 2026 at 12:17 AM\nSubject: Je inloglink\nTo: Support <support@example.com>\n\nDe link werkt niet.\n\n--- ATTACHMENTS ---\n1. foto.png (image/png, 21.5 KB)\n   Attachment ID: abc') },
    letter001: {
      text: head('Big news', 1) + message(1, 'Shop <news@example.com>', 'View online'),
      html: head('Big news', 1) + message(1, 'Shop <news@example.com>', '<html><head><meta http-equiv="refresh" content="0;url=https://evil.example"><script>alert(1)</script></head><body><img src="https://a/1"><img src="https://a/2"><img src="https://a/3">Sale</body></html>'),
    },
  }
  const gmail = fakeGmail(threads)
  await new Promise((r) => gmail.listen(0, '127.0.0.1', r))
  t.after(() => gmail.close())

  const port = await freePort()
  const env = {
    PATH: `${path.join(home, 'bin')}:${process.env.PATH}`, HOME: home, FRAIM_RUNTIME_ENV: '/dev/null', FRAIM_QUEUE_QUIET: '1',
    FRAIM_QUEUE_PORT: String(port), FRAIM_QUEUE_BIND: '127.0.0.1', FRAIM_GOOGLE_MCP: `http://127.0.0.1:${gmail.address().port}/mcp`,
  }
  const cli = (...args) => execFileSync(process.execPath, [bin, ...args], { env, encoding: 'utf8' }).trim()
  const put = (json, ...args) => execFileSync(process.execPath, [bin, 'thread', 'put', ...args], { env, encoding: 'utf8', input: JSON.stringify(json) }).trim()

  // Not execFileSync: the fake Gmail answers from this same process.
  const mail = async (id) => (await promisify(execFile)(process.execPath, [bin, 'thread', 'mail', id], { env })).stdout.trim()
  assert.equal(await mail('chain0001'), 't1')
  assert.match(fs.readFileSync(told, 'utf8'), /^tell chief --from email --thread t1 -- New email: "Login"/m)
  assert.equal(await mail('chain0001'), 't1', 'the same chain stays one conversation')
  assert.equal(fs.readFileSync(told, 'utf8').split('\n').filter(Boolean).length, 1, 'no news, nobody is told again')
  assert.equal(await mail('forward01'), 't2')
  assert.equal(await mail('letter001'), 't3')
  await assert.rejects(mail('missing001'), /no such thread/)

  assert.equal(put({ kind: 'linear', key: 'MLV-1', who: 'Sanne', title: 'Page missing', text: 'The last page is gone.', fields: { Status: 'Todo' } }, '--quiet'), 't4')
  assert.equal(put({ kind: 'error', key: 'error:pdf', who: 'Website problem', title: 'PDF fails', text: 'x', details: 'TypeError', hit: 3 }, '--quiet'), 't5')
  assert.equal(put({ kind: 'error', key: 'error:pdf', hit: 2 }, '--quiet'), 't5')

  cli('thread', 'say', 't1', '--from', 'chief', '--to', 'mlv-platform', '--', 'Can you look at this?\n\nDetails:\nsrc/auth.ts line 40')
  const q = cli('add', '--title', 'Send a new link?', '--ask', 'Shall I send a new link?', '--lead', 'mlv-platform', '--kind', 'decision', '--thread', 't1', '--quiet')
  const loose = cli('add', '--title', 'Loose review', '--summary', 'Some text', '--quiet')

  const server = spawn(process.execPath, [bin, 'serve'], { env, stdio: ['ignore', 'ignore', 'pipe'] })
  t.after(() => server.kill())
  await new Promise((r) => server.stderr.once('data', r))
  const base = `http://127.0.0.1:${port}`
  const login = await fetch(`${base}/?t=${cli('token')}`, { redirect: 'manual' })
  const cookie = login.headers.get('set-cookie').split(';')[0]
  const get = async (p) => (await fetch(base + p, { headers: { cookie } })).json()
  const post = (p, body) => fetch(base + p, { method: 'POST', headers: { cookie, 'Content-Type': 'application/json', 'X-Fraim-Queue': '1' }, body: JSON.stringify(body) })

  const page = await (await fetch(`${base}/`, { headers: { cookie } })).text()
  assert.match(page, /Write to the agents/)
  assert.match(page, /For you/, 'what is for the owner says so')
  assert.doesNotMatch(page, />(Reply|Forward|Comment)</, 'the middle pane only shows what came in')
  assert.match(await (await fetch(`${base}/team`, { headers: { cookie } })).text(), /Automations/)

  const chain = await get('/api/threads/t1')
  assert.equal(chain.title, 'Login', 'no Re: in front')
  assert.equal(chain.who, 'Anna de Vries')
  assert.equal(chain.messages.length, 2)
  assert.equal(chain.messages[1].text, 'Yes please.', 'the quote is cut')
  assert.match(chain.messages[1].quoted, /Which book/, 'and kept for the owner')
  assert.deepEqual(chain.chat.map((c) => [c.from, c.to, c.text ?? c.item.ask]), [
    ['Chief of staff', 'Platform', 'Can you look at this?'],
    ['Platform', 'You', 'Shall I send a new link?'],
  ], 'people names, and no details')

  const fwd = await get('/api/threads/t2')
  assert.deepEqual([fwd.messages[0].from, fwd.messages[0].forwardedBy, fwd.messages[0].forwardNote, fwd.messages[0].text], ['Klant Een', 'Daan', 'fyi', 'De link werkt niet.'])
  assert.deepEqual(fwd.messages[0].attachments, [{ name: 'foto.png', type: 'image/png', size: '21.5 KB' }])

  const letter = (await get('/api/threads/t3')).messages[0]
  assert.equal(letter.designed, true)
  assert.doesNotMatch(letter.html, /<script|http-equiv/i, 'nothing that can reach outside the frame')

  assert.deepEqual((await get('/api/threads/t5')).stats.count, 5, 'a repeat raises the count')
  const card = await get(`/api/threads/${loose}`)
  assert.deepEqual([card.kind, card.title, card.text], ['item', 'Loose review', 'Some text'], 'anything else gets the plain card')

  let rows = await get('/api/threads')
  const row = (id) => rows.find((r) => r.id === id)
  assert.equal(rows.length, 6)
  assert.deepEqual([row('t1').state, row('t1').unread, row('t1').snippet], ['need', true, 'Platform: Shall I send a new link?'])
  assert.equal((await post('/api/threads/t1/seen', {})).status, 200)
  assert.equal((await post('/api/threads/t1/say', { text: 'Be kind to her' })).status, 200)
  // The page server does not wait for the tell it starts.
  for (let i = 0; i < 50 && !/Be kind to her/.test(fs.readFileSync(told, 'utf8')); i++) await new Promise((r) => setTimeout(r, 100))
  assert.match(fs.readFileSync(told, 'utf8'), /tell chief --from owner --thread t1 -- The boss says: Be kind to her/, "the owner's own file wins")

  await mkdir(path.join(home, 'fraim/relay/chat.lock'), { recursive: true })
  await writeFile(path.join(home, 'fraim/relay/conversation.jsonl'), [
    { time: '2026-11-10 09:00', who: 'owner', chat: '316@lid', about: '', text: 'How is Anna?' },
    { time: '2026-11-10 09:01', who: 'me', chat: '', about: `g4 ${q}`, text: 'She waits for your yes.' },
  ].map((l) => JSON.stringify(l)).join('\n') + '\n')
  const talk = await get('/api/chief')
  assert.deepEqual([talk.exists, talk.typing, talk.messages.map((m) => [m.who, m.text, m.app])], [true, true, [['owner', 'How is Anna?', false], ['chief', 'She waits for your yes.', false]]])
  assert.deepEqual(talk.messages[1].refs, [{ id: 't1', title: 'Login' }], 'a mention opens its conversation')
  assert.equal((await post('/api/chief/say', { text: 'Thanks' })).status, 200)
  // The shell creates the file before it writes to it.
  for (let i = 0; i < 50 && !(fs.existsSync(asked) && fs.statSync(asked).size); i++) await new Promise((r) => setTimeout(r, 100))
  assert.equal(fs.readFileSync(asked, 'utf8').trim(), 'chat -- Thanks')

  const rules = path.join(home, 'fraim/inbox-rules.md')
  assert.equal((await post('/api/threads/t3/dismiss', {})).status, 200)
  let gone = (await get('/api/threads')).find((r) => r.id === 't3')
  assert.deepEqual([gone.state, gone.closed, gone.unread], ['done', true, false])
  assert.match(fs.readFileSync(rules, 'utf8'), /^- not relevant: Shop <news@example.com>, "Big news"$/m, 'the mail check learns from it')
  assert.equal((await post('/api/threads/t3/restore', {})).status, 200)
  gone = (await get('/api/threads')).find((r) => r.id === 't3')
  assert.equal(gone.closed, false)
  assert.doesNotMatch(fs.readFileSync(rules, 'utf8'), /Big news/, 'undo takes the example back')
  assert.throws(() => cli('thread', 'close', 't1', '--from', 'chief'), /--reason/)
  cli('add', '--title', 'Still open', '--ask', 'Yes?', '--kind', 'decision', '--thread', 't2', '--quiet')
  assert.throws(() => execFileSync(process.execPath, [bin, 'thread', 'close', 't2', '--from', 'chief', '--reason', 'done'], { env, stdio: 'pipe' }), /needs the owner/)
  cli('thread', 'close', 't4', '--from', 'chief', '--reason', 'Just a thank-you, nothing to do.')
  assert.equal((await get('/api/threads')).find((r) => r.id === 't4').closed, true)
  assert.match(cli('thread', 'ignore', '--from', '@spam.example'), /never: @spam.example/)
  threads.spam00001 = { text: head('Buy now', 1) + message(1, 'Spam <a@spam.example>', 'Buy.') }
  assert.equal(await mail('spam00001'), 'kept out by inbox-rules.md')
  assert.equal(fs.existsSync(path.join(home, 'fraim/threads/t6')), false, 'a sender kept out leaves no trace')
  cli('thread', 'ignore', 'newsletters about sales')
  assert.match(fs.readFileSync(rules, 'utf8'), /^- not relevant: newsletters about sales$/m)

  const staff = await get('/api/employees')
  assert.deepEqual(staff.people.map((p) => [p.title, p.does, p.product, p.starts, p.tools]), [
    ['Platform', 'The whole web app.', 'shop', ['schedule 0 6 * * 1-5'], ['Github', 'Linear']],
  ])
  assert.equal((await post(`/api/items/${q}/decide`, { verdict: 'approved', note: '' })).status, 200)
  rows = await get('/api/threads')
  assert.equal(row('t1').unread, false)
  assert.equal(row('t1').state, 'work', 'answered and recent')
  const after = await get('/api/threads/t1')
  assert.deepEqual(after.chat.at(-1).text, 'Yes, go ahead.')
  assert.match(cli('thread', 'show', 't2'), /forwarded by Daan/)
})
