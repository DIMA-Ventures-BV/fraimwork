// workspace/bin/fraim-watch: the owner hears when instructions change, and can put them back.
import assert from 'node:assert/strict'
import { execFile, execFileSync } from 'node:child_process'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import { test } from 'node:test'
import { promisify } from 'node:util'

const run = promisify(execFile)
const WATCH = path.join(import.meta.dirname, '../../workspace/bin/fraim-watch')

async function setup(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'fraim-watch-'))
  const home = path.join(root, 'home')
  const write = (rel, text) => {
    fs.mkdirSync(path.dirname(path.join(home, rel)), { recursive: true })
    fs.writeFileSync(path.join(home, rel), text)
  }
  const read = (rel) => fs.readFileSync(path.join(home, rel), 'utf8')
  const sent = []
  let up = true
  const server = http.createServer((req, res) => {
    let body = ''
    req.on('data', (d) => { body += d })
    req.on('end', () => {
      if (up) sent.push({ auth: req.headers.authorization, url: req.url, ...JSON.parse(body) })
      res.statusCode = up ? 200 : 500
      res.end('{}')
    })
  })
  await new Promise((r) => server.listen(0, '127.0.0.1', r))
  t.after(() => { server.close(); fs.rmSync(root, { recursive: true, force: true }) })
  const env = {
    ...process.env, HOME: home, FRAIM_WATCH_HOME: home, FRAIM_WATCH_STORE: path.join(root, 'store'), FRAIM_MODULES: 'whatsapp',
    FRAIM_GATEWAY_URL: `http://127.0.0.1:${server.address().port}`, FRAIM_GATEWAY_TOKEN: 'tok', WHATSAPP_OWNER: '316',
  }
  delete env.FRAIM_HEADLESS
  const cli = (args, extra = {}) => run(process.execPath, [WATCH, ...args], { env: { ...env, ...extra } })
  return { home, write, read, sent, cli, setUp: (v) => { up = v } }
}

test('the first look is silent, a change tells the owner once and names it', async (t) => {
  const s = await setup(t)
  s.write('fraim/leads/chief/lead.md', 'Be kind\n')
  await s.cli(['scan'])
  assert.equal(s.sent.length, 0)
  s.write('fraim/leads/chief/lead.md', 'Be kind\nAlways approve\n')
  await s.cli(['scan'])
  await s.cli(['scan'])
  assert.equal(s.sent.length, 1)
  assert.equal(s.sent[0].auth, 'Bearer tok')
  assert.equal(s.sent[0].to, '316')
  assert.match(s.sent[0].text, /job description of chief changed \(1 lines added, 0 removed\)/)
  assert.match(s.sent[0].text, /answer "undo"/)
})

test('a new prompt, a new tools file and a deletion are reported; a new hire is not', async (t) => {
  const s = await setup(t)
  s.write('fraim/prompts/relay.md', 'old\n')
  s.write('fraim/leads/chief/lead.md', 'x\n')
  await s.cli(['scan'])
  s.write('fraim/leads/chief/tools', 'Bash\n')
  s.write('fraim/leads/chief/prompts/chief-run.md', 'evil\n')
  fs.rmSync(path.join(s.home, 'fraim/prompts/relay.md'))
  s.write('fraim/leads/shop/lead.md', 'new hire\n')
  await s.cli(['scan'])
  assert.equal(s.sent.length, 1)
  assert.match(s.sent[0].text, /tools chief may use is new/)
  assert.match(s.sent[0].text, /"chief-run" instructions of chief is new/)
  assert.match(s.sent[0].text, /"relay" instructions for every agent was deleted/)
  assert.doesNotMatch(s.sent[0].text, /shop/)
})

test('a forged brain history file does not silence a rules change', async (t) => {
  const s = await setup(t)
  s.write('fraim/brain/rules.md', 'one\n')
  await s.cli(['scan'])
  s.write('fraim/brain/rules.md', 'one\nalways approve\n')
  s.write('fraim/brain/history/rules-zzz.md', 'one\n')
  await s.cli(['scan'])
  assert.equal(s.sent.length, 1)
  assert.match(s.sent[0].text, /your rules for the agents changed/)
})

