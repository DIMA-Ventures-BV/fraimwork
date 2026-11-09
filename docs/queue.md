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
- **The chief works all day.** Its `chief-events` automation wakes it when a goal result, a failure, an automation answer or a priority 1 item lands in the queue, and `chief: ...` on WhatsApp wakes it at once. See "The chief of staff" below.
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

- **Page:** `fraim queue` on the laptop opens it. Keys: `j`/`k` move, `a` approve, `r` reject, `d` dismiss, `n` write a note, `v` dictate a note, `1` `2` `3` priority. The page is on the tailnet only and needs the link with the token once (the browser then keeps a cookie).
- **WhatsApp:** `queue`, `ok q3`, `ok q3 <note>`, `no q3 <why>`, `skip q3`, `remember: <preference>`, `leads`, `chief: <message>`.
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

1. acts first on its inbox (`~/fraim/leads/<name>/inbox.md`: notes from the owner and the chief, written with `fraim-lead tell web -- "..."`);
2. starts goals for clear work (`fraim-goal start --lead web`), at most `budget` per day (default 3);
3. adds ideas and decisions to the queue, at most 3 per run;
4. rewrites its notes.

A lead cannot send mail, post, pay, merge or deploy. Its tools are narrow: read files, the queue, goals, `fraim-api`, and read-only `git` and `gh`. Add more in `~/fraim/leads/<name>/tools`, one per line.

You get one WhatsApp message per run, and none when the lead found nothing.

## The chief of staff

`fraim lead new chief --chief` makes it. It has two kinds of run.

| Run | Starts when | It does | It tells you |
|---|---|---|---|
| Morning digest | its schedule (default 07:30) | reads all leads and the open queue, fixes priorities | one digest, or nothing (`SILENT`) |
| Event | `chief-events` sees new queue items (checked every 15 minutes, 07:00 to 22:00) | routes each new thing | only when you must act today |
| Your message | `chief: <message>` on WhatsApp, or `fraim lead ask -- "..."` | routes your request | always: what it did |

The events are new open queue items: goal results, failures, automation answers (such as the Gmail and Linear watchers) and anything priority 1. A lead's own ideas wait for the morning digest. Items the chief added itself never wake it.

Routing means one of:

1. **Start it**: a goal, within its budget (default 2 per day, in `~/fraim/leads/chief/budget`). The result lands in your queue.
2. **Hand it to a lead**: `fraim-lead tell <lead> --from chief -- "..."`. The lead acts on it at its next run.
3. **Ask you**: a decision in the queue, with the work to start when you approve.

The chief cannot send mail, post, pay, merge or deploy. `fraim lead events chief --off` stops the event runs; `--every 30m` checks less often.

Watchers feed the queue from outside. The examples `mail-requests` (Gmail) and `linear-new` (Linear) check every 30 minutes and add a decision when someone asks something: `fraim-auto new mail-requests --from mail-requests`.

`fraim lead pause web` stops a lead without deleting it.

## The brain

`fraim-queue` gives every reason you write to the brain as evidence. Every Sunday at 20:00 the brain proposes rule changes as one queue item; approve applies them, reject with a reason makes it try again. Goals can propose skills the same way. `remember: ...` on WhatsApp adds a rule at once. Details: [brain.md](brain.md).

## Costs

Every lead run and every goal is a Claude run on your plan. Start with one lead per product and a budget of 3 goals per day. Raise it when the queue stays short.

## Not built yet

- Screen recordings depend on the agent: the server browser makes screenshots, but there is no recorder in the image yet.
- The chief cannot merge duplicate items; it reports them in the digest.
