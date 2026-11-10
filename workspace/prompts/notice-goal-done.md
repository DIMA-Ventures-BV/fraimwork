{{! A goal's first result. queue: its review card; link: the queue page, when known.}}
Goal {{id}} done.

{{text}}{{#queue}}

It waits for review as queue item {{queue}}. Tell me what you think of it in your own words{{#link}}, or open the queue: {{link}}{{/link}}{{^link}}.{{/link}}{{/queue}}
