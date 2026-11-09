---
description: Every Friday afternoon, a short report of the week from the automation answers, kept as a file
schedule: "0 16 * * 5"
tools: Read, Glob, Grep
output: file: reports/week-{date}.md, whatsapp
---
Read ~/fraim/outbox.md. Write a short report of what my automations found since {{since}}: the three things that matter most first, then the rest in one line each.
If there was nothing, answer with exactly: SILENT
