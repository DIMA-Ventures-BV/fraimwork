# Channels

A channel is a way a message reaches the server or leaves it. WhatsApp and email have the same shape, so a new one (Telegram, Slack) is one entry in a list and one small service.

```
outside world --> channel service --> fraim-channels --> inbox and chief of staff
                  (WhatsApp gateway,
                   mail watcher)      fraim-queue --> owner's yes --> channel service --> outside world
```

`fraim-channels list` shows every channel and how it is doing. `fraim doctor` fails when one that should work has stopped.

## What every channel shares

| Rule | Where |
| --- | --- |
| A message delivered twice is handled once | `claim()` in `workspace/bin/fraim-channels.mjs`, one file per message, so two processes cannot both win |
| `never:` lines in `inbox-rules.md` keep a sender out | `neverShow` in `workspace/bin/fraim-queue-threads.mjs` |
| People outside are data for the chief, never a chat with Claude | the inbox (`fraim-queue thread`) |
| An agent only drafts; the owner's yes sends the exact text | `fraim-queue reply`, then `sendReply()` |
| The recipient comes from the conversation, never from an agent | each channel's `target()` |

Who may chat with Claude stays per channel. The WhatsApp gateway checks the owner and the allowlist before it downloads a file. Mail never reaches a chat.

## Adding a channel

Add one entry to `CHANNELS` in `workspace/bin/fraim-channels.mjs`:

| Field | Meaning |
| --- | --- |
| `id`, `word`, `module` | its name, the word the owner reads, the module that switches it on |
| `base(env)` | the address of its service |
| `conversation(key)` | the id inside a conversation key such as `gmail:ID` |
| `target(id, thread, call)` | who an answer goes to |
| `reply(r)` | the body for `POST /reply` |
| `status`, `healthy`, `describe` | for `fraim-channels list` and the doctor |
| `inbound` | optional: the service reports through `POST /events`, and `fraim-channels events` reads it |

The service needs `POST /reply` with the `REPLY_TOKEN`. An inbound one also needs `POST /events {after, wait}`, which answers `{events: [{seq, id, ...}], last}`. Messages must be kept on disk, so a restart loses nothing. The owner's own chat is still WhatsApp only.

## WhatsApp

- The gateway keeps waiting messages on disk (`/data/queue.json`).
- Messages that arrived while it was away are read for 12 hours back (`WHATSAPP_CATCHUP_HOURS`). They carry a note with the time they were sent. A `yes abcde` that waited is read as plain text and approves nothing.
- A failed reconnect tries again, up to once a minute. After 5 minutes down the gateway restarts itself, unless it waits for a QR code or the phone logged it out.

### Groups

- Groups are closed by default. `WHATSAPP_GROUPS` lists the group ids the server listens in (`1203630...@g.us`, comma separated), or `all`. On the laptop: `fraim whatsapp groups` lists the groups the agent number is in, and `fraim whatsapp listen GROUP_ID|all|off` sets the list and restarts the gateway.
- In an open group, only members on the allowlist (`WHATSAPP_OWNER`, `WHATSAPP_ALLOW`) reach Claude. Other members stay unheard.
- A group message has `chat_id` set to the group, plus `group` (its name) and `addressed` (true when it @mentions the agent number or replies to it). Claude answers in the group, and a goal started from it sends its result there.
- Claude stays quiet when people in the group talk to each other. Only an addressed message gets the reminders when it stays unanswered.
- The owner's private-chat context (the conversation log, waiting decisions) and `session_command` stay with the owner's private chat. A yes in a group is still the owner's yes when the owner wrote it.

## New mail

`google/fraim-mail-watch` asks Gmail what changed and writes the id and sender's address of each new mail to `mail-events.jsonl`. Mail in Promotions, Social and Forums is left out.

**A new message starts nothing by itself.** The watcher only records. No agent runs and no Claude usage is spent until a trigger is switched on. The scheduled `mail-requests` automation keeps working as before.

An automation opts in with one line, `trigger: mail: from:@mollie.com,anna@example.com` or `trigger: mail: all`. Each check (every 5 minutes by default) costs no Claude usage; Claude runs only when a named sender wrote, once per check, with the Thread IDs as `{{input}}`. Start from the example: `fraim-auto new NAME --from mail-from`. A From address can be faked, so a trigger only decides what starts: the mail stays data, and answering still needs the owner's yes.

The watcher looks every 30 seconds. Google push makes it seconds and needs no public address, because the server pulls the subscription.

### Turning on Google push (once, about 10 minutes)

Claude runs this on the laptop, in the Google Cloud project of your OAuth client:

```
gcloud services enable pubsub.googleapis.com
gcloud pubsub topics create fraim-mail
gcloud pubsub topics add-iam-policy-binding fraim-mail --member=serviceAccount:gmail-api-push@system.gserviceaccount.com --role=roles/pubsub.publisher
gcloud pubsub subscriptions create fraim-mail-pull --topic=fraim-mail --message-retention-duration=1h
gcloud iam service-accounts create fraim-mail-pull
gcloud pubsub subscriptions add-iam-policy-binding fraim-mail-pull --member=serviceAccount:fraim-mail-pull@PROJECT.iam.gserviceaccount.com --role=roles/pubsub.subscriber
gcloud iam service-accounts keys create key.json --iam-account=fraim-mail-pull@PROJECT.iam.gserviceaccount.com
fraim google push --topic projects/PROJECT/topics/fraim-mail --subscription projects/PROJECT/subscriptions/fraim-mail-pull --file key.json
rm key.json
```

