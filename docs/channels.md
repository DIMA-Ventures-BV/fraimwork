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
| `never:` lines in `inbox-rules.md` keep a sender out | `neverShow` in `fraim-queue` |
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
| `inbound`, `handoff(events, tools)` | optional: the service reports through `POST /events` |

The service needs `POST /reply` with the `REPLY_TOKEN`. An inbound one also needs `POST /events {after, wait}`, which answers `{events: [{seq, id, ...}], last}`. Messages must be kept on disk, so a restart loses nothing. The owner's own chat is still WhatsApp only.

## WhatsApp

- The gateway keeps waiting messages on disk (`/data/queue.json`).
- Messages that arrived while it was away are read for 12 hours back (`WHATSAPP_CATCHUP_HOURS`). They carry a note with the time they were sent. A `yes abcde` that waited is read as plain text and approves nothing.
- A failed reconnect tries again, up to once a minute. After 5 minutes down the gateway restarts itself, unless it waits for a QR code or the phone logged it out.

## New mail

`google/fraim-mail-watch` asks Gmail what changed and writes the id of each new mail to `mail-events.jsonl`. Mail in Promotions, Social and Forums is left out.

**A new message starts nothing by itself.** The watcher only records. No agent runs and no Claude usage is spent until a trigger is switched on. The scheduled `mail-requests` automation keeps working as before.

A trigger is a deliberate choice: set `FRAIM_MAIL_AUTOMATION` to the name of an automation and run `fraim-channels listen`. It hands that automation the Thread IDs as `{{input}}`, at most once a minute. Nothing starts `listen` yet.

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
