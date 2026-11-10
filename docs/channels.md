# Channels

A channel is how the owner and fraimwork reach each other: WhatsApp today, something else tomorrow. The contract is the HTTP API of the WhatsApp gateway (`whatsapp/gateway.mjs`). A second channel is a service that serves the same routes.

## The seam

`fraim-gateway` and `fraim-notify` use `FRAIM_CHANNEL_URL` and `FRAIM_CHANNEL_TOKEN` when the URL is set. Otherwise they use `FRAIM_GATEWAY_URL` and `FRAIM_GATEWAY_TOKEN` and need the `whatsapp` module.

To point a server at another channel, put `CHANNEL_URL` and `CHANNEL_TOKEN` in its `.env` and restart the workspace. A channel URL without a token is refused, so the WhatsApp token never reaches another service.

## Routes

Every route except `GET /health` needs `Authorization: Bearer TOKEN` and answers `401 {"error": "unauthorized"}` without it. Other errors are JSON too: `{"error": "what went wrong"}`, with a 4xx status for a bad request and 503 while the channel is not connected.

| Route | Body | Answer |
|---|---|---|
| `GET /health` | | `200 {"ok": true}` when the service runs, connected or not. No token. |
| `GET /status` | | `200 {"connected": true, "me": "ID", "queued": 0, "listeners": 1}` |
| `GET /events` | | A stream of server-sent events, see below. |
| `POST /send` | `{"chat_id": "ID", "text": "hi"}` or `{"to": "ADDRESS", "text": "hi"}` | `200 {"ok": true}` |
| `POST /send-file` | `{"chat_id": "ID", "path": "fraim/report.pdf", "caption": "..."}`, or `to` instead of `chat_id` | `200 {"ok": true}` |

`connected` says whether the channel can deliver right now. `listeners` is the number of open `/events` streams. `fraim-doctor` reads both.

`POST /send` with an empty `to` and no `chat_id` means the owner: `fraim-notify` sends that when `WHATSAPP_OWNER` is empty. The WhatsApp gateway answers 400 there, because it always has an owner.

`path` in `/send-file` starts with `fraim/` or `pc/` and is relative to the shared folders. The service mounts them read-only, as `whatsapp` does in `compose.yaml`, and refuses a path that leads outside them.

## Events

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

## What a channel must do

1. Serve the routes above, on a network the workspace can reach.
2. Check the sender. Only people the owner allowed may produce `message` events; drop the rest.
3. Keep events while nobody listens, up to 100, and deliver them when a stream opens. Claude restarts, and a message may not vanish then.
4. Accept long text: split it when the service has a size limit.
5. Serve `/health` without a token, for Docker.

Ship it as a module: a service with its own compose profile and a `modules/NAME.manifest` with its health checks.

## Not generic yet

`fraim-gateway` and `fraim-notify` are the only callers that know about `FRAIM_CHANNEL_URL`. These still talk to WhatsApp directly:

- `workspace/channel/whatsapp-channel.mjs`, the listener that feeds `/events` to the Claude session and handles approvals. It reads `FRAIM_GATEWAY_URL`, and `fraim-entrypoint` only registers it with the `whatsapp` module on.
- `fraim-queue`, for approved replies to contacts (`POST /reply`, which is not part of this contract).
- `fraim whatsapp` on the laptop, and the pairing routes `/pair` and `/qr.png`, which are specific to WhatsApp.

So a second channel can receive notices and answer `fraim-gateway` today. Bringing its messages into the Claude session needs that listener made generic first.
