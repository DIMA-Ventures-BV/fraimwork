# shellcheck shell=bash disable=SC2034,SC2154

cmd_help() {
  cat <<'EOF'
fraim: control a fraimwork server (an always-on Claude Code server). Built to be run by Claude.

Conventions: never prompts without a terminal; long-running parts run in the background;
a human-only step prints one "HUMAN STEP: ..." line. Exit codes: 0 ok, 1 failure,
2 usage or missing input, 3 human step needed.

Join a server that someone else runs
  fraim invite NAME --share-url LINK | NAME --no-share   (operator) make an invite for one person
  fraim invite list | revoke NAME                        (operator) see or end invites
  fraim attach --stdin | --file INVITE [--use] | --check connect this computer with an invite
  fraim mirror scan [--out FILE]                         list this computer's Claude setup, names only

Try locally (Docker on this computer)
  fraim local up [--whatsapp-owner N] [--whatsapp-allow N,N] [--modules browser,whatsapp,scheduler]
                 [--port-offset N]   FRAIM_INSTANCE=NAME runs a separate stack (default: local)
  fraim local down [--wipe]

Real server
  fraim init --hostname NAME --access tailscale|public [--ts-authkey KEY]
             [--modules sync,browser,whatsapp,scheduler] [--tz Europe/Amsterdam]
             [--whatsapp-owner N] [--whatsapp-allow N,N] [--ssh-key PATH]
  fraim tailscale policy --email ADDR [--email-2 ADDR]   print the access policy to merge in Tailscale
  fraim tailscale key [--stdin]              save a Tailscale API token on this computer (Keychain)
  fraim tailscale apply [--email ADDR] [--yes]   merge the fraim rules into the tailnet policy via the API
  fraim tailscale reach tag:NAME|100.x.y.z [--port 22] [--yes]   let fraim servers reach that device
  fraim deploy root@IP [--force-env] [--take-over]   installs, then closes public SSH once Tailscale works
                                             (--take-over replaces a stale update lock)
  fraim lock                                 close public SSH (tailscale mode; checks access first)
  fraim update [--to vX.Y.Z] [--force]     install the latest release; rolls back if health checks fail
  fraim update --recover [--to vX.Y.Z]       finish an interrupted update: reinstall the last good version,
                                             or the given release when the last good one is unknown
  fraim use local|server

Operate
  fraim setup [--repo OWNER/REPO,...] [--no-full-login]
                                             finish every open setup step in order (Tailscale policy,
                                             lock, login, full login, sync, laptop config, GitHub);
                                             run again after each HUMAN STEP
  fraim status [--json]                      services and health checks
  fraim login [--token-stdin]                store a Claude login token on the server
  fraim ask "PROMPT" [--allow TOOLS] [--json]  one-off claude -p run on the server
  fraim goal "TASK" | list | show ID | stop ID  background task on the server; result on WhatsApp
  fraim goal send ID "MSG" | read ID | attach ID   talk to a live goal, see its screen, take it over
  fraim herdr link | unlink                  show the server's leads, goals and coding sessions live in
                                             the Herdr app on this computer (installs it when missing)
  fraim session [list | all | new REPO ["TASK"] | send ID "MSG" | read ID | attach ID | stop ID]
                                             coding sessions on the server (s1, s2, ...) that keep
                                             working with the laptop closed; all = every session
  fraim auto [list | show NAME | runs NAME | run NAME [--dry] | pause NAME | resume NAME | on NAME | check]
                                             automations in ~/fraim/automations (trigger, prompt, output)
  fraim queue [open|url|list|show ID|approve ID [NOTE]|reject ID NOTE|dismiss ID]
                                             questions for you (asked in chat); open/url: the settings page
  fraim lead new NAME [--area TEXT] [--at "CRON"] [--budget N] [--chief|--engineer] [--off] | list | show NAME | run NAME
           | tell NAME -- TEXT | ask [NAME] -- TEXT | events NAME [--off]
                                             lead agents that watch an area; the chief routes work, the engineer builds
  fraim brain [show | note "TEXT" | why rN | forget rN | undo | history | stats | distill | skills]
                                             preferences and skills learned from reviews
  fraim autoupdate [status|on|off|canary|stable|now]   the server installs new releases by itself
  fraim exec -- CMD [ARGS]                   run a command in the workspace as user claude
  fraim whatsapp status|link [--number N]|relink|test|check
  fraim browser [--print-url] | stop         server browser view URL and VNC password
  fraim browser --url-only                   only the fixed URL (no tunnel, no password; not in public mode)
  fraim chrome start|stop|status             lend a separate local Chrome profile to the server
  fraim sync [--print-url] | stop            Syncthing GUI URL and password
  fraim sync pair [--dir DIR]                pair this laptop's Syncthing with the space (~/fraim)
  fraim logs [SERVICE] [--tail N] [--follow]
  fraim support-bundle                       write a redacted debug file to send to a helper
  fraim restart [SERVICE]
  fraim reset-workspace                      recreate the workspace container (files kept)
  fraim config ...                           Claude config layer (see bin/fraim-config help)
  fraim secret list                          API keys held by the secrets proxy (names only)
  fraim secret add NAME --upstream https://HOST [--header H] [--format 'Bearer %s']
  fraim secret set NAME [--stdin]            store the key: hidden prompt, or piped (never an argument)
  fraim secret rm NAME
  fraim secret env NAME [--stdin] | env-rm NAME   key a tool reads from its environment
  fraim secret file PATH [--stdin]           credentials file at ~/PATH in the workspace
                                             (env and file keys are readable by Claude, as on a laptop)
  fraim tool add npm:PKG@VER|uv:PKG@VER ... | list | rm NAME   extra command-line tools for the space
  fraim mirror FILE [--yes] [--only KIND,...] [--dry-run]   set up the space from a mirror file (docs/mirror.md)
  fraim project add OWNER/REPO [--dry-run] [--yes --commit SHA]   install a repo's .fraim folder (docs/projects.md)
  fraim project update REPO [--dry-run] [--yes --commit SHA]      show and install what changed in it
  fraim project on REPO ITEM...|--all | list | export ITEM... --to DIR/.fraim
  fraim shell [main|g3|s1|NAME]              humans only: take over a session (Ctrl+\ leaves it)

Spaces: separate fraims on one server (own Claude, browser, keys, files). Every command
takes --space NAME; without it a command works on the main space. See docs/spaces.md.
  fraim space list [--json]                  every space, its SSH port and health
  fraim space add NAME [--modules browser,scheduler,whatsapp,sync] [--whatsapp-owner N]
  fraim space up NAME                        start a stopped space
  fraim space policy NAME [--deny 'claude.ai Gmail,NAME'|none] [--claudeai on|off] [--modules m,m]
  fraim space rm NAME [--wipe --yes]         stop a space; --wipe deletes all its data
  fraim login --from-space main              reuse another space's setup-token login (stays on the server)
  fraim login --full [--restart] | --code [--stdin] | --status
                                             full Claude login: Remote Control and claude.ai connectors
  fraim repo token [--owner ORG] [--stdin]   GitHub token for the space (git, API, GitHub MCP via the proxy)
  fraim repo add OWNER/REPO [--dir DIR] | list [--json] | setup [--git-name N --git-email E]
  fraim host add NAME --like SSH_ALIAS          same host, user and host keys as `ssh SSH_ALIAS` here
  fraim host add NAME --address HOST [--user U] [--port P] [--authorize-via SSH_ALIAS]
  fraim host test NAME | list [--json] | rm NAME [--authorize-via SSH_ALIAS]
  fraim connect NAME --url https://HOST/PATH                  MCP server without a key
  fraim connect NAME --url URL --oauth, then NAME --finish    MCP server with an OAuth sign-in
                                             (the browser lands on the server; --redirect pastes it)
  fraim connect NAME --url URL --key [--header H] [--format F] [--stdin]   key in the secrets proxy
  fraim connect NAME --command 'CMD ARGS' | list [--json] | rm NAME
  fraim google setup --email E --file F | code | status | signout   Gmail, Drive, Calendar for any agent
  fraim google push --topic T --subscription S --file KEY | --off   new mail within seconds (docs/channels.md)
  fraim preview [PORT] | stop [PORT|all] [--json]   show a dev server of the space on the phone
EOF
}
