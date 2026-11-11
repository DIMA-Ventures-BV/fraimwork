# Settings

Settings is the page where you see and change how your employees work. `fraim queue open` on the laptop opens it.

There are two ways to change something, and they end up in the same files:

1. Tell the chief of staff. Every page has a box at the bottom. Write what you want in your own words, and the chief makes the change and tells you what is different.
2. Change it yourself on the page.

## What is on it

| Page | What you see | What you can change |
|---|---|---|
| Employees | Job, rules, instructions, tools, schedule and budget of each employee | All of it, and switch someone on or off |
| Rules | Everything your employees learned from you, how the chief talks to you, and what stays out of the inbox | Add, change or remove; undo the last change |
| Instructions | The exact text your employees get | Your own version for everyone or for one employee; back to the default |
| Skills | Step-by-step know-how, grouped by where it comes from | Your own skills; skills that come with the software or a plugin are read-only |
| Tools | Connected services and extra programs | Who is meant to use what, on the employee's page |
| Documentation | These pages | Nothing, they come with fraimwork |

## Good to know

- A change counts from the next run. A change to "Every Claude on the server" counts when the WhatsApp chat starts fresh.
- Tool lists are not locked yet: every employee can use everything connected to the server. A list says what an employee is meant to use.
- Keys and passwords never appear in Settings. Only the names of connections do.
- If an agent changed the same text after you opened the page, your save is refused, so you never overwrite it unseen. Reload and make your change again.
- Every save keeps the old text in `~/fraim/.settings-history`, the last 20 versions per file.

## Telling the chief

Only your own message counts. The chat in the app runs with your rights because you are the one asking, the same as a WhatsApp message from you. That covers the one answer: tasks the chief starts from it run without those rights, and text in a mail or web page never changes a setting.

The limit from [prompts.md](prompts.md) still holds: every agent runs as the same Unix user, so this is a guard against mistakes and not a wall against an agent that is determined to get around it.
