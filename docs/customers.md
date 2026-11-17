# Running fraim for other people

The operator runs the server and Tailscale. The person only does two things: approve a Claude sign-in link, and type a WhatsApp code. They use fraim through WhatsApp and the Claude phone app.

Tell the person this first: the operator has root on their server, so the operator can read their mail, files and keys.

## How customers stay apart

- Customers are not on the operator's tailnet. Only the operators are.
- Every customer server gets `tag:fraim-customer`, not `tag:fraim`. Tailscale blocks everything that no rule allows, and no rule has `tag:fraim-customer` as a source. A customer server therefore cannot reach another customer, an operator's laptop, or anything that `fraim tailscale reach` opens for `tag:fraim`.
- Each customer has their own server, their own Claude account and their own WhatsApp number.

## Once per operator tailnet

```
fraim tailscale customers        # shows the policy change
fraim tailscale customers --yes  # applies it
```

## For each person

The person needs a Claude Pro or Max plan and a second phone number registered in WhatsApp Business.

```
fraim customer add alice --owner +31... --bot +31... --hcloud-context PROJECT --yes
```

Without `--yes` the command shows the plan and the cost. `--hcloud-context` names the Hetzner project, so a customer server can never land in the wrong project by accident.

Run the same command again after each human step. It skips what is done:

1. It creates the server, turns on backups and installs fraim, in about 10 minutes.
2. It prints a sign-in link for the person. They send back the code, and the operator runs `FRAIM_TARGET=alice fraim login --code`.
3. It prints a WhatsApp code that works for about 1 minute, so do this step while the person has the phone in their hand.

## Every day

```
fraim customer list             # health of every server
fraim customer update           # update all, or: fraim customer update alice
FRAIM_TARGET=alice fraim logs   # every other fraim command works the same way
```

The operator's own fraim, `.env` and current target stay untouched.

The records live in `~/.config/fraim/customers/` on the laptop that ran `add`. A second operator does not see them.

To delete a server: `fraim cloud destroy --name fraim-alice --yes`, then remove `~/.config/fraim/customers/alice.*`, `~/.config/fraim/alice.config` and the machine in the Tailscale admin console.
