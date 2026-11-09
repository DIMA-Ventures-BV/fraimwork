# Leads, the review queue and the brain

You decide. Agents do the rest. Everything that needs you lands in one ranked list, and every decision you make teaches the agents what you want.

```
lead agents (one per area, on a schedule)      the chief of staff (morning digest + events all day)
   │ start goals, propose ideas                   │ ranks, routes new work, sends one digest
   ▼                                              ▼
goals (background work) ──── results ────►  REVIEW QUEUE  ◄── you: approve / reject / dismiss
   ▲                                              │
   └──────── rework with your feedback ───────────┤
                                                  ▼
         brain: your reasons become rules and skills, after your approval
```

## Parts

| Part | Command | Where it lives |
|---|---|---|
| Review queue | `fraim-queue` | `~/fraim/queue/qN/item.json` plus `media/` |
| Queue page | `fraim-queue serve` (started with the workspace) | container port 3109, the space's last preview port |
| Goals | `fraim-goal` | `~/fraim/goals/gN/` |
| Leads | `fraim-lead` | `~/fraim/leads/<name>/`, scheduled by the automation `~/fraim/automations/<name>/` (`lead: <name>`) |
| Automations | `fraim-auto` | `~/fraim/automations/<name>/`; see [automations.md](automations.md) |

## How the parts work together

One system, one inbox:

- **Leads are automations.** `fraim-lead new` writes an automation with `lead: <name>`. `fraim-auto list` shows leads and automations together; pause, failure alerts, run history and `trigger: after: <lead>` work the same for both. Old `fraim-lead run` crontab lines move into automations when the scheduler starts.
- **Everything reports to the queue.** Goals put their result there. Leads add ideas and decisions. An automation with `output: queue` (or `queue:decision`, `queue:idea`, `queue:review`) adds its answer as an item.
- **Failures land in the queue too.** A failed automation or lead adds one `failed` item (priority 1) next to the WhatsApp alert. Approving it starts a goal that finds the cause and fixes the automation. A login or usage-limit failure only informs.
- **The chief sees all of it**: the queue, every lead's notes, `fraim-auto list` and the recent automation answers in `~/fraim/outbox.md`. Its digest names failed or paused automations.
- **The chief works all day.** Its `chief-events` automation wakes it when a goal result, a failure, an automation answer or a priority 1 item lands in the queue, and work you ask for on WhatsApp wakes it at once: the server's Claude reads your message by meaning and passes it on with `fraim-lead ask`. There is no keyword. See "The chief of staff" below.
- **The brain applies everywhere.** General rules go into every goal, lead and automation prompt. Rules for one lead stay with that lead.
- **Leads can propose automations.** For a fixed check without judgement, a lead adds a decision whose `on_approve` makes the automation with the building-automations skill.
| Brain | `fraim-brain` | `~/fraim/brain/log.md` (evidence), `rules.md` (rules), `~/.claude/skills` (skills); see [brain.md](brain.md) |

## The queue

An item has a title, a summary, a kind (`review`, `decision`, `idea`, `info`, `failed`), a priority (1 = today, 2 = normal, 3 = whenever), links, screenshots and videos, and an optional `on_approve` step.

Your decision has these effects, and only these:

| Decision | Effect |
|---|---|
| Approve | If the item has an `on_approve` step, a goal runs it. Your note goes to the brain. |
| Reject (reason required) | If a goal made the item, a new goal reworks it with your reason. An idea is only closed. The reason goes to the brain. |
| Dismiss | The item closes. Nothing else happens. |

The ranking is: priority, then age, so nothing waits forever. The chief of staff changes priorities; it never decides for you.

### Where you review

- **Page:** `fraim queue` on the laptop opens it. Keys: `j`/`k` move, `a` approve, `r` reject, `d` dismiss, `n` write a note, `v` dictate a note, `1` `2` `3` priority. The page is on the tailnet only and needs the link with the token once (the browser then keeps a cookie). `fraim queue keep` makes it always available on a Mac: a launchd agent keeps an SSH tunnel open on `http://localhost:3109` through restarts of the Mac and the server, so a bookmark always works; `fraim queue keep --off` removes it.
- **WhatsApp:** talk in your own words ("what's waiting for me?", "the export looks good", "no, use the brand green", "drop the blog idea"). The server's Claude finds the item and records your decision, with your words as the note. There are no keywords.
- **Laptop:** `fraim queue list`, `fraim queue approve q3`, `fraim queue reject q3 "why"`.

## Goals feed the queue

Every finished goal becomes a queue item. The goal prompt asks the run to:

