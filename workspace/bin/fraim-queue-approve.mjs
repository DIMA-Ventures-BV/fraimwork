// How a card is added and decided. Every decision has its effects here, and only the owner decides.
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { channelWord } from './fraim-channels.mjs'
import {
  ADVICE, GOALS, KINDS, LEADS, Refused, THREADS, UsageError, allItems, capability, copyMedia, fire, itemDir, newId, now,
  promptText, queueUrl, readItem, runtimeEnv, tellLead, theContact, tool, usage, validId, validThread, writeItem,
} from './fraim-queue-store.mjs'

export const MAX_REPLY = 20000
export const replySummary = (r) => `To: ${r.name} (${r.to}), by ${channelWord(r.channel)}${r.subject ? `\nSubject: ${r.subject}` : ''}\n\n${r.text}`

// direct: the owner reads it word for word (a security notice), not rewritten by the chief.
export function notify(text, direct = false) {
  if (process.env.FRAIM_QUEUE_QUIET === '1') return
  const env = { ...process.env, FRAIM_NOTIFY_NO_ALERT: '1', ...(direct ? { FRAIM_NOTIFY_DIRECT: '1' } : {}) }
  fire('fraim-notify', [text], env)
}

export const ADVICE_WORD = { approve: 'Approve', reject: 'Send back', dismiss: 'Skip' }

// The message about a new item says what it is about and what the owner gains or risks, so the
// owner can decide from the message alone.
function newText(item) {
  const lines = [`New in your queue: ${item.title}`]
  if (item.ask) lines.push(item.ask)
  if (item.need) lines.push(`Why: ${item.need}`)
  if (item.if_yes) lines.push(`If you approve: ${item.if_yes}`)
  if (item.if_no) lines.push(`If you say no: ${item.if_no}`)
  if (item.advise) lines.push(`My advice: ${ADVICE_WORD[item.advise]}`)
  lines.push(queueUrl())
  return lines.join('\n')
}

// One job, one card: the card a goal was started from, when it can carry the next step.
function cardToContinue(id) {
  if (!id) return null
  if (!validId(id)) usage('--continues needs a queue item id (q1, q2, ...)')
  try {
    const card = readItem(id)
    return card.brain || card.skill || card.reply ? null : card
  } catch { return null }
}

// The next step of a job lands on the job's card and the step before it moves to the card's
// history. With a new question the card waits for the owner again. With nothing to decide a
// card the owner approved stays closed; rework the owner sent back always comes back to them.
function continueCard(card, step, nothingToDecide) {
  const history = [...(card.history || []), {
    title: card.title, ask: card.ask, state: card.state, note: card.note, created: card.created, decided: card.decided,
    via: card.via || '', goal: card.goal, summary: card.summary.slice(0, 4000), links: card.links, media: card.media,
  }]
  const result = { summary: step.summary, goal: step.goal, source: step.source, lead: step.lead || card.lead, links: step.links, media: step.media, history }
  if (nothingToDecide && card.state === 'approved') return { ...card, ...result }
  return { ...card, ...step, ...result, thread: step.thread || card.thread || '', id: card.id, title: card.title, started: card.started || card.created, follow_up: '', outcome: '', via: '', approved_by: '', switch_on: '' }
}

// The conversation an item belongs to: said outright, set for this run, or that of its goal.
function itemThread(opts) {
  const fromGoal = opts.goal ? readGoalFile(String(opts.goal), 'thread') : ''
  const id = String(opts.thread || process.env.FRAIM_THREAD || fromGoal)
  return validThread(id) && fs.existsSync(path.join(THREADS, id, 'thread.json')) ? id : ''
}

