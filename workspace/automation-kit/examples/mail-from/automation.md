---
description: Mail from the senders named below lands in the inbox as a conversation and tells the chief of staff. Mail from anyone else starts nothing
trigger: mail: from:@example.com
every: 5m
tools: Bash(fraim-queue thread mail:*)
model: haiku
timeout: 5m
output: none
---
The Thread IDs of new mail, one per line:

{{input}}

For each Thread ID run: fraim-queue thread mail <the Thread ID>
That saves the real mail for the owner and tells the chief of staff. Do not read or summarise the mail.

Then answer with exactly: SILENT