- save screenshots (and a recording when a flow matters) in `~/fraim/goals/gN/media/`, using the server browser;
- write `~/fraim/goals/gN/queue.json` with the title, priority, kind, links and the `on_approve` step.

A failed goal becomes a priority 1 item; `no qN <what to change>` retries it.

## Leads

```
fraim lead new web --area "the mijnlevensverhalen web app" --at "0 7 * * 1-5"
fraim lead new chief --chief
```

Then edit `~/fraim/leads/web/lead.md`: where to look (repositories, issues, errors, analytics) and what the lead may start without asking.

Each run, a lead reads its brief, its own notes (`state.md`), the brain rules and your past decisions on its items. Then it:

1. acts first on its inbox (`~/fraim/leads/<name>/inbox.md`: notes from the owner, the chief, other leads and its goals, written with `fraim-lead tell web -- "..."`);
2. starts goals for clear work (`fraim-goal start --lead web`), at most `budget` per day (default 3);
3. adds ideas and decisions to the queue, at most 3 per run;
4. rewrites its notes.

A lead cannot send mail, post, pay, merge or deploy. Its tools are narrow: read files, the queue, goals, `fraim-api`, and read-only `git` and `gh`. Add more in `~/fraim/leads/<name>/tools`, one per line.

You get one WhatsApp message per run, and none when the lead found nothing.

## The chief of staff

