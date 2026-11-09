---
description: Read each new file in ~/fraim/inbox and say in one line what it is and what to do with it
trigger: files: inbox
every: 5m
tools: Read, Glob, Grep
output: whatsapp
---
These files are new:
{{input}}

Read each one. Answer with one line per file: what it is (invoice, contract, letter, photo) and the action it needs, if any.
If none of them needs attention, answer with exactly: SILENT
