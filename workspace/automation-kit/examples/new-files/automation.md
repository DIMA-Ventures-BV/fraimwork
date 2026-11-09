---
description: New files in ~/fraim/inbox and ~/fraim/downloads, every weekday morning
schedule: "0 8 * * 1-5"
tools: Read, Glob, Grep
output: whatsapp
---
List the files that were added to ~/fraim/inbox and ~/fraim/downloads since {{since}}, with one line per file.

If there are no new files, answer with exactly: SILENT