export function addItem(opts) {
  const title = String(opts.title || '').trim()
  if (!title) usage('add needs --title')
  if (process.env.FRAIM_GOAL && !opts.result && !opts.brain && !opts.skill && !opts.switchOn && !opts.approvedBy) {
    usage(`a goal does not add queue items itself: write ~/fraim/goals/${process.env.FRAIM_GOAL}/queue.json and the server makes the card; other questions go in its "more" list`)
  }
  const kind = opts.kind || 'review'
  if (!KINDS.includes(kind)) usage(`--kind must be one of ${KINDS.join(', ')}`)
  const priority = parseInt(opts.priority || '2', 10)
  if (![1, 2, 3].includes(priority)) usage('--priority must be 1, 2 or 3')
  if (opts.brain && !/^p\d{1,6}$/.test(opts.brain)) usage('--brain needs a proposal id (p1, p2, ...)')
  if (opts.skill && !/^s\d{1,6}$/.test(opts.skill)) usage('--skill needs a skill proposal id (s1, s2, ...)')
  if (opts.switchOn && !/^[a-z0-9][a-z0-9_-]{0,47}$/.test(opts.switchOn)) usage('--switch-on needs an automation name')
  if (opts.approvedBy && !validId(opts.approvedBy)) usage('--approved-by needs the id of a queue item the owner approved (q1, q2, ...)')
  if (opts.switchOn) requireTrial(opts.switchOn)
  const advise = opts.advise ? String(opts.advise).toLowerCase().replace(/^send-?back$/, 'reject').replace(/^skip$/, 'dismiss') : ''
  if (advise && !ADVICE.includes(advise)) usage('--advise must be approve, reject (send back) or dismiss (skip)')
  const why = (Array.isArray(opts.why) ? opts.why : opts.why ? [opts.why] : []).map((w) => String(w).trim()).filter(Boolean).slice(0, 3)
  const origin = cardToContinue(opts.continues)
  const id = origin ? origin.id : newId()
  const dir = itemDir(id)
  const takenMedia = origin ? [...origin.media, ...(origin.history || []).flatMap((s) => s.media || [])] : []
  const step = {
    id,
    title: title.slice(0, 200),
    // The decision in one look: the question for the owner, the advice, why it is needed, what
    // changes when the owner says yes or no, and at most 3 reasons for the advice.
    ask: String(opts.ask || '').trim().slice(0, 300),
    advise,
    need: String(opts.need || '').trim().slice(0, 400),
    if_yes: String(opts.ifYes || '').trim().slice(0, 400),
    if_no: String(opts.ifNo || '').trim().slice(0, 400),
    why: why.map((w) => w.slice(0, 300)),
    summary: String(opts.summary || '').slice(0, 20000),
    kind,
    priority,
    source: opts.source || (opts.goal ? `goal ${opts.goal}` : opts.lead ? `lead ${opts.lead}` : 'manual'),
    goal: opts.goal || '',
    lead: opts.lead || '',
    links: opts.links || [],
    media: copyMedia(dir, opts.media || [], takenMedia),
    on_approve: String(opts.onApprove || ''),
    brain: opts.brain || '',
    skill: opts.skill || '',
    // An automation or lead the engineer built switched off; approve switches it on.
    switch_on: opts.switchOn || '',
    thread: itemThread(opts),
    // Set only by draftReply; a value from the command line is a string and does not count.
    ...(opts.reply && typeof opts.reply === 'object' ? { reply: opts.reply } : {}),
    state: 'open',
    note: '',
    created: now(),
    decided: '',
  }
  const nothingToDecide = Boolean(opts.result) && !step.ask && !step.on_approve && kind !== 'failed'
  const item = origin ? continueCard(origin, step, nothingToDecide) : step
  if (!origin && nothingToDecide) Object.assign(item, { state: 'dismissed', note: 'Nothing to decide.', decided: now(), via: 'system' })
  writeItem(item)
  if (opts.approvedBy) {
    try {
      return approvedByGrant(item, String(opts.approvedBy))
    } catch (err) {
      if (err instanceof UsageError) throw err
      process.stderr.write(`fraim-queue: ${err.message}. ${id} waits in the queue as a normal question.\n`)
    }
  }
  if (!opts.quiet && item.state === 'open') notify(newText(item))
  // A lead hears at once when a goal it started ends; queue=all hears through its queue events.
  if (item.goal && item.lead && capability(item.lead, 'queue') !== 'all') {
    tellLead(item.lead, `goal ${item.goal}`, `${kind === 'failed' ? 'A task you started failed' : 'A task you started is done'}: ${item.title} (queue item ${id}, fraim-queue show ${id}).`, item.thread)
  }
  return item
}

function brain(args) {
  const res = spawnSync(tool('fraim-brain'), args, { encoding: 'utf8', timeout: 30000 })
  if (res.status !== 0) throw new Error((res.stderr || res.error?.message || 'fraim-brain failed').trim().replace(/^fraim-brain: /, ''))
  return res.stdout.trim()
}