`fraim lead new chief --chief` makes it. The chief is the one voice between you and everything technical. The WhatsApp chat talks as the chief: before it answers about work, it reads `fraim-lead brief` (the chief's brief and notes, what you were told, recent tasks with what they were for, coding sessions, leads, automations, open decisions and your rules) and tells you what each thing means, without ids. Every message you read also gets the plain-words rules from `fraim-style prompt`.

Besides the chat, it has these runs.

| Run | Starts when | It does | It tells you |
|---|---|---|---|
| Morning digest | its schedule (default 07:30) | reads all leads and the open queue, fixes priorities | one digest, or nothing (`SILENT`) |
| Event | `chief-events` sees new queue items (checked every 15 minutes, 07:00 to 22:00) | routes each new thing | only when you must act today |
| Your request | any WhatsApp message that asks for work (the server's Claude passes it on), or `fraim lead ask -- "..."` | routes your request | always: what it did |

The events are new open queue items: goal results, failures, automation answers (such as the Gmail and Linear watchers) and anything priority 1. A lead's own ideas wait for the morning digest. Items the chief added itself never wake it.

Routing means one of:

1. **Start it**: a goal, within its budget (default 2 per day, in `~/fraim/leads/chief/budget`). The result lands in your queue.
2. **Hand it to a lead**: `fraim-lead tell <lead> --from chief -- "..."`. The note wakes the lead within minutes, and the lead reports back to the chief the same way.

### Who talks to whom

Everyone can send a note to everyone, and a note wakes the receiver now:

| From | To | How |
|---|---|---|
| Chief | a lead | `fraim-lead tell <lead> --from chief -- "..."` |
| A lead | the chief or another lead | `fraim-lead tell <name> --from <lead> -- "..."` |
| A goal | the lead that started it | automatic when the goal ends (done or failed) |
| You (queue decision) | the lead or chief that added the item | automatic when you approve, reject or dismiss |
| You (WhatsApp) | the chief or one lead | `fraim-lead ask`, or `fraim-lead tell` from the server's Claude |

A lead that is running when a note arrives runs once more when it ends. `--later` leaves a note without waking. To stop two leads from waking each other forever, a chain of notes stops waking after 6 hops (`FRAIM_LEAD_MAX_DEPTH`); the note then waits for the next run.
3. **Ask you**: a decision in the queue, with the work to start when you approve.

The chief cannot send mail, post, pay, merge or deploy. `fraim lead events chief --off` stops the event runs; `--every 30m` checks less often.

Watchers feed the queue from outside. The examples `mail-requests` (Gmail) and `linear-new` (Linear) check every 30 minutes and add a decision when someone asks something: `fraim-auto new mail-requests --from mail-requests`.

`fraim lead pause web` stops a lead without deleting it.

### One voice on WhatsApp

When a chief exists, it writes every message the server sends you on its own. Goals, coding sessions, leads, automations and health checks call `fraim-notify`. `fraim-notify` hands their raw notice to `fraim-relay`, and the chief turns it into one plain message. The message says what the work was about in your words, what happened, what it means and what it advises. It ends with the one question that waits for you. It has no ids (`g7`, `s2`, `q8`) and no reply syntax. You answer in your own words. The server's Claude reads `fraim-relay said`, which logs each message with the notices and ids behind it, and passes your answer to the right goal, session or queue item.

- Notices that arrive within 20 seconds of each other become one message (`FRAIM_RELAY_WAIT`).
- The owner gets at most one message per 15 minutes (`FRAIM_RELAY_GAP`, seconds). Notices that come in sooner go into the next message. The chief holds back check-ins and questions it already asked.
- Noise, such as a test or a repeat, can stay unsent (`SILENT`). It is still logged. A question, a failure or a server problem is always sent.
- When the chief cannot run (not signed in, usage limit, more than 180 seconds), the raw notice goes out, so nothing is lost.
- Some messages skip the chief and go out word for word: its own digest and answers, rules the brain saved, an approval from the command line, and permission prompts.
- `FRAIM_RELAY=off` in the runtime env turns the relay off. Pausing the chief does the same.

## The engineer

The chief manages; the engineer builds. `fraim lead new engineer --engineer` makes it (one per server). It is a lead like the others, so it can send and receive notes, shows in `fraim-auto list` and the Active view, and reports to the chief.

```
you: "send me the Meta ad spend every Monday"
  └─► server's Claude ──tell──► engineer ──builds, tests (switched off)──► queue: "Switch on: ...?"
                                   ▲                                          │ you approve
  chief, any lead ──tell───────────┤                                          ▼
  failed automation ──tell─────────┘                               fraim-auto on: it runs
```

| Work | Who asks | What the engineer does |
|---|---|---|
| New automation, reminder, report, watcher | you, the chief, a lead | `fraim-auto new NAME --off`, writes it, `check`, `run --dry`, then one queue item with `--switch-on NAME` |
| New lead | you, the chief | `fraim-lead new NAME --off`, writes the brief, same queue item |
| Change to an automation that runs | you, the chief | edits, checks, dry-runs; it stays on. New people or tools reached: asks first |
| Failed automation | the runner, on its own | finds the cause and fixes it; tells the chief. The queue item only informs. A login or a usage limit goes to you |
| Trigger or output plugin | anyone | writes it in `~/fraim/automations/_triggers` or `_outputs` and tests it through an automation |
| Skill | anyone | drafts it and proposes it with `fraim-brain skill propose`; you approve |
| Bug in fraimwork itself | anyone | a goal in `~/code/fraimwork` that opens a pull request; never merges or deploys. Without the repo on the server: an idea in the queue |
| Login, key, MCP server, server update | anyone | a queue item that tells you what to ask Claude on your laptop |

Guards:

- **New things start off.** While the engineer runs, `fraim-auto new` and `fraim-lead new` always make it switched off (`FRAIM_LEAD_ROLE=engineer`), even when it forgets `--off`.
- **Only you switch on.** Approving a `--switch-on NAME` item runs `fraim-auto on NAME`: it removes `enabled: false`, resumes a paused lead and updates the scheduler. A headless run (goal, lead, automation) cannot run `fraim-auto on`, and the engineer's tools do not include `resume`.
- **No loops.** A failure of the engineer's own runs goes to the queue as before, not back to the engineer.
- It cannot send mail or messages, post, pay, merge or deploy.

### Hiring

The chief and the engineer grow your team for you. A lead is an employee with one area of one of your companies or projects: a product, a repo, ads, sales, support, finance or ops.

1. The chief notices work that no lead owns: three or more items or notes in two weeks, or one lead's area that is too big. It tells the engineer: "Hire: someone for <area> of <company> because <what it saw>". It sends at most one hire a week and never repeats one you turned down.
2. The engineer creates the lead switched off and writes the brief from what is really on the server: repos, automations, APIs and your rules.
3. You get one question: "Hire someone for ads of the shop: checks spend and sales every weekday morning?" When you approve, the lead is hired and starts working.

On a fresh server, with only the chief and the engineer, both suggest a first team of at most 3 leads for the areas with the most going on. You can also just say "I need someone for X". The chief passes it to the engineer in the same way.

Its schedule (default Monday 06:00) is a weekly check for automations that fail, are paused or answer nothing useful. All other runs start from a note.

## The brain

`fraim-queue` gives every reason you write to the brain as evidence. Every Sunday at 20:00 the brain proposes rule changes as one queue item; approve applies them, reject with a reason makes it try again. Goals can propose skills the same way. `remember: ...` on WhatsApp adds a rule at once. Details: [brain.md](brain.md).

## Costs

Every lead run and every goal is a Claude run on your plan. Start with one lead per product and a budget of 3 goals per day. Raise it when the queue stays short.

## Not built yet

- Screen recordings depend on the agent: the server browser makes screenshots, but there is no recorder in the image yet.
- The chief cannot merge duplicate items; it reports them in the digest.
