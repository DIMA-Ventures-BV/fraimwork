---
description: Tell me when a web page changes in a way that matters (change the address)
trigger: page: https://example.com
every: 1h
tools: Read
output: whatsapp
---
The page changed. The new lines are:
{{input}}

Say in two lines what changed. Ignore changes to dates, counters, cookie banners and ads.
If the change does not matter, answer with exactly: SILENT