// Every reason the owner gives is evidence for the brain. A failed write must not undo a decision.
function brainNote(item, verdict, note) {
  if (!note) return
  const args = ['log', '--verdict', verdict, '--item', item.id, '--title', item.title]
  if (item.lead) args.push('--lead', item.lead)
  try { brain([...args, '--', note]) } catch (err) { process.stderr.write(`fraim-queue: the brain did not save the reason: ${err.message}\n`) }
}

// A switched-off employee is only offered to the owner after a passed trial of its current brief.
function requireTrial(name) {
  const dir = path.join(LEADS, name)
  if (!fs.existsSync(path.join(dir, 'lead.md')) || !fs.existsSync(path.join(dir, 'paused'))) return
  const res = spawnSync(tool('fraim-lead'), ['try', name, '--status'], { encoding: 'utf8', timeout: 30000 })
  if (res.status !== 0) throw new Error(`${name} cannot be hired yet: ${(res.stdout || res.stderr || res.error?.message || '').trim()}`)
}

function switchOn(name, granted = false) {
  const env = { ...process.env }
  if (granted) delete env.FRAIM_HEADLESS
  const res = spawnSync(tool('fraim-auto'), ['on', name], { encoding: 'utf8', timeout: 30000, env })
  if (res.status !== 0) throw new Error(`could not switch on ${name}: ${(res.stderr || res.error?.message || '').trim().replace(/^fraim-auto: /, '')}`)
  return res.stdout.trim()
}

function startGoal(text, item) {
  const args = ['start']
  if (item.lead) args.push('--lead', item.lead)
  args.push('--queue', item.id, '--', text)
  const env = { ...process.env, FRAIM_GOAL_FROM_QUEUE: '1' }
  const res = spawnSync('fraim-goal', args, { encoding: 'utf8', timeout: 30000, env })
  if (res.status !== 0) throw new Error(`could not start the follow-up goal: ${(res.stderr || res.error?.message || '').trim()}`)
  return res.stdout.trim()
}

function readGoalFile(goal, name, max = 4000) {
  if (!/^g\d{1,6}$/.test(goal)) return ''
  try { return fs.readFileSync(path.join(GOALS, goal, name), 'utf8').slice(0, max).trim() } catch { return '' }
}

function reworkText(item, note) {
  const original = readGoalFile(item.goal, 'goal.md') || item.title
  const result = readGoalFile(item.goal, 'result.md') || item.summary
  return promptText('queue-rework', { id: item.id, title: item.title, original, result, note, goal: item.goal })
}

function approveText(item, note) {
  return promptText('queue-approved', { id: item.id, title: item.title, on_approve: item.on_approve, note, goal: item.goal })
}

// The one place where a decision has effects, used by the CLI, the page and WhatsApp.
// Only the owner decides: a headless Claude run (goal, lead, automation) cannot.
export function decide(id, verdict, note = '', via = 'cli', editedText = undefined) {
  if (process.env.FRAIM_HEADLESS === '1') throw new Refused('only the owner decides; a goal, lead or automation cannot approve, reject or dismiss')
  const item = readItem(id)
  if (item.state !== 'open') throw new Error(`${id} is already ${item.state}`)
  note = String(note || '').trim()
  if (verdict === 'rejected' && !note) usage('reject needs a reason (--note), so the agent knows what to change')
  if (!['approved', 'rejected', 'dismissed'].includes(verdict)) usage(`unknown decision ${verdict}`)
  if (item.reply && verdict === 'approved' && editedText != null) {
    const text = String(editedText).trim()
    if (!text) usage('the reply is empty')
    if (text.length > MAX_REPLY) usage(`a reply is at most ${MAX_REPLY} characters`)
    if (text !== item.reply.text) {
      Object.assign(item.reply, { text, edited: true })
      item.summary = replySummary(item.reply)
    }
  }
  return applyDecision(item, verdict, note, via)
}

// The owner's yes covers the work that follows from it. An item added with --approved-by qN
// (qN approved by the owner in the last 14 days) is approved at once: what was built for that
// yes starts without a second question, and the owner hears that it runs.
const GRANT_DAYS = 14
// A card that moved on to its next question still carries the owner's last decision.
const lastDecision = (card) => [card, ...[...(card.history || [])].reverse()].find((s) => s.state !== 'open')
const recent = (decision) => Date.now() - Date.parse(String(decision.decided).replace(' ', 'T')) < GRANT_DAYS * 86400000
// A yes covers the work that follows from it, so a run nobody watches may only spend its own:
// a goal the yes it was started from, the engineer what it built for one. Nothing else.
function grantAllowedForCaller(item, grantId) {
  if (process.env.FRAIM_HEADLESS !== '1') return
  const goal = process.env.FRAIM_GOAL
  if (goal) {
    if (readGoalFile(goal, 'queue') !== grantId) throw new Error(`${grantId} is not the yes this task was started from; ask the owner in the queue instead`)
    return
  }
  if (process.env.FRAIM_BUILDS_OFF !== '1') throw new Error(`only the owner can use ${grantId} for this; ask the owner in the queue instead`)
  if (item.on_approve) throw new Error(`a new task needs its own yes; ask the owner in the queue instead`)
}

