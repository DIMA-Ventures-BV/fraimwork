# Your own inbox

Everything in the inbox and the app can change. Tell your chief of staff what you want in your own words: "put my mail on the left", "make it light", "remove that tab", "rename this button", or "add a page with my orders". The chief changes it, and you reload the page.

## How it works

Every page is a file. fraimwork ships the defaults. Your version lives in `~/fraim/ui/NAME.html` and always wins. An update never overwrites your file.

| Page | Address | File |
|---|---|---|
| Inbox | `/` | `inbox.html` |
| Team | `/team` | `team.html` |
| Settings | `/settings` | `settings.html` |
| A page of your own | `/p/NAME` | `NAME.html` |

The whole page is yours: the words, colours, layout, buttons and the code in it.

## Commands

The chief runs these.

| Command | Does |
|---|---|
| `fraim-ui list` | Every page, and whose version is used |
| `fraim-ui own NAME` | Copy the default to your file and print the path |
| `fraim-ui new NAME` | A new page at `/p/NAME` |
| `fraim-ui check [NAME]` | Name the mistakes in your pages |
| `fraim-ui diff NAME` | Your page against the default |
| `fraim-ui reset NAME` | Back to the default; the old page goes to `.history/` |
| `fraim-ui restore NAME` | Put back the newest copy `reset` kept |

## If a page breaks

Add `?builtin=1` to the address, for example `/?builtin=1`. That always shows the default page. Then say "put it back".

## Who may change a page

Only you. The chief changes a page in your chat on WhatsApp or in the app. Goals, leads, automations and the chief's own scheduled runs are refused, so a mail or a web page cannot ask for a change.

This stops the edit tools and `fraim-ui`. It does not stop a shell command in a run nobody watches, because those run as the same Unix user. A page can show anything, including an approve button, so a page changed that way could mislead you. A separate Unix user for those runs closes this gap.

When fraimwork improves a default you copied, your page stays. `fraim-ui list` tells you, and `fraim-ui diff` shows what is different.
