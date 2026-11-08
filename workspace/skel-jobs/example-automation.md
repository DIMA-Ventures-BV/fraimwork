---
description: An example. Change enabled to true to switch it on, or ask Claude to make your own.
schedule: "0 8 * * 1-5"
tools: Read, Glob, Grep
output: whatsapp
enabled: false
---
List the files that were added to ~/fraim/inbox and ~/fraim/downloads since {{since}}, with one line per file.

If there are no new files, answer with exactly: SILENT
