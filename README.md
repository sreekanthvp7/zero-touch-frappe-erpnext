# Zero Touch Frappe & ERPNext Installer

One command turns a fresh **Ubuntu 24.04** server into a production
**ERPNext v16 + HRMS** system. All questions are asked at the start; after
that it runs to the end without touching anything.

```bash
curl -fsSL https://raw.githubusercontent.com/sreekanthvp7/zero-touch-frappe-erpnext/main/install.sh | sudo bash
```

## What it installs

| Part | Version |
|---|---|
| Frappe / ERPNext | v16 (`version-16` branch) |
| HRMS | v16 |
| MariaDB | 11.8 |
| Python | 3.14 (via uv) |
| Node.js | 24 (via nvm) + yarn |
| Redis, nginx, supervisor | from Ubuntu |
| wkhtmltopdf | 0.12.6.1 (patched Qt, for PDFs) |

It ends in **production mode**: nginx serves the site on port 80 and
supervisor keeps the workers running and restarts them after a reboot.

## The questions it asks

| Question | Default |
|---|---|
| Linux user to run Frappe as (created if missing) | `frappe` |
| Password for that user (only if it's new) | — |
| MariaDB root password | — |
| ERPNext Administrator password | — |
| Site name | `site1.local` |
| Timezone | `Asia/Kolkata` |

Passwords must be at least 8 characters and are asked twice. They are never
written into the script or the log.

### Fully unattended

Set the answers first and nothing is asked:

```bash
curl -fsSL https://raw.githubusercontent.com/sreekanthvp7/zero-touch-frappe-erpnext/main/install.sh | \
  sudo FRAPPE_USER=frappe FRAPPE_USER_PASS='…' DB_ROOT_PASS='…' ADMIN_PASS='…' \
       SITE=erp.example.com TZ_NAME=Asia/Kolkata bash
```

## Steps it runs

1. Timezone and system upgrade
2. Base packages
3. wkhtmltopdf
4. MariaDB (secured, root password set, utf8mb4)
5. uv + Python
6. nvm + Node + yarn
7. frappe-bench
8. `bench init` (takes several minutes)
9. Get ERPNext + HRMS and create the site
10. Production setup (nginx + supervisor)
11. Health checks: services running, login page, Administrator login

A full log is saved to `~/erpnext-install-<date>.log` of the Frappe user.

## Known v16 problems it fixes for you

1. `bench install-app` needs the bench's Redis running, so it is started
   temporarily first.
2. `bench setup production` can skip the supervisor link on its first run;
   the script checks and creates it.
3. supervisor can't find Node installed by nvm, so Node is linked into
   `/usr/local/bin`.

## After install

- Open `http://<server-ip>/` and log in as **Administrator**.
- **HTTPS:** point a real domain at the server, then as the Frappe user:
  `sudo -H env "PATH=$PATH" bench setup lets-encrypt <site>`
- **Firewall:** `sudo ufw allow 22,80,443/tcp && sudo ufw enable`
  (otherwise port 9000 is open to the network).

## ⚠️ Take care

- **Fresh servers only.** It upgrades the system, installs MariaDB and nginx,
  and changes their settings. Don't run it on a server that already has
  other databases or websites.
- **Ubuntu 24.04, x86_64 only.** Other versions get a warning; ARM stops.
- **Strong passwords.** The MariaDB root and Administrator passwords protect
  all your business data.
- **Back up before re-running** on a server that already has data.
- **Root during install:** the Frappe user gets temporary passwordless sudo
  while it runs; that rule is removed at the end, even if it fails. The user
  stays in the `sudo` group.
- **Runs as root from this repo:** whoever can push here controls what it
  installs. Read the script before running it.
- **If you upgrade Node later** with nvm, re-link it:
  `sudo ln -sf "$(nvm which default)" /usr/local/bin/node`
