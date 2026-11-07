# Deploy to Hetzner, DigitalOcean, AWS or any other provider

You say "set up fraim on Hetzner" (or DigitalOcean, or AWS). Claude runs the commands below. You only do the steps marked **you**.

## What every server needs

| | Minimum | Recommended |
| --- | --- | --- |
| OS | Ubuntu 22.04 or Debian 12 | Ubuntu 24.04 |
| Memory | 2 GB (install.sh adds 2 GB swap) | 4 GB |
| Disk | 20 GB | 30 GB or more |
| CPU | x86 or ARM | either |
| Access | SSH key login as root, or as a user with passwordless sudo | |

`install.sh` does the rest on every provider: Docker, Tailscale, the firewall (ufw), password logins off, swap on small servers.

## The three steps

1. **Create the server.** `fraim cloud create --provider hetzner|digitalocean|aws`, or create it yourself in any provider's console.
2. **Deploy.** `fraim deploy USER@IP`. It accepts `root@`, `ubuntu@`, `admin@` and any sudo user. It moves to root by itself.
3. **Log in to Claude** on the server: `fraim shell`, then `/login`.

## Hetzner Cloud

1. **You:** in https://console.hetzner.com, open a project. Use a separate project for fraim, not a production project.
2. **You:** Security > API tokens > Generate (Read & Write). In your own terminal, run `hcloud context create fraim` and paste the token there. Never paste it in the Claude chat.
3. Claude: `fraim cloud create --provider hetzner` shows the plan and the cost. After you agree: the same command with `--yes`.
4. Claude: `fraim deploy root@IP`.

Defaults: `cx23` (2 vCPU, 4 GB, x86, about EUR 5.50 per month) in `nbg1`. ARM: `--arch arm` gives `cax11` in `fsn1`. Other types: `hcloud server-type list`.

## DigitalOcean

1. **You:** install the CLI: `brew install doctl`.
2. **You:** create a token at https://cloud.digitalocean.com/account/api/tokens. In your own terminal, run `doctl auth init` and paste it there.
3. Claude: `fraim cloud create --provider digitalocean`, then `--yes` after you agree.
4. Claude: `fraim deploy root@IP`.

Defaults: `s-2vcpu-4gb` (about USD 24 per month) in `ams3`. DigitalOcean has no ARM droplets.

## AWS (EC2)

1. **You:** in your own terminal, run `aws login` (or `aws configure sso`). Pick the region you want as default.
2. Claude: `fraim cloud create --provider aws`, then `--yes` after you agree.
3. Claude: `fraim deploy root@IP`.

What `create` does on AWS:

- Imports your SSH public key as an EC2 key pair.
- Finds the current Ubuntu 24.04 image through Canonical's public SSM parameter.
- Creates a security group `fraim-<name>` in the default VPC. Tailscale mode: SSH 22 and UDP 41641. Public mode: also the workspace SSH port, mosh and Syncthing.
- Starts `t3.medium` (x86) or `t4g.medium` (`--arch arm`) with a 30 GB gp3 disk. The AWS default of 8 GB is too small.
- Requires IMDSv2 on the instance.

Two AWS facts to know:

- The public IP changes when you stop and start the instance. Tailscale mode does not care. In public mode, attach an Elastic IP.
- The security group keeps port 22 open in Tailscale mode, but ufw on the server blocks it after `install.sh`. To close it at AWS too, remove that rule after the deploy.

## Any other provider

Vultr, Linode, OVH, Scaleway, Google Cloud, Oracle, a home server: all work the same way.

1. **You** (or Claude, if the provider has a CLI): create an Ubuntu 24.04 server with your SSH public key (`~/.ssh/id_ed25519.pub`).
2. Optional: paste `deploy/cloud-init.yaml` into the "user data" or "cloud config" field. It gives root your key and installs rsync.
3. Claude: `fraim deploy USER@IP`, with the user the provider gives you (`root`, `ubuntu`, `admin`, ...).

Before it copies anything, `fraim deploy` runs `fraim cloud prepare`. That step:

1. Logs in as root, or as the provider's user and copies your key to root through sudo.
2. Removes the "Please login as ubuntu" line that cloud images put in root's keys.
3. Waits until cloud-init is done, so `install.sh` does not collide with the first apt run.
4. Installs rsync when it is missing.

## Remove a server

`fraim cloud destroy --name NAME` shows what it deletes. With `--yes` it deletes the server and its disk (and on AWS the security group). Then remove the machine in the Tailscale admin console.

`fraim cloud list` shows the servers that `fraim cloud create` made from this laptop. The records live in `~/.config/fraim/cloud/`.

## Provider tokens

Provider API tokens stay in the provider CLI's own login on your laptop (`hcloud`, `doctl`, `aws`). `fraim cloud` never reads them, and they never go to the server. See [secrets.md](secrets.md).

## Tests

- `tests/cloud-cli.sh`: usage errors, the cost gate, login checks, and a Hetzner dry run. It spends no money.
- `tests/cloud-prepare.sh`: runs `prepare` against an AWS-style Ubuntu container and a Debian container.
- `tests/vm-deploy.sh [debian-12|ubuntu-24.04]`: the real thing on a local VM (macOS, `brew install lima`). It boots a cloud image with cloud-init and a sudo user, runs `fraim deploy USER@IP`, checks 11 things on the server, and deletes the VM. It takes 15 to 25 minutes.
