#!/usr/bin/env bash
# =============================================================================
#  Zero Touch Frappe & ERPNext Installer
#  ERPNext v16 + HRMS, production setup, for Ubuntu 24.04 (x86_64)
#  https://github.com/sreekanthvp7/zero-touch-frappe-erpnext
#
#  One command on a fresh server:
#     curl -fsSL https://raw.githubusercontent.com/sreekanthvp7/zero-touch-frappe-erpnext/main/install.sh | sudo bash
#
#  Or from a downloaded copy:
#     sudo bash install.sh      # as root: can create the Linux user
#     bash install.sh           # as an existing sudo user
#
#  All answers are asked at the start. Nothing is asked after that.
#  To skip the questions, set these first:
#     FRAPPE_USER, FRAPPE_USER_PASS, DB_ROOT_PASS, ADMIN_PASS, SITE, TZ_NAME
#
#  Includes fixes for three known problems:
#   1. v16 install-app needs the bench's Redis running, so it is started
#      temporarily before install-app.
#   2. `bench setup production` may skip the supervisor link on its first
#      run, so the script checks for it and creates it if missing.
#   3. supervisor can't find node installed by nvm, so node is linked
#      into /usr/local/bin.
# =============================================================================
set -Eeuo pipefail

SELF_URL="https://raw.githubusercontent.com/sreekanthvp7/zero-touch-frappe-erpnext/main/install.sh"
FRAPPE_BRANCH="version-16"
PY_VER="3.14"
NODE_VER="24"
NVM_VER="v0.41.0"
MARIADB_VER="11.8"
WK_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb"

# ---------- helpers ----------------------------------------------------------
c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_b=$'\e[1m'; c_0=$'\e[0m'
step() { echo; echo "${c_b}==> $*${c_0}"; }
ok()   { echo "${c_g}  ✔ $*${c_0}"; }
warn() { echo "${c_y}  ⚠ $*${c_0}"; WARNINGS+=("$*"); }
die()  { echo "${c_r}  ✘ $*${c_0}" >&2; exit 1; }
WARNINGS=()
trap 'echo "${c_r}✘ Failed at line $LINENO: $BASH_COMMAND  (details: ${LOG:-no log yet})${c_0}" >&2' ERR

ask() {   # ask VAR "Question" "default"
  local __v=$1 __q=$2 __d=${3:-} __a
  [[ -n ${!__v:-} ]] && return 0
  read -rp "$__q${__d:+ [$__d]}: " __a </dev/tty
  printf -v "$__v" '%s' "${__a:-$__d}"
  [[ -n ${!__v} ]] || die "$__v cannot be empty"
}

