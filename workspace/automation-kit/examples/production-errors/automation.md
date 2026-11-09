---
description: Every new production error gets a goal that finds the cause and prepares a fix (set the channel and the repo at the top of check.sh)
every: 5m
script_only: true
output: none
---
check.sh reads the new messages in the Slack channel a production app posts its errors to,
groups them by error event (the name between backticks, for example
`cron.question_reminder.not_delivered`), and starts one goal per error it has not handled in
the last day: at most 3 per run, the rest in the next runs. Each goal finds the cause in the
repo and opens a draft pull request with the fix; nothing is merged or deployed. No Claude
runs here, so nothing in an alert can steer this automation.