function approvedByGrant(item, grantId) {
  const grant = readItem(grantId)
  const decision = lastDecision(grant)
  if (decision?.state !== 'approved' || decision.via === 'grant') throw new Error(`${grantId} is not a yes from the owner; ask the owner in the queue instead`)
  if (grant.brain || grant.skill) throw new Error(`${grantId} approved a brain change; ask the owner in the queue instead`)
  if (grant.reply) throw new Error(`${grantId} approved one message to one person; ask the owner in the queue instead`)
  grantAllowedForCaller(item, grantId)
  if (!recent(decision)) throw new Error(`the owner's yes on ${grantId} is older than ${GRANT_DAYS} days; ask again in the queue`)
  item.approved_by = grantId
  const done = applyDecision(item, 'approved', `The owner already said yes: "${grant.title}" (${grantId})${decision.note ? `: ${decision.note}` : ''}`, 'grant', { HEADLESS_OK: true })
  grant.used_by = [...(grant.used_by || []), item.id]
  writeItem(grant)
  notify(`Started, because you already said yes to "${grant.title}": ${item.title}.${item.if_yes ? ` ${item.if_yes}` : ''}${done.follow_up ? ' A task for it has started.' : ''}`)
  return done
}

// The default contact starts the task the owner asked for in the chat: that request covers one goal.
export function useYesForGoal(grantId) {
  if (!validId(grantId || '')) usage('use-yes needs a queue id (q1, q2, ...)')
  const lead = process.env.FRAIM_LEAD_NAME || ''
  if (!lead || lead !== theContact()) throw new Error('only the default contact can start a task from the owner\'s request')
  const grant = readItem(grantId)
  if (grant.source !== 'the owner in the chat') throw new Error(`${grantId} is not a request from the owner's chat`)
  const decision = lastDecision(grant)
  if (decision?.state !== 'approved' || decision.via === 'grant') throw new Error(`${grantId} is not a yes from the owner`)
  if (!recent(decision)) throw new Error(`the owner's yes on ${grantId} is older than ${GRANT_DAYS} days`)
  if (grant.goal_started) throw new Error(`${grantId} already started a task`)
  grant.goal_started = true
  writeItem(grant)
}

// A request the owner gave in the chat is already their yes: record it as an approved item, so
// what gets built for it can cite it with --approved-by and start without a second question.
export function grantRequest(title, note, via = 'cli') {
  if (process.env.FRAIM_HEADLESS === '1') throw new Error('only the owner gives a yes; a goal, lead or automation cannot')
  title = String(title || '').trim()
  if (!title) usage('grant needs --title "<what the owner asked for>"')
  const item = addItem({ title, kind: 'decision', source: 'the owner in the chat', quiet: true })
  return applyDecision(item, 'approved', String(note || '').trim(), via)
}