ask_secret() {   # ask_secret VAR "Question"
  local __v=$1 __q=$2 __a __b
  [[ -n ${!__v:-} ]] && return 0
  while true; do
    read -rsp "$__q: " __a </dev/tty; echo
    if [[ ${#__a} -lt 8 ]]; then echo "  Must be at least 8 characters."; continue; fi
    read -rsp "  Confirm: " __b </dev/tty; echo
    [[ "$__a" == "$__b" ]] && break
    echo "  Passwords do not match, try again."
  done
  printf -v "$__v" '%s' "$__a"
}

sql_escape() { local s=${1//\\/\\\\}; printf '%s' "${s//\'/\'\'}"; }

# ---------- pre-flight -------------------------------------------------------
. /etc/os-release
[[ "$ID" == "ubuntu" && "$VERSION_ID" == "24.04" ]] || echo "${c_y}Warning: tested on Ubuntu 24.04 only (found $PRETTY_NAME)${c_0}"
[[ "$(uname -m)" == "x86_64" ]] || die "Only x86_64 is supported (wkhtmltopdf .deb is amd64)."

# =============================================================================
#  ROOT MODE: collect answers, create the user, then run the rest as that user
# =============================================================================
if [[ $EUID -eq 0 && "${INSTALL_STAGE:-}" != "user" ]]; then
  echo "${c_b}ERPNext v16 + HRMS installer${c_0}  (running as root)"
  ask FRAPPE_USER "Linux user to run Frappe as" "frappe"
  [[ "$FRAPPE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid username: $FRAPPE_USER"
  [[ "$FRAPPE_USER" == "root" ]] && die "Do not run Frappe as root."
  if ! id "$FRAPPE_USER" &>/dev/null; then
    ask_secret FRAPPE_USER_PASS "Password for new Linux user '$FRAPPE_USER'"
  fi
  ask_secret DB_ROOT_PASS "MariaDB root password"
  ask_secret ADMIN_PASS   "ERPNext Administrator password"
  ask SITE    "Site name" "site1.local"
  ask TZ_NAME "Timezone" "Asia/Kolkata"

  if ! id "$FRAPPE_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$FRAPPE_USER"
    printf '%s:%s\n' "$FRAPPE_USER" "$FRAPPE_USER_PASS" | chpasswd
    ok "Created user $FRAPPE_USER"
  fi
  usermod -aG sudo "$FRAPPE_USER"

  # temporary passwordless sudo for the install, always removed at the end
  TMP_SUDO=/etc/sudoers.d/erpnext-install-tmp
  echo "$FRAPPE_USER ALL=(ALL) NOPASSWD:ALL" > "$TMP_SUDO"; chmod 440 "$TMP_SUDO"
  trap 'rm -f '"$TMP_SUDO"'; echo "Removed temporary sudo rule."' EXIT

  USER_HOME=$(getent passwd "$FRAPPE_USER" | cut -d: -f6)
  # copy this script to the user (download it again when run as  curl ... | bash)
  SELF="$USER_HOME/zero-touch-install.sh"
  if [[ -f "${BASH_SOURCE[0]:-}" ]]; then cp "${BASH_SOURCE[0]}" "$SELF"
  else curl -fsSL "$SELF_URL" -o "$SELF" || die "Could not download $SELF_URL"; fi
  chown "$FRAPPE_USER:$FRAPPE_USER" "$SELF"; chmod 755 "$SELF"
  sudo -u "$FRAPPE_USER" -H env INSTALL_STAGE=user FRAPPE_USER="$FRAPPE_USER" \
       DB_ROOT_PASS="$DB_ROOT_PASS" ADMIN_PASS="$ADMIN_PASS" SITE="$SITE" TZ_NAME="$TZ_NAME" \
       bash "$SELF"
  exit $?
fi

# =============================================================================
#  USER MODE
# =============================================================================
[[ $EUID -ne 0 ]] || die "Run as root without INSTALL_STAGE, or as a normal sudo user."
FRAPPE_USER=$(id -un)
if [[ "${INSTALL_STAGE:-}" != "user" ]]; then
  echo "${c_b}ERPNext v16 + HRMS installer${c_0}  (running as user: $FRAPPE_USER)"
  ask_secret DB_ROOT_PASS "MariaDB root password"
  ask_secret ADMIN_PASS   "ERPNext Administrator password"
  ask SITE    "Site name" "site1.local"
  ask TZ_NAME "Timezone" "Asia/Kolkata"
  echo "Checking sudo access (enter YOUR Linux password if asked)..."
  sudo -v </dev/tty || die "User $FRAPPE_USER needs sudo rights."
  # keep sudo alive while the script runs
  ( while true; do sudo -n true; sleep 50; kill -0 $$ 2>/dev/null || exit; done ) 2>/dev/null &
fi

LOG="$HOME/erpnext-install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
echo "Logging to $LOG"
export DEBIAN_FRONTEND=noninteractive
APT="sudo -E apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
BENCH_DIR="$HOME/frappe-bench"

# ---------- 1. timezone + upgrade --------------------------------------------
step "1/11 Timezone and system upgrade"
sudo timedatectl set-timezone "$TZ_NAME"
ok "Timezone: $(timedatectl show -p Timezone --value)"
$APT update >>"$LOG" 2>&1 && $APT upgrade >>"$LOG" 2>&1
ok "System upgraded"

# ---------- 2. packages ------------------------------------------------------
step "2/11 Base packages"
$APT install git curl python3-dev python3-pip python3-setuptools python3-venv \
  software-properties-common xvfb libfontconfig libmysqlclient-dev pkg-config redis-server >>"$LOG" 2>&1
redis-cli ping | grep -q PONG && ok "Packages installed, Redis running"

# ---------- 3. wkhtmltopdf ---------------------------------------------------
step "3/11 wkhtmltopdf 0.12.6.1"
if wkhtmltopdf --version 2>/dev/null | grep -q '0.12.6.1 (with patched qt)'; then
  ok "Already installed"
else
  TMPD=$(mktemp -d); curl -fsSL -o "$TMPD/wk.deb" "$WK_URL"
  $APT install "$TMPD/wk.deb" >>"$LOG" 2>&1; rm -rf "$TMPD"
  wkhtmltopdf --version | grep -q 'patched qt' && ok "$(wkhtmltopdf --version)"
fi

# ---------- 4. MariaDB -------------------------------------------------------
step "4/11 MariaDB $MARIADB_VER"
if mariadb --version 2>/dev/null | grep -q "from $MARIADB_VER"; then
  ok "Already installed"
else
  TMPD=$(mktemp -d)
  curl -fsSL -o "$TMPD/mariadb_repo_setup" https://r.mariadb.com/downloads/mariadb_repo_setup
  sudo bash "$TMPD/mariadb_repo_setup" --mariadb-server-version="mariadb-$MARIADB_VER" --skip-maxscale >>"$LOG" 2>&1
  rm -rf "$TMPD"
  $APT update >>"$LOG" 2>&1 && $APT install mariadb-server mariadb-client >>"$LOG" 2>&1
fi
ok "$(mariadb --version | awk '{print $3,$4,$5}')"

ESC_PASS=$(sql_escape "$DB_ROOT_PASS")
sudo mariadb <<SQL
DELETE FROM mysql.global_priv WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\\\_%';
ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('$ESC_PASS');
FLUSH PRIVILEGES;
SQL
sudo tee /etc/mysql/mariadb.conf.d/99-frappe.cnf >>"$LOG" 2>&1 <<'EOF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF
sudo systemctl restart mariadb
MYSQL_PWD="$DB_ROOT_PASS" mariadb -uroot -h127.0.0.1 -e 'SELECT 1' >>"$LOG" 2>&1 || die "MariaDB root password login failed"
[[ "$(sudo mariadb -Nse 'SELECT @@collation_server')" == "utf8mb4_unicode_ci" ]] || die "utf8mb4 config not applied"
ok "Secured, root password set, utf8mb4 enabled"

# ---------- 5. uv + Python ---------------------------------------------------
step "5/11 uv + Python $PY_VER"
export PATH="$HOME/.local/bin:$PATH"
command -v uv >>"$LOG" 2>&1 || curl -LsSf https://astral.sh/uv/install.sh | sh >>"$LOG" 2>&1
uv python install "$PY_VER" --default >>"$LOG" 2>&1
ok "$(python$PY_VER --version), $(uv --version)"

# ---------- 6. nvm + Node + yarn ---------------------------------------------
step "6/11 nvm + Node $NODE_VER + yarn"
export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] || curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VER/install.sh" | PROFILE="$HOME/.bashrc" bash >>"$LOG" 2>&1
set +u; . "$NVM_DIR/nvm.sh"
nvm install "$NODE_VER" >>"$LOG" 2>&1; nvm alias default "$NODE_VER" >>"$LOG" 2>&1; nvm use default >>"$LOG" 2>&1
NODE_BIN=$(nvm which default); set -u
command -v yarn >>"$LOG" 2>&1 || npm install -g yarn >>"$LOG" 2>&1
sudo ln -sf "$NODE_BIN" /usr/local/bin/node    # FIX 3: supervisor needs node on system PATH
ok "node $(node -v), yarn $(yarn -v), linked into /usr/local/bin/node"

# ---------- 7. bench ---------------------------------------------------------
step "7/11 frappe-bench"
command -v bench >>"$LOG" 2>&1 || uv tool install frappe-bench >>"$LOG" 2>&1
ok "bench $(bench --version)"

# ---------- 8. bench init ----------------------------------------------------
step "8/11 bench init ($FRAPPE_BRANCH) - takes several minutes"
if [[ -d "$BENCH_DIR/apps/frappe" ]]; then
  ok "Bench already exists, skipping"
else
  cd "$HOME"
  bench init --frappe-branch "$FRAPPE_BRANCH" --python "python$PY_VER" frappe-bench >>"$LOG" 2>&1
fi
chmod -R o+rx "$HOME"
cd "$BENCH_DIR"
ok "Bench ready at $BENCH_DIR ($(env/bin/python --version))"

# ---------- 9. apps + site ---------------------------------------------------
step "9/11 Get apps and create site $SITE"
for app in erpnext hrms; do
  [[ -d "apps/$app" ]] || bench get-app --branch "$FRAPPE_BRANCH" "$app" >>"$LOG" 2>&1
  ok "Fetched $app"
done

# FIX 1: install-app needs the bench Redis running
STARTED_REDIS=()
for p in queue:11000 cache:13000; do
  name=${p%%:*}; port=${p##*:}
  if ! redis-cli -p "$port" ping &>/dev/null; then
    redis-server "config/redis_$name.conf" --daemonize yes >>"$LOG" 2>&1; STARTED_REDIS+=("$port")
  fi
done
sleep 2

if [[ -d "sites/$SITE" ]]; then
  ok "Site exists, skipping new-site"
else
  bench new-site "$SITE" --db-root-password "$DB_ROOT_PASS" --admin-password "$ADMIN_PASS" >>"$LOG" 2>&1
  ok "Site created"
fi
for app in erpnext hrms; do
  if bench --site "$SITE" list-apps 2>/dev/null | grep -qw "^$app"; then
    ok "$app already installed"
  else
    bench --site "$SITE" install-app "$app" >>"$LOG" 2>&1
    ok "Installed $app"
  fi
done
bench --site "$SITE" enable-scheduler >>"$LOG" 2>&1
bench --site "$SITE" set-maintenance-mode off >>"$LOG" 2>&1
bench use "$SITE" >>"$LOG" 2>&1
ok "Scheduler on, maintenance off, default site = $SITE"

for port in "${STARTED_REDIS[@]}"; do redis-cli -p "$port" shutdown nosave &>/dev/null || true; done

# ---------- 10. production ---------------------------------------------------
step "10/11 Production setup (nginx + supervisor)"
$APT install ansible >>"$LOG" 2>&1
sudo env "PATH=$PATH" bench setup production "$FRAPPE_USER" --yes >>"$LOG" 2>&1
# FIX 2: first run may skip the supervisor link
if [[ ! -L /etc/supervisor/conf.d/frappe-bench.conf ]]; then
  echo "  supervisor link missing, running setup production again..."
  sudo env "PATH=$PATH" bench setup production "$FRAPPE_USER" --yes >>"$LOG" 2>&1
fi
[[ -L /etc/supervisor/conf.d/frappe-bench.conf ]] || die "Supervisor config still not linked"
bench setup nginx --yes >>"$LOG" 2>&1
sudo nginx -t 2>/dev/null && sudo systemctl reload nginx
sudo systemctl restart supervisor
ok "nginx reloaded, supervisor restarted"

# ---------- 11. verify -------------------------------------------------------
step "11/11 Verification"
echo "  Waiting for services to start..."
for i in {1..12}; do
  sleep 5
  NOT_RUNNING=$(sudo supervisorctl status | grep -vc RUNNING || true)
  [[ "$NOT_RUNNING" -eq 0 ]] && break
done
sudo supervisorctl status || true
[[ "$NOT_RUNNING" -eq 0 ]] && ok "All supervisor services RUNNING" || warn "$NOT_RUNNING supervisor service(s) not RUNNING - check $BENCH_DIR/logs/"

HTTP=$(curl -s -o /dev/null -w '%{http_code}' http://localhost/login || true)
[[ "$HTTP" == "200" ]] && ok "http://localhost/login -> 200" || warn "http://localhost/login returned $HTTP"
LOGIN=$(curl -s -X POST http://localhost/api/method/login -H 'Content-Type: application/json' \
        --data-binary @- <<<"{\"usr\":\"Administrator\",\"pwd\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$ADMIN_PASS")}" || true)
grep -q 'Logged In' <<<"$LOGIN" && ok "Administrator login works" || warn "Administrator login test failed"

sudo ufw status 2>/dev/null | grep -q 'Status: active' || \
  warn "Firewall (ufw) is off. Port 9000 (socketio) is open to the network. Suggested: sudo ufw allow 22,80,443/tcp && sudo ufw enable"
warn "No HTTPS yet. With a real domain pointing here: sudo -H env \"PATH=\$PATH\" bench setup lets-encrypt <site>"
warn "If you upgrade Node with nvm, re-run: sudo ln -sf \"\$(nvm which default)\" /usr/local/bin/node"

# ---------- summary ----------------------------------------------------------
echo
echo "${c_b}================ SUMMARY ================${c_0}"
bench version
echo "bench      $(bench --version)"
echo "Python     $(env/bin/python --version | awk '{print $2}')"
echo "Node       $(node -v)"
echo "MariaDB    $(mariadb --version | awk '{print $5}' | tr -d ,)"
echo "Redis      $(redis-server --version | awk '{print $3}' | cut -d= -f2)"
echo "nginx      $(nginx -v 2>&1 | cut -d/ -f2)"
echo "wkhtml     $(wkhtmltopdf --version | awk '{print $2}')"
echo
echo "Site:  http://$(hostname -I | awk '{print $1}')/   (user: Administrator)"
echo "Log:   $LOG"
if ((${#WARNINGS[@]})); then
  echo; echo "${c_y}Warnings:${c_0}"; printf '  - %s\n' "${WARNINGS[@]}"
fi
echo "${c_g}Done.${c_0}"