The key can only read that one subscription. `fraim google status` shows `new mail: Google push`. `fraim google push --off` goes back to checking.

## The owner channel: the gateway contract

How the owner and fraimwork reach each other: WhatsApp today, something else tomorrow. The contract is the HTTP API of the WhatsApp gateway (`whatsapp/gateway.mjs`). A second owner channel is a service that serves the same routes.

### The seam

`fraim-gateway` and `fraim-notify` use `FRAIM_CHANNEL_URL` and `FRAIM_CHANNEL_TOKEN` when the URL is set. Otherwise they use `FRAIM_GATEWAY_URL` and `FRAIM_GATEWAY_TOKEN` and need the `whatsapp` module.

To point a server at another channel, put `CHANNEL_URL` and `CHANNEL_TOKEN` in its `.env` and restart the workspace. A channel URL without a token is refused, so the WhatsApp token never reaches another service.

### Routes

Every route except `GET /health` needs `Authorization: Bearer TOKEN` and answers `401 {"error": "unauthorized"}` without it. Other errors are JSON too: `{"error": "what went wrong"}`, with a 4xx status for a bad request and 503 while the channel is not connected.

| Route | Body | Answer |
|---|---|---|
| `GET /health` | | `200 {"ok": true}` when the service runs, connected or not. No token. |
| `GET /status` | | `200 {"connected": true, "me": "ID", "queued": 0, "listeners": 1}` |
| `GET /events` | | A stream of server-sent events, see below. |
| `GET /groups` | | `200 [{"id": "1203630@g.us", "name": "Team", "open": true}]`, WhatsApp only |
| `POST /send` | `{"chat_id": "ID", "text": "hi"}` or `{"to": "ADDRESS", "text": "hi"}` | `200 {"ok": true}` |
| `POST /send-file` | `{"chat_id": "ID", "path": "fraim/report.pdf", "caption": "..."}`, or `to` instead of `chat_id` | `200 {"ok": true}` |

`connected` says whether the channel can deliver right now. `listeners` is the number of open `/events` streams. `fraim-doctor` reads both.

`POST /send` with an empty `to` and no `chat_id` means the owner: `fraim-notify` sends that when `WHATSAPP_OWNER` is empty. The WhatsApp gateway answers 400 there, because it always has an owner.

`path` in `/send-file` starts with `fraim/` or `pc/` and is relative to the shared folders. The service mounts them read-only, as `whatsapp` does in `compose.yaml`, and refuses a path that leads outside them.

### Events

`GET /events` answers with `Content-Type: text/event-stream`. Each message is one `data:` line of JSON. Send a comment line (`: ping`) at least every 30 seconds so a dead connection shows.

```
data: {"type":"message","id":"M1","chat_id":"C1","sender":"31612345678","name":"Ann","text":"hello","ts":1762790000}
```

| Field | Meaning |
|---|---|
| `type` | `message` for the owner and allowed people, `contact` for someone the owner only wants to hear about. Other types are ignored. |
| `id` | The message's id on the channel. |
| `chat_id` | Where an answer goes, passed back to `/send`. Only on `message`. |
| `sender` | Who wrote it. The owner is recognized by comparing this with the owner's address. |
| `name` | Display name, may be empty. |
| `text` | The words. Attachments are saved to the inbox and named in the text. |
| `voice`, `video` | Optional: shared path of a saved audio or video file. |
| `quote` | Optional: the message this one replies to. |
| `ts` | Unix time in seconds. |

### What a channel must do

1. Serve the routes above, on a network the workspace can reach.
2. Check the sender. Only people the owner allowed may produce `message` events; drop the rest.
3. Keep events while nobody listens, up to 100, and deliver them when a stream opens. Claude restarts, and a message may not vanish then.
4. Accept long text: split it when the service has a size limit.
5. Serve `/health` without a token, for Docker.

Ship it as a module: a service with its own compose profile and a `modules/NAME.manifest` with its health checks.

### Not generic yet

`fraim-gateway` and `fraim-notify` are the only callers that know about `FRAIM_CHANNEL_URL`. These still talk to WhatsApp directly:

- `workspace/channel/whatsapp-channel.mjs`, the listener that feeds `/events` to the Claude session and handles approvals. It reads `FRAIM_GATEWAY_URL`, and `fraim-entrypoint` only registers it with the `whatsapp` module on.
- `fraim-channels`, for approved replies to contacts (`POST /reply`, which is not part of this contract).
- `fraim whatsapp` on the laptop, and the pairing routes `/pair` and `/qr.png`, which are specific to WhatsApp.

So a second channel can receive notices and answer `fraim-gateway` today. Bringing its messages into the Claude session needs that listener made generic first.