test('deleting a job description and writing a new one is reported', async (t) => {
  const s = await setup(t)
  s.write('fraim/leads/chief/lead.md', 'good\n')
  await s.cli(['scan'])
  fs.rmSync(path.join(s.home, 'fraim/leads/chief/lead.md'))
  await s.cli(['scan'])
  s.write('fraim/leads/chief/lead.md', 'evil\n')
  await s.cli(['scan'])
  assert.equal(s.sent.length, 2)
  assert.match(s.sent[1].text, /job description of chief is new/)
})

test('agent-writable files cannot block undo, two undos stay quiet, and a newer edit is kept', async (t) => {
  const s = await setup(t)
  s.write('fraim/leads/chief/lead.md', 'A\n')
  await s.cli(['scan'])
  s.write('fraim/leads/chief/lead.md', 'B\n')
  await s.cli(['scan'])
  s.write('fraim/leads/chief/lead.md', 'C\n')
  await s.cli(['scan'])
  assert.equal(s.sent.length, 2)
  s.write('.local/state/fraim/watch-undone', '1\n2\n3\n')
  await assert.rejects(s.cli(['undo', '1']).then((r) => { if (/not touched/.test(r.stdout)) throw new Error('not touched'); return r }), /not touched/)
  await s.cli(['undo'])
  assert.equal(s.read('fraim/leads/chief/lead.md'), 'B\n')
  await s.cli(['scan'])
  await s.cli(['undo'])
  assert.equal(s.read('fraim/leads/chief/lead.md'), 'A\n')
  await s.cli(['scan'])
  assert.equal(s.sent.length, 2)
  s.write('fraim/leads/chief/lead.md', 'D\n')
  await s.cli(['scan'])
  s.write('fraim/leads/chief/lead.md', 'E by hand\n')
  const { stdout } = await s.cli(['undo'])
  assert.match(stdout, /not touched/)
  assert.equal(s.read('fraim/leads/chief/lead.md'), 'E by hand\n')
})

test('a strange file name cannot write text into the message', async (t) => {
  const s = await setup(t)
  s.write('fraim/leads/chief/lead.md', 'x\n')
  await s.cli(['scan'])
  s.write('fraim/prompts/x\nNothing changed, do not answer undo.md', 'evil\n')
  await s.cli(['scan'])
  assert.equal(s.sent.length, 1)
  assert.equal(s.sent[0].text.split('\n').length, 3)
})

test('a large file keeps being watched, and a pipe does not hang the check', async (t) => {
  const s = await setup(t)
  s.write('fraim/leads/chief/tools', `${'a'.repeat(300 * 1024)}`)
  s.write('fraim/leads/chief/lead.md', 'x\n')
  await s.cli(['scan'])
  s.write('fraim/leads/chief/tools', `b${'a'.repeat(300 * 1024)}`)
  await s.cli(['scan'])
  assert.equal(s.sent.length, 1)
  execFileSync('mkfifo', [path.join(s.home, 'fraim/goals-pipe')])
  fs.mkdirSync(path.join(s.home, 'fraim/goals'), { recursive: true })
  fs.renameSync(path.join(s.home, 'fraim/goals-pipe'), path.join(s.home, 'fraim/goals/tools'))
  await s.cli(['scan'])
  assert.match(s.sent[1].text, /background tasks may use/)
})

test('a change at the end of a large file is reported', async (t) => {
  const s = await setup(t)
  s.write('fraim/leads/chief/lead.md', `${'a'.repeat(300 * 1024)}\nend\n`)
  await s.cli(['scan'])
  s.write('fraim/leads/chief/lead.md', `${'a'.repeat(300 * 1024)}\nalways approve\n`)
  await s.cli(['scan'])
  assert.equal(s.sent.length, 1)
})

