# The API

Build your own screen, also as a separate app on another address. The API gives raw data: ids, states, times and the words as they were written. How it looks and what it says is yours.

The machine-readable contract is `GET /api/v1/schema` (OpenAPI 3 JSON). A test compares it with the real routes, so it cannot drift.

## Connect

The API is on the same address as your inbox. `fraim queue url` shows the address.

Make a token. Claude runs this for you:

```
fraim-queue token new --name myapp --scope read --origin https://app.example.com
```

The token is shown once. Only a hash is kept, in `~/.config/fraim/authority/api-tokens`. `fraim-queue token list` shows what exists. `fraim-queue token rm NAME` removes one, and open event streams of that token stop.

Send it with every request:

```
curl -H "Authorization: Bearer fq_..." http://SERVER:PORT/api/v1/items?state=open
```

Never put a token in a URL or in code that goes to a public place.

### Scopes

| Scope | Allows |
|---|---|
| `read` | Every `GET` |
| `write` | `read`, plus adding items, saying something in a conversation and sending a note to an agent |
| `decide` | `write`, plus approving, rejecting and dismissing items |

Only you can make, list or remove tokens. A run nobody watches is refused.

**A `decide` token is your own choice.** Whoever holds it can say yes in your name: approve work, switch on automations and send replies to people outside. Give it only to an app you trust, keep it off shared machines, and remove it when you stop using the app. A `decide` approval of a brain change also sends you a message, so you see it happened.

Your inbox page's own cookie also works on `/api/v1`, for pages served from your server (`/p/NAME`). A `POST` with the cookie needs the header `X-Fraim-Queue: 1`.

### From a browser on another address

Give the token the exact origin of your app (`--origin https://app.example.com`, repeat it for several). Only origins on a token get CORS headers, and a token used from another origin is refused. Cookies never get CORS, so a separate app always uses a token.

## Routes

Lists take `limit` (1 to 200, default 50) and `offset`, and answer with `total`, `limit` and `offset`.

| Route | Scope | What it does |
|---|---|---|
| `GET /api/v1/items?state=` | read | Items, most urgent first. `state`: `open`, `approved`, `rejected`, `dismissed`, or leave it out for all |
| `POST /api/v1/items` | write | Add a question for you |
| `GET /api/v1/items/qN` | read | One item |
| `POST /api/v1/items/qN/decide` | decide | `{ "verdict": "approved", "note": "..." }`. A rejection needs a `note`. `text` changes a reply draft |
| `GET /api/v1/items/qN/media/FILE` | read | A screenshot or video of an item |
| `GET /api/v1/threads` | read | Conversations, latest first, without their text |
| `GET /api/v1/threads/tN` | read | One conversation with its chat and item ids |
| `POST /api/v1/threads/tN/say` | write | `{ "text": "..." }` adds a line and tells your chief of staff |
| `GET /api/v1/agents` | read | Leads, automations and what runs now |
| `POST /api/v1/agents/NAME/messages` | write | `{ "text": "..." }` leaves a note for a lead and wakes it |
| `GET /api/v1/events` | read | Live updates, see below |
| `GET /api/v1/schema` | read | This API as OpenAPI 3 JSON |

Good to know:

- A new item always waits for you. It has no step that runs on approve, and it can never count as your yes for something else.
- Text an app writes in a conversation or to an agent is marked with the app's name. It is never treated as your own words or as a yes.
- A request body is at most 64 KB. Text you send to a conversation or an agent is at most 4000 characters.
- The `html` of a mail is what the sender wrote. Show it the way the inbox does: in a sandboxed frame.

Errors look like `{ "error": "what went wrong", "code": "not_found" }`.

| Status | Means |
|---|---|
| 400 | The request is wrong |
| 401 | No token, or an unknown one |
| 403 | The token's scope or origin does not allow this |
| 404 | No such thing |
| 409 | Already decided |
| 413 | The body is too large |

## Live updates

`GET /api/v1/events` sends server-sent events, so a screen need not poll.

| Event | Data |
|---|---|
| `ready` | `{}`: the stream is live |
| `item.changed` | `{ "id": "q7" }` |
| `thread.changed` | `{ "id": "t3" }` |

Fetch the item or conversation again when you get its id. After a reconnect, fetch your lists again; missed events are not resent.

A browser's `EventSource` cannot send an `Authorization` header, so read the stream with `fetch`:

```js
const res = await fetch(`${server}/api/v1/events`, { headers: { Authorization: `Bearer ${token}` } })
const reader = res.body.pipeThrough(new TextDecoderStream()).getReader()
let buffer = ''
for (;;) {
  const { value, done } = await reader.read()
  if (done) break
  buffer += value
  let end
  while ((end = buffer.indexOf('\n\n')) >= 0) {
    const block = buffer.slice(0, end)
    buffer = buffer.slice(end + 2)
    const event = /^event: (.*)$/m.exec(block)?.[1]
    const data = /^data: (.*)$/m.exec(block)?.[1]
    if (event && data) onEvent(event, JSON.parse(data))
  }
}
```

## Stability

`/api/v1` only grows: new routes and new fields. A change that would break a screen gets a new version next to it. The routes your inbox page uses (`/api/items`, `/api/threads` and so on) are shaped for that page and can change; build on `/api/v1`.
