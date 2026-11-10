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

## Replacing the brain

The brain is content: you can run your own instead of this one. Put an executable at `~/fraim/automations/_brain/brain` (`FRAIM_AUTOMATIONS_DIR` moves the folder). `fraim-brain` stays the command everyone calls and hands over to your program, with the same arguments, the same input and output, and its exit code.

What your program must do:

| Action | Contract |
|---|---|
| `show [--for LEAD] [--all] [--plain]` | Required. Prints the text that goes into a prompt, at most 6000 characters. Empty is valid. `--for` names the lead; `--all` adds every lead's rules. `show --plain` without `--for` is also called. |

Optional: `note`, `forget`, `undo`, `why`, `history`, `stats`, `review`, `distill`, `log`, `apply`, `discard`, with the arguments listed at the top of `workspace/bin/fraim-brain`. An action you do not have exits 2, and callers cope with that: the review and distill cron jobs do nothing, a reason you give in the queue is not saved, and a rule change from Settings shows an error. Without `apply` and `discard`, the default brain handles them, so a proposal that waited in the queue before you switched can still be closed.

Plain `show` (no options) is what Settings reads and what `fraim brain show` prints. To list rules on the Settings page, print `## Section` headings and `- text [r1]` lines; other lines are ignored. Changing a rule from Settings calls `note`, `forget` and `undo`.

What stays with the engine:

- `fraim-brain skill ...` never goes to your program. Installing a skill needs your yes, and that stays in the engine.
- `note`, `forget`, `undo`, `apply` and `discard` are refused for a run nobody watches, before your program starts.
- A program written by a run nobody watches, or any other file in that folder changed by one, is marked and ignored until your yes (`fraim-auto on`); the default brain runs meanwhile. What you write or ask for in the chat goes live at once.

Every call has a time limit: 20 seconds, or `FRAIM_BRAIN_PLUGIN_TIMEOUT` seconds. When `show` runs out of time it prints nothing and exits 0, so prompts still build. Any other action that runs out of time is handed to the default brain, so a `review` or `distill` that needs longer needs a higher limit, and an action cut off halfway also runs in the default brain. `show` output longer than 6000 characters is cut at the last line end before the limit.

If your program crashes on `show`, prompts go out without rules: every caller discards the error and carries on. If it exists but cannot start, other actions fail with an error instead of quietly writing to the default brain.

To build on the default, call `fraim-brain` from your program. Your program runs with `FRAIM_BRAIN_BUILTIN=1`, so that call reaches the default and not your program again. Set the same variable yourself to skip your program from outside.

## Where the design comes from

The memory split (evidence, rules, skills), the patch-style edits, the size limits and the approval gate follow Nous Research's [Hermes Agent](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory). Treating a generalization as a guess until more evidence supports it, and keeping each rule linked to its evidence, follow [current work on agent memory](https://alpeshnakrani.com/books/memory-systems-for-agents/reflection-consolidation-and-the-summaries-that-lie/).