function applyDecision(item, verdict, note, via, opts = {}) {
  let followUp = ''
  let outcome = ''
  // A brain proposal or a new skill changes nothing until the owner approves it here.
  if (item.brain) {
    outcome = verdict === 'approved' ? brain(['apply', item.brain]) : brain(['discard', item.brain, '--note', verdict === 'rejected' ? note : ''])
  } else if (item.skill) {
    outcome = verdict === 'approved' ? brain(['skill', 'install', item.skill]) : brain(['skill', 'discard', item.skill, '--note', note])
  } else if (verdict === 'approved' && item.reply) {
    item.reply = { ...item.reply, status: 'sending', error: '' }
  } else if (verdict === 'approved' && (item.switch_on || item.on_approve)) {
    if (item.switch_on) outcome = switchOn(item.switch_on, opts.HEADLESS_OK)
    if (item.on_approve) followUp = startGoal(approveText(item, note), item)
  } else if (verdict === 'rejected' && item.goal) {
    // A rejected idea only teaches the brain; a rejected piece of work is done again.
    followUp = startGoal(reworkText(item, note), item)
  }
  item.state = verdict
  item.note = note
  item.decided = now()
  item.follow_up = followUp
  item.outcome = outcome
  item.via = via
  writeItem(item)
  // The sender reads the card, so it starts after the write. It never waits inside the page.
  if (verdict === 'approved' && item.reply) fire(tool('fraim-queue'), ['send-reply', item.id], runtimeEnv())
  // A change to the brain from the command line could come from an agent: tell the owner.
  if ((item.brain || item.skill) && verdict === 'approved' && (via === 'cli' || via.startsWith('api:'))) notify(`${item.id} was approved ${via === 'cli' ? 'from the command line' : `by the app "${via.slice(4)}"`}: ${outcome}\nNot you? Tell me and I undo it.`, true)
  if (verdict !== 'dismissed' && via !== 'grant') brainNote(item, verdict === 'approved' ? 'approved' : 'rejected', note)
  if (item.lead && via !== 'grant') {
    const covers = verdict === 'approved' && !item.reply ? '1' : ''
    tellLead(item.lead, 'owner', promptText('queue-decided', { verdict, title: item.title, id: item.id, note, follow_up: followUp, covers }), item.thread)
  }
  return item
}

// A failed attempt at a decision is no longer a question once a later goal for the same
// decision succeeded: close those failures (not a decision of the owner, so no brain note).
// origin: the queue item the goals were started from (~/fraim/goals/gN/queue).
export function supersedeFailed(origin, by) {
  if (!validId(origin || '') || !/^g\d{1,6}$/.test(by || '')) usage('supersede --origin qN --by gN')
  // Only a goal that really finished for this decision closes its earlier failures.
  if (!readGoalFile(by, 'state').startsWith('done') || readGoalFile(by, 'queue') !== origin) throw new Error(`goal ${by} did not finish ${origin}`)
  const closed = []
  for (const item of allItems()) {
    if (item.state !== 'open' || item.kind !== 'failed' || !/^g\d+$/.test(item.goal || '') || item.goal === by) continue
    if (readGoalFile(item.goal, 'queue') !== origin) continue
    let fresh
    try { fresh = readItem(item.id) } catch { continue }
    if (fresh.state !== 'open') continue
    Object.assign(item, fresh)
    item.state = 'dismissed'
    item.note = `done after all by goal ${by}`
    item.decided = now()
    item.via = 'system'
    writeItem(item)
    closed.push(item.id)
  }
  return closed
}

// Solved is not a decision: the problem on the card is gone, so nobody has to choose anything.
// The chief may do this, unlike decide(). It starts nothing and teaches the brain nothing.
export function closeSolved(item, proof, via) {
  item.state = 'dismissed'
  item.note = `Solved: ${proof}`
  item.decided = now()
  item.via = via
  writeItem(item)
  return item
}

// A card with a next step still asks the owner something, and a goal result is the owner's to
// review. Those stay open whatever a run believes.
export function markSolved(id, proof) {
  proof = String(proof || '').trim()
  if (proof.length < 10) usage('solved ID --proof "<what proves it is solved>"')
  const item = readItem(id)
  if (item.state !== 'open') throw new Error(`${id} is already ${item.state}`)
  if (item.on_approve || item.switch_on || item.brain || item.skill || item.reply) throw new Error(`${id} still needs the owner's decision`)
  if (item.kind !== 'failed' && !/^automation /.test(item.source || '')) throw new Error(`${id} is for the owner to review`)
  return closeSolved(item, proof, 'chief')
}

// The automation itself proved it works again, so even a card with a next step is out of date.
export function closeRecovered(source) {
  if (!/^automation [a-z0-9_-]+$/.test(source || '')) usage('recovered --source "automation NAME"')
  const closed = []
  for (const item of allItems()) {
    if (item.state !== 'open' || item.kind !== 'failed' || item.source !== source) continue
    let fresh
    try { fresh = readItem(item.id) } catch { continue }
    if (fresh.state !== 'open') continue
    closeSolved(fresh, 'the automation works again', 'system')
    closed.push(item.id)
  }
  return closed
}

export function setPriority(id, priority) {
  const item = readItem(id)
  const p = parseInt(priority, 10)
  if (![1, 2, 3].includes(p)) usage('priority must be 1, 2 or 3')
  item.priority = p
  writeItem(item)
  return item
}
