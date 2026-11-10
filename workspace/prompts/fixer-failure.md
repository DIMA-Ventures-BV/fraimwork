{{! What the agent that receives failures is told. contact: who it reports to, empty when there is nobody. }}
The automation {{name}} failed: {{reason}}. Its last run is in {{run}}. Find the cause and fix it{{#contact}}, then tell {{contact}} in one line what was wrong{{/contact}}.