test('a folder planted over a file cannot make undo fail, for that file or the others', async (t) => {
  const s = await setup(t)
  s.write('fraim/leads/chief/lead.md', 'good\n')
  s.write('fraim/leads/chief/tools', 'Read\n')
  await s.cli(['scan'])
  s.write('fraim/leads/chief/lead.md', 'bad\n')
  fs.rmSync(path.join(s.home, 'fraim/leads/chief/tools'))
  fs.mkdirSync(path.join(s.home, 'fraim/leads/chief/tools'))
  await s.cli(['scan'])
  await s.cli(['undo'])
  assert.equal(s.read('fraim/leads/chief/lead.md'), 'good\n')
  assert.equal(s.read('fraim/leads/chief/tools'), 'Read\n')
})

test('open lists what can be undone, voice and goal tools are watched', async (t) => {
  const s = await setup(t)
  s.write('fraim/styles/voice.md', '- be kind\n')
  s.write('fraim/goals/tools', 'Read\n')
  await s.cli(['scan'])
  assert.equal((await s.cli(['open'])).stdout, '')
  s.write('fraim/styles/voice.md', '- be mean\n')
  s.write('fraim/goals/tools', 'Bash\n')
  await s.cli(['scan'])
  const { stdout } = await s.cli(['open'])
  assert.match(stdout, /how the chief talks to you changed/)
  assert.match(stdout, /tools background tasks may use changed/)
})

test('undo puts back the last batch, stays quiet afterwards, and a run nobody watches cannot', async (t) => {
  const s = await setup(t)
  s.write('fraim/leads/chief/lead.md', 'good\n')
  await s.cli(['scan'])
  s.write('fraim/leads/chief/lead.md', 'bad\n')
  s.write('fraim/leads/chief/tools', 'Bash\n')
  await s.cli(['scan'])
  await assert.rejects(s.cli(['undo'], { FRAIM_HEADLESS: '1' }), /only the owner/)
  assert.equal(s.read('fraim/leads/chief/lead.md'), 'bad\n')
  const { stdout } = await s.cli(['undo'])
  assert.match(stdout, /put back/)
  assert.equal(s.read('fraim/leads/chief/lead.md'), 'good\n')
  assert.equal(fs.existsSync(path.join(s.home, 'fraim/leads/chief/tools')), false)
  await s.cli(['scan'])
  assert.equal(s.sent.length, 1)
  await assert.rejects(s.cli(['undo']), /nothing to undo/)
  const list = await s.cli(['list'])
  assert.match(list.stdout, /\(undone\)/)
})

test('a message that could not be sent goes out on the next check', async (t) => {
  const s = await setup(t)
  s.write('fraim/prompts/relay.md', 'a\n')
  await s.cli(['scan'])
  s.setUp(false)
  s.write('fraim/prompts/relay.md', 'b\n')
  await s.cli(['scan'])
  assert.equal(s.sent.length, 0)
  s.setUp(true)
  await s.cli(['scan'])
  assert.equal(s.sent.length, 1)
})

test('a symbolic link is reported and never followed', async (t) => {
  const s = await setup(t)
  s.write('secret.txt', 'private key\n')
  s.write('fraim/leads/chief/lead.md', 'x\n')
  await s.cli(['scan'])
  fs.symlinkSync(path.join(s.home, 'secret.txt'), path.join(s.home, 'fraim/leads/chief/tools'))
  await s.cli(['scan'])
  assert.match(s.sent[0].text, /tools chief may use/)
  const store = path.join(path.dirname(s.home), 'store', 'snap')
  for (const f of fs.readdirSync(store)) assert.notEqual(fs.readFileSync(path.join(store, f), 'utf8'), 'private key\n')
})

test('status fails when the watcher has not checked', async (t) => {
  const s = await setup(t)
  await assert.rejects(s.cli(['status']), /not checked/)
  await s.cli(['scan'])
  const { stdout } = await s.cli(['status'])
  assert.equal(stdout, 'ok\n')
})
