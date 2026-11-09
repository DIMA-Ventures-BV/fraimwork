# Leads, the review queue and the brain

You decide. Agents do the rest. Everything that needs you lands in one ranked list, and every decision you make teaches the agents what you want.

```
lead agents (one per area, on a schedule)      the chief of staff (daily)
   │ start goals, propose ideas                   │ ranks the queue, sends one digest
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
| Leads | `fraim-lead` | `~/fraim/leads/<name>/` and a line in `~/fraim/jobs/crontab` |
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
- **WhatsApp:** `queue`, `ok q3`, `ok q3 <note>`, `no q3 <why>`, `skip q3`, `remember: <preference>`, `leads`.
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

1. starts goals for clear work (`fraim-goal start --lead web`), at most `budget` per day (default 3);
2. adds ideas and decisions to the queue, at most 3 per run;
3. rewrites its notes.

A lead cannot send mail, post, pay, merge or deploy. Its tools are narrow: read files, the queue, goals, `fraim-api`, and read-only `git` and `gh`. Add more in `~/fraim/leads/<name>/tools`, one per line.

You get one WhatsApp message per run, and none when the lead found nothing.

The chief of staff (`--chief`) starts no goals. It reads all leads and the open queue, fixes priorities and sends one daily digest. It answers `SILENT` when nothing needs you.

`fraim lead pause web` stops a lead without deleting it.

## The brain

`fraim-queue` gives every reason you write to the brain as evidence. Every Sunday at 20:00 the brain proposes rule changes as one queue item; approve applies them, reject with a reason makes it try again. Goals can propose skills the same way. `remember: ...` on WhatsApp adds a rule at once. Details: [brain.md](brain.md).

## Costs

Every lead run and every goal is a Claude run on your plan. Start with one lead per product and a budget of 3 goals per day. Raise it when the queue stays short.

## Not built yet

- Screen recordings depend on the agent: the server browser makes screenshots, but there is no recorder in the image yet.
- The chief cannot merge duplicate items; it reports them in the digest.
