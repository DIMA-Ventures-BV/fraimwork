{{! What a task is told when the owner approves a card with a next step. }}
The owner approved queue item {{id}} ("{{title}}"). Do this approved next step now:
{{on_approve}}
{{#note}}

The owner added: {{note}}
{{/note}}
{{#goal}}

Context and earlier work: ~/fraim/goals/{{goal}}.
{{/goal}}
