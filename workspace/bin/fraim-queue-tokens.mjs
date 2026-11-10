// Tokens for the API. Only a hash is kept; the token itself is shown once, to the owner.
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { HOME, Refused, now, usage } from './fraim-queue-store.mjs'

export const SCOPES = ['read', 'write', 'decide']
const NAME = /^[a-z0-9][a-z0-9_-]{0,39}$/

const dir = () => process.env.FRAIM_AUTHORITY_DIR || path.join(HOME, '.config/fraim/authority')
const file = () => path.join(dir(), 'api-tokens')
const hash = (token) => crypto.createHash('sha256').update(token).digest('hex')

function load() {
  let text = ''
  try { text = fs.readFileSync(file(), 'utf8') } catch { return [] }
  return text.split('\n').flatMap((l) => {
    try { return l ? [JSON.parse(l)] : [] } catch { return [] }
  })
}

function save(rows) {
  fs.mkdirSync(dir(), { recursive: true, mode: 0o700 })
  fs.chmodSync(dir(), 0o700)
  const tmp = `${file()}.${process.pid}.tmp`
  fs.writeFileSync(tmp, rows.map((r) => `${JSON.stringify(r)}\n`).join(''), { mode: 0o600 })
  fs.renameSync(tmp, file())
}

export function findToken(token) {
  const want = Buffer.from(hash(String(token)), 'hex')
  return load().find((r) => {
    const have = Buffer.from(String(r.hash), 'hex')
    return have.length === want.length && crypto.timingSafeEqual(have, want)
  }) || null
}

export const stillValid = (row) => load().some((r) => r.hash === row.hash)
export const originListed = (origin) => load().some((r) => r.origins?.includes(origin))
export const allows = (scope, need) => SCOPES.indexOf(scope) >= SCOPES.indexOf(need)

function ownerOnly() {
  if (process.env.FRAIM_HEADLESS === '1') throw new Refused('only the owner manages API tokens; a goal, lead or automation cannot')
}

function checkedOrigin(origin) {
  let parsed = null
  try { parsed = new URL(origin) } catch {}
  if (!parsed || !/^https?:$/.test(parsed.protocol) || parsed.origin !== origin || origin.includes('*')) usage(`--origin needs an exact origin such as https://app.example.com, not "${origin}"`)
  return origin
}

function create(args) {
  ownerOnly()
  if (!NAME.test(args.name || '')) usage('token new needs --name, lowercase letters, digits, - or _')
  if (!SCOPES.includes(args.scope)) usage(`--scope must be one of ${SCOPES.join(', ')}`)
  const origins = (args.origin || []).map(checkedOrigin)
  const rows = load()
  if (rows.some((r) => r.name === args.name)) throw new Error(`a token named ${args.name} already exists; remove it first`)
  const token = `fq_${crypto.randomBytes(32).toString('base64url')}`
  save([...rows, { name: args.name, scope: args.scope, origins, hash: hash(token), created: now() }])
  console.log(token)
  process.stderr.write('Shown once. Only a hash is kept, so a lost token cannot be read back; remove it and make a new one.\n')
}

function list(args) {
  ownerOnly()
  const rows = load().map(({ name, scope, origins, created }) => ({ name, scope, origins, created }))
  if (args.json) return console.log(JSON.stringify(rows))
  if (!rows.length) return console.log('No API tokens.')
  console.log(rows.map((r) => `${r.name}  ${r.scope}  ${r.created}  ${r.origins.join(' ')}`.trimEnd()).join('\n'))
}

function remove(name) {
  ownerOnly()
  if (!name) usage('token rm NAME')
  const rows = load()
  if (!rows.some((r) => r.name === name)) throw new Error(`no token named ${name}`)
  save(rows.filter((r) => r.name !== name))
  console.log(`removed ${name}`)
}

export function tokenCommand(args) {
  const [what, name] = args._
  if (what === 'new') return create(args)
  if (what === 'list') return list(args)
  if (what === 'rm') return remove(name)
  usage('token new --name N --scope read|write|decide [--origin https://...] | token list | token rm NAME')
}
