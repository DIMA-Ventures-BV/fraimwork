// The page server's door (token, cookie) and the owner's answers to questions.
import assert from 'node:assert/strict'
import { execFileSync, spawn } from 'node:child_process'
import { mkdtemp, writeFile, chmod, mkdir } from 'node:fs/promises'
import fs from 'node:fs'
import net from 'node:net'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const bin = path.join(here, '../../workspace/bin/fraim-queue')


const freePort = () =>
  new Promise((resolve) => {
    const s = net.createServer()
    s.listen(0, '127.0.0.1', () => {
      const { port } = s.address()
      s.close(() => resolve(port))
    })
  })

test('the page needs the token, and an answer to a question is recorded and acted on', async (t) => {
  const home = await mkdtemp(path.join(tmpdir(), 'fraim-queue-'))
  const fake = path.join(home, 'bin')
  await mkdir(fake)
  await writeFile(path.join(fake, 'fraim-goal'), '#!/bin/sh\necho g5\n')
  await writeFile(path.join(fake, 'fraim-notify'), '#!/bin/sh\nexit 0\n')
  await chmod(path.join(fake, 'fraim-goal'), 0o755)
  await chmod(path.join(fake, 'fraim-notify'), 0o755)
  const port = await freePort()
  const env = {
    PATH: `${fake}:${process.env.PATH}`, HOME: home, FRAIM_RUNTIME_ENV: '/dev/null', FRAIM_QUEUE_QUIET: '1',
    FRAIM_QUEUE_PORT: String(port), FRAIM_QUEUE_BIND: '127.0.0.1',
  }
  const cli = (...args) => execFileSync(process.execPath, [bin, ...args], { env, encoding: 'utf8' }).trim()
  await writeFile(path.join(home, 'shot.png'), 'png-bytes')
  cli('add', '--title', 'With a picture', '--goal', 'g1', '--media', path.join(home, 'shot.png'))
  cli('add', '--title', 'Plain', '--priority', '1')
  const token = cli('token')

  const server = spawn(process.execPath, [bin, 'serve'], { env, stdio: ['ignore', 'ignore', 'pipe'] })
  t.after(() => server.kill())
  await new Promise((resolve) => server.stderr.once('data', resolve))
  const base = `http://127.0.0.1:${port}`

  assert.equal((await fetch(`${base}/health`)).status, 200)
  assert.equal((await fetch(`${base}/settings`)).status, 401)
  assert.equal((await fetch(`${base}/?t=wrong`, { redirect: 'manual' })).status, 403)
  const login = await fetch(`${base}/?t=${token}`, { redirect: 'manual' })
  assert.equal(login.status, 303)
  assert.match(login.headers.get('set-cookie'), /HttpOnly; SameSite=Strict/)
  const cookie = login.headers.get('set-cookie').split(';')[0]
  assert.match(await (await fetch(`${base}/settings`, { headers: { cookie } })).text(), /<html/i)
  assert.equal((await fetch(`${base}/media/q1/shot.png`, { headers: { cookie } })).status, 404, 'media is not served any more')

  assert.deepEqual(JSON.parse(cli('list', '--json')).map((i) => i.id), ['q2', 'q1'], 'priority 1 first')
  assert.match(cli('reject', 'q1', '--note', 'crop the picture'), /q1 rejected; goal g5 started/)
  assert.deepEqual(JSON.parse(cli('list', '--json')).map((i) => i.id), ['q2'])
  assert.equal(JSON.parse(cli('list', '--all', '--json')).length, 2)
  assert.match(fs.readFileSync(path.join(home, 'fraim/brain/log.md'), 'utf8'), /rejected q1 "With a picture": crop the picture/)
})
