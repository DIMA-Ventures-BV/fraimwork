// fraim-preview: forwards a preview slot to a dev server on 127.0.0.1 and reports the right URL.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdtemp } from 'node:fs/promises'
import http from 'node:http'
import net from 'node:net'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const bin = path.join(here, '../../workspace/bin/fraim-preview')

const run = (home, env, ...args) =>
  execFileSync(process.execPath, [bin, ...args], {
    env: { PATH: process.env.PATH, HOME: home, ...env },
    encoding: 'utf8',
  }).trim()

// A local fraim stack publishes 127.0.0.1:3100, which macOS lets 0.0.0.0 bind next to.
const freeOn = (host) =>
  new Promise((resolve) => {
    const s = net.createServer()
    s.once('error', () => resolve(false))
    s.listen(3100, host, () => s.close(() => resolve(true)))
  })
const slotsFree = async () => (await freeOn('127.0.0.1')) && (await freeOn('0.0.0.0'))

test('start forwards a slot to the dev server, list shows it, stop ends it', async (t) => {
  if (!(await slotsFree())) return t.skip('port 3100 is in use on this machine')
  const home = await mkdtemp(path.join(tmpdir(), 'fraim-preview-'))
  const server = http.createServer((_, res) => res.end('hello from the dev server'))
  await new Promise((r) => server.listen(0, '127.0.0.1', r))
  const port = server.address().port
  const env = { FRAIM_ACCESS_MODE: 'tailscale', FRAIM_HOSTNAME: 'fraim-test', FRAIM_PREVIEW_PORTS: '3200-3209' }
  try {
    const url = run(home, env, 'start', String(port), '--name', 'app')
    // Slot 3100 inside the container is published as the space's first preview port.
    assert.equal(url, 'http://fraim-test:3200')
    assert.equal(run(home, env, 'start', String(port)), url, 'a second start reuses the running preview')
    const body = await new Promise((resolve, reject) =>
      http.get('http://127.0.0.1:3100/', (res) => {
        let data = ''
        res.on('data', (c) => (data += c))
        res.on('end', () => resolve(data))
      }).on('error', reject),
    )
    assert.equal(body, 'hello from the dev server')
    const list = JSON.parse(run(home, env, 'list', '--json'))
    assert.deepEqual(list, [{ port, url, label: 'app' }])
  } finally {
    run(home, env, 'stop', 'all')
    server.close()
  }
  assert.equal(run(home, env, 'list'), 'No previews running.')
})

test('public mode points the user at the laptop tunnel', async (t) => {
  if (!(await slotsFree())) return t.skip('port 3100 is in use on this machine')
  const home = await mkdtemp(path.join(tmpdir(), 'fraim-preview-'))
  const env = { FRAIM_ACCESS_MODE: 'public', FRAIM_SPACE: 'work' }
  try {
    const url = run(home, env, 'start', '45999')
    assert.match(url, /^http:\/\/localhost:3100 .*fraim preview --space work/)
  } finally {
    run(home, env, 'stop', 'all')
  }
})
