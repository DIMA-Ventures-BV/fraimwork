# The brain

The brain is what the server's agents learn about you. You stay in charge of it: agents propose changes, and only your approval in the queue applies them.

```
your reasons in the queue ─┐                         ┌─► rules.md   (goal and lead prompts)
what you tell Claude ──────┼─► log.md (evidence) ────┤
fraim-brain note ──────────┘    e1, e2, ...          └─► proposals ─► queue ─► you approve ─► applied

goal finishes ─► skill folder ─► fraim-brain skill propose ─► queue ─► you approve ─► ~/.claude/skills
```

## Three kinds of memory

| Memory | File | What it holds |
|---|---|---|
| Evidence | `~/fraim/brain/log.md` | Every reason you gave and every preference you stated, one line each, with an id (`e12`). Nothing edits or deletes it. |
| Rules | `~/fraim/brain/rules.md` | One-line rules in sections. Each rule has an id and cites its evidence: `- Never use emoji. [r4: e2 e9]`. |
| Skills | `~/.claude/skills/NAME/SKILL.md` | Step-by-step know-how: when to use it, steps, pitfalls, how to check the result. Claude loads one when a task fits. |

## How rules change

| Who | How | Needs approval |
|---|---|---|
| You | a preference or correction in your own words on WhatsApp, or `fraim brain note "..."` | No. It applies at once. |
| You | "drop that rule", "undo the last change" on WhatsApp; `fraim brain forget r4`, `fraim brain undo` | No. |
| The chat review (every 10 minutes, once a chat pauses) | Claude rereads your new messages and finds lasting preferences by meaning, in any words or language | A preference you stated: no, it applies at once and WhatsApp tells you its id. A correction it generalized: yes, one queue item. |
| The weekly distill (Sunday 20:00) | Claude reads new evidence and proposes add, change or remove steps | Yes. The proposal is one queue item. |

A proposal is checked before it reaches you: every step must cite events that exist, a change or removal must name a rule that exists, a rule is one line of at most 300 characters, and the file holds at most 60 rules. A proposal that fails a check is dropped and the rules stay the same.

The distill only adds a rule when you stated it as a general preference, or when at least two events point the same way. One correction of one piece of work is not a rule yet.

When you reject a proposal, give a reason: the brain proposes again with it. While a proposal waits, no new one is made.

Every change keeps the previous file in `~/fraim/brain/history/`, so `undo` always works. `fraim brain history` lists the changes and `fraim brain why r4` shows the events behind a rule.

## The chat review

You never need a keyword. `fraim-brain review` runs every 10 minutes and reads the server's Claude sessions: WhatsApp, the laptop and the phone app. It waits until a chat has been quiet for 5 minutes, or until 10 new messages pile up, the same as the background review in Hermes. Without new messages it does not call Claude.

- It reads only your messages. Messages from other WhatsApp numbers, tool output, web pages and mails never count. Claude's answers are context only.
- Every item must quote your own words exactly, or it is dropped. So a page that says "always do X" can never become a rule.
- Goals, leads and automations run headless and are skipped.
- On its first run it reads the last 2 days of chats, not everything.
- Its answer is checked like a distill proposal. When the answer is broken, nothing changes and the same messages are read again next time.

A preference you state directly ("from now on, ...") is saved at once without waiting for the review.

## Rules per lead

Sections named `Lead <name>` hold rules for one lead's area. A lead and its goals get the general sections plus their own; the chief of staff gets all of them. Other leads never see them. Reasons given on a lead's queue items name the lead, so the distill can file them there.

## Skills

When a goal finds a procedure worth reusing (a multi-step task that will come back, a dead end it got past, or your correction of how to do something), it writes a skill folder and runs `fraim-brain skill propose DIR`. The queue item shows the whole skill, or for a change, the diff.

Checks before it reaches you: `SKILL.md` with a name and a description that says when to use it, at most 20 files and 256 KB, plain text only, no links. Invisible characters and anything that looks like a key or token are refused. A download piped into a shell, a delete of a home folder, or text that tells the agent to ignore instructions raise the item to priority 1 with a warning.

The brain only changes skills it installed itself. Your own skills and plugin skills stay as they are. `fraim-brain skill lock NAME` freezes a brain skill. A replaced version is kept in `~/fraim/brain/history/skills/`.

## Limits

- Only you decide. Every headless run (goal, lead, automation) is marked by `fraim-claude`, and `fraim-queue approve/reject/dismiss`, `fraim-brain note/forget/undo/apply` and skill installs refuse it. The internal commands (`apply`, `discard`, `skill install/discard`) are also denied to every Claude by the managed settings. An approval of a brain change from the command line sends you a WhatsApp message with *undo rules*. All of this runs as one Unix user, so a run that works hard to get around it could; a separate user per run would close that, and is not built.
- The chat review uses Sonnet (`FRAIM_BRAIN_MODEL` changes it). A preference it misses still reaches the weekly distill only through the queue, so check `rules` now and then.
- Whether it helps: `fraim brain stats` (or ask on WhatsApp how the rules are doing) shows how much work you sent back per week. Brain proposals and skills do not count. That share should go down as the rules grow.

## Where the design comes from

The memory split (evidence, rules, skills), the patch-style edits, the size limits and the approval gate follow Nous Research's [Hermes Agent](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory). Treating a generalization as a guess until more evidence supports it, and keeping each rule linked to its evidence, follow [current work on agent memory](https://alpeshnakrani.com/books/memory-systems-for-agents/reflection-consolidation-and-the-summaries-that-lie/).
