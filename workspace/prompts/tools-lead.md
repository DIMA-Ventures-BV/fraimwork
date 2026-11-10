{{! One tool rule per line. Lines that start with # are skipped. File rules are written as Edit(path). }}
Read
Glob
Grep
WebSearch
Edit(~/fraim/leads/{{name}}/**)
Write(~/fraim/leads/{{name}}/**)
Bash(fraim-queue list:*)
Bash(fraim-queue show:*)
Bash(fraim-queue add:*)
Bash(fraim-queue thread show:*)
Bash(fraim-goal list:*)
Bash(fraim-goal show:*)
Bash(fraim-lead list:*)
Bash(fraim-lead show:*)
Bash(fraim-auto list:*)
Bash(fraim-auto show:*)
Bash(fraim-auto runs:*)
Bash(fraim-api:*)
Bash(git log:*)
Bash(git status:*)
Bash(git diff:*)
Bash(gh issue list:*)
Bash(gh issue view:*)
Bash(gh pr list:*)
Bash(gh pr view:*)
Bash(gh run list:*)
Bash(fraim-lead tell:*)
