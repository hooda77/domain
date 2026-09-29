#!/usr/bin/env bash
# ============================================================================
#  install.sh — Meeting Platform installer (LiveKit + PHP + MySQL + nginx)
#  • Reusable on any Ubuntu 22.04/24.04 server (requires root).
#  • Runs from inside the project directory, or downloads the bundle (.zip)
#    from BUNDLE_URL.
#  • Idempotent: safe to re-run — never loses data or secrets.
#  • Self-healing: verifies every service; whatever is down is restarted,
#    then reinstalled if needed.
#
#  Usage:
#    sudo bash install.sh                          # interactive (prompts for domain…)
#    sudo APP_DOMAIN=meet.site.com \
#         LIVEKIT_DOMAIN=lk.site.com \
#         ADMIN_EMAIL=admin@site.com \
#         ADMIN_PASSWORD=Str0ng! \
#         MEET_NONINTERACTIVE=1 bash install.sh    # silent
#    curl -fsSL <url>/install.sh | sudo BUNDLE_URL=<url .zip> bash
# ============================================================================
set -Eeuo pipefail

# ---- Pinned versions ----
PHP_VER="${PHP_VER:-8.2}"
LIVEKIT_VERSION="${LIVEKIT_VERSION:-1.13.7}"

# ---- Default bundle source (used when run via curl|bash) ----
# When run from inside the project directory, local files are used and this
# URL is ignored.
BUNDLE_URL="${BUNDLE_URL:-https://github.com/hooda77/domain/raw/refs/heads/main/meet-platform.zip}"

# ---- Paths ----
APP_DIR="/var/www/meet"
REC_DIR="/var/lib/meet/recordings"
ENV_FILE="$APP_DIR/.env"
CRED_FILE="/root/meet-credentials.txt"
LOG_FILE="/var/log/meet-install.log"

# ---- Colors ----
if [ -t 1 ]; then C0='\033[0m'; C1='\033[1;36m'; CG='\033[1;32m'; CY='\033[1;33m'; CR='\033[1;31m'; CD='\033[2m'; CB='\033[1m'; else C0='' C1='' CG='' CY='' CR='' CD='' CB=''; fi

export DEBIAN_FRONTEND=noninteractive
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
: >"$LOG_FILE" 2>/dev/null || true

# Keep the terminal on fd 3, then send all command output (apt/composer…) to the
# log only, so what the user sees on screen stays clean and professional.
exec 3>&1
exec >>"$LOG_FILE" 2>&1

_ts(){ date '+%H:%M:%S'; }
say(){ printf "$@" >&3; }                                  # clean line on screen
log(){ printf '[%s] %s\n' "$(_ts)" "$*"; }                 # log file only
ok(){  log "OK: $*"; }
warn(){ log "WARN: $*"; }
err(){ log "ERR: $*"; }
die(){ log "FATAL: $*"; say "\r  ${CR}✗${C0} %s\n" "$*"; say "  ${CD}See the log: %s${C0}\n" "$LOG_FILE"; exit 1; }

trap 'log "Failed at line $LINENO (command: $BASH_COMMAND)"' ERR

# Spinner shown while a step runs (hides its verbose output)
_spin(){
  local pid="$1" msg="$2" f='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i+1) % ${#f} ))
    say "\r  ${C1}%s${C0} %s" "${f:$i:1}" "$msg"
    sleep 0.1
  done
}

# ============================================================================
#  0) Preflight checks
# ============================================================================
[ "$(id -u)" = "0" ] || die "Run this script as root (use sudo)."
if ! command -v apt-get >/dev/null 2>&1; then die "This installer targets Ubuntu/Debian only (apt-get not found)."; fi
. /etc/os-release 2>/dev/null || true
log "System: ${PRETTY_NAME:-unknown}"

# Run mode: update (a previous .env exists) or a fresh install
if [ -f "$ENV_FILE" ]; then MODE="update"; MODE_LABEL="Update"; else MODE="fresh"; MODE_LABEL="Fresh install"; fi

# Clean banner
say "\n"
say "  ${CB}${C1}Meeting Platform${C0}  ${CD}·  Professional installer${C0}\n"
say "  ${CD}────────────────────────────────────────${C0}\n"
say "  Mode: ${CB}%s${C0}   ${CD}System: %s${C0}\n\n" "$MODE_LABEL" "${PRETTY_NAME:-Linux}"

# ============================================================================
#  1) Read configuration (from env or interactively)
# ============================================================================
NONINTERACTIVE="${MEET_NONINTERACTIVE:-0}"
# When run via "curl | bash", stdin is the pipe rather than the terminal,
# so we read from /dev/tty directly when available (otherwise use the default).
ask(){ # ask VAR "question" "default"
  local __var="$1" __q="$2" __def="${3:-}" __ans=""
  local __cur="${!__var:-}"
  if [ -n "$__cur" ]; then eval "$__var=\$__cur"; return; fi
  if [ "$NONINTERACTIVE" = "1" ] || [ ! -r /dev/tty ]; then eval "$__var=\$__def"; return; fi
  printf "  ${C1}?${C0} %s ${CD}[%s]${C0} " "$__q" "$__def" >/dev/tty
  read -r __ans </dev/tty || true
  eval "$__var=\${__ans:-\$__def}"
}

# Public IP (auto-detect)
detect_ip(){ curl -fsS4 https://api.ipify.org 2>/dev/null || curl -fsS4 https://ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}'; }
PUBLIC_IP="${PUBLIC_IP:-$(detect_ip)}"

# If a previous .env exists, load its values (preserving secrets and domain)
if [ "$MODE" = "update" ]; then
  set -a; . "$ENV_FILE"; set +a
  say "  ${CG}✓${C0} Existing configuration found — secrets and domain will be reused.\n\n"
fi

ask APP_DOMAIN     "Site domain"                        "${APP_DOMAIN:-meet.example.com}"
ask LIVEKIT_DOMAIN "LiveKit domain"                     "${LIVEKIT_DOMAIN:-livekit.${APP_DOMAIN}}"
ask ADMIN_EMAIL    "Admin email"                        "${ADMIN_EMAIL:-admin@${APP_DOMAIN}}"
ask ADMIN_PASSWORD "Admin password"                     "${ADMIN_PASSWORD:-$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-14)}"
ask PUBLIC_IP      "Server public IP"                   "${PUBLIC_IP:-127.0.0.1}"
ask ENABLE_TLS     "Automatic TLS certificate (Let's Encrypt)? y/n" "${ENABLE_TLS:-y}"

say "\n"
log "Config: APP=$APP_DOMAIN  LIVEKIT=$LIVEKIT_DOMAIN  IP=$PUBLIC_IP  TLS=$ENABLE_TLS  MODE=$MODE"

# ============================================================================
#  2) Locate project files (local directory or download the bundle)
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "$PWD")"
find_src(){ # look for a directory that contains backend/ and public/
  for d in "$SCRIPT_DIR" "$SCRIPT_DIR/.." "$PWD"; do
    if [ -d "$d/backend" ] && [ -d "$d/public" ]; then (cd "$d" && pwd); return 0; fi
  done
  return 1
}
if SRC_DIR="$(find_src)"; then
  ok "Local file source: $SRC_DIR"
elif [ -n "${BUNDLE_URL:-}" ]; then
  log "Downloading bundle from: $BUNDLE_URL"
  TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
  curl -fL --retry 3 -o "$TMPD/bundle.zip" "$BUNDLE_URL" || die "Failed to download the bundle from BUNDLE_URL"
  mkdir -p "$TMPD/x"
  # Extraction: use unzip if present, otherwise install it, otherwise fall back to python3
  if ! command -v unzip >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y unzip >/dev/null 2>&1 || true
  fi
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$TMPD/bundle.zip" -d "$TMPD/x" || die "Failed to extract the bundle (unzip)"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$TMPD/bundle.zip" "$TMPD/x" || die "Failed to extract the bundle (python3)"
  else
    die "Neither unzip nor python3 is available to extract the bundle."
  fi
  # Find the project root inside the extracted files (it may be in a subdirectory)
  ROOT="$(find "$TMPD/x" -maxdepth 3 -type d -name backend -printf '%h\n' 2>/dev/null | head -1)"
  [ -n "$ROOT" ] && [ -d "$ROOT/public" ] || die "Could not find backend/ and public/ inside the bundle"
  SRC_DIR="$ROOT"; ok "Bundle extracted: $SRC_DIR"
else
  die "No local project files and no BUNDLE_URL. Place install.sh next to backend/ and public/, or pass BUNDLE_URL=<url .zip>."
fi

# ============================================================================
#  Generic retry helper
# ============================================================================
retry(){ # retry <times> <description> <command...>
  local n="$1" desc="$2"; shift 2
  local i=1
  while [ "$i" -le "$n" ]; do
    if "$@"; then return 0; fi
    warn "\"$desc\" failed (attempt $i/$n) — retrying in 3s…"; sleep 3; i=$((i+1))
  done
  return 1
}

# ============================================================================
#  Install steps (each one is idempotent)
# ============================================================================
gen(){ openssl rand -hex "${1:-24}"; }

step_base(){
  systemctl stop docker 2>/dev/null || true
  apt-get remove -y docker docker-engine docker.io containerd runc docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null 2>&1 || true
  apt-get update -y
  apt-get install -y curl wget gnupg lsb-release ca-certificates software-properties-common \
    unzip git jq openssl gettext-base ufw
}

step_env(){
  mkdir -p "$APP_DIR" "$REC_DIR"
  JWT_SECRET="${JWT_SECRET:-$(gen 32)}"
  DB_PASSWORD="${DB_PASSWORD:-$(gen 20)}"
  DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-$(gen 20)}"
  REDIS_PASSWORD="${REDIS_PASSWORD:-$(gen 20)}"
  LIVEKIT_API_KEY="${LIVEKIT_API_KEY:-APt$(gen 6)}"
  LIVEKIT_API_SECRET="${LIVEKIT_API_SECRET:-$(gen 32)}"
  TURN_SECRET="${TURN_SECRET:-$(gen 24)}"
  cat > "$ENV_FILE" <<ENV
APP_DOMAIN=$APP_DOMAIN
LIVEKIT_DOMAIN=$LIVEKIT_DOMAIN
ADMIN_EMAIL=$ADMIN_EMAIL
APP_URL=https://$APP_DOMAIN
APP_ENV=production
JWT_SECRET=$JWT_SECRET
JWT_TTL=604800
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=meet
DB_USER=meet
DB_PASSWORD=$DB_PASSWORD
DB_ROOT_PASSWORD=$DB_ROOT_PASSWORD
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASSWORD=$REDIS_PASSWORD
LIVEKIT_URL=wss://$LIVEKIT_DOMAIN
LIVEKIT_HTTP_URL=http://127.0.0.1:7880
LIVEKIT_API_KEY=$LIVEKIT_API_KEY
LIVEKIT_API_SECRET=$LIVEKIT_API_SECRET
RECORDINGS_DIR=$REC_DIR
PUBLIC_IP=$PUBLIC_IP
TURN_SECRET=$TURN_SECRET
ENV
  chmod 600 "$ENV_FILE"
  set -a; . "$ENV_FILE"; set +a
}

step_mysql(){
  apt-get install -y mysql-server
  systemctl enable --now mysql
  mysql --protocol=socket -uroot <<SQL
CREATE DATABASE IF NOT EXISTS meet CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'meet'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD';
CREATE USER IF NOT EXISTS 'meet'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
ALTER USER 'meet'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD';
ALTER USER 'meet'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON meet.* TO 'meet'@'127.0.0.1';
GRANT ALL PRIVILEGES ON meet.* TO 'meet'@'localhost';
FLUSH PRIVILEGES;
SQL
}

step_redis(){
  apt-get install -y redis-server
  sed -i "s/^# *requirepass .*/requirepass $REDIS_PASSWORD/; s/^requirepass .*/requirepass $REDIS_PASSWORD/" /etc/redis/redis.conf
  grep -q "^requirepass " /etc/redis/redis.conf || echo "requirepass $REDIS_PASSWORD" >> /etc/redis/redis.conf
  sed -i "s/^appendonly .*/appendonly yes/" /etc/redis/redis.conf
  grep -q "^appendonly yes" /etc/redis/redis.conf || echo "appendonly yes" >> /etc/redis/redis.conf
  systemctl enable redis-server
  systemctl restart redis-server
}

step_php(){
  add-apt-repository -y ppa:ondrej/php
  apt-get update -y
  apt-get install -y php${PHP_VER}-fpm php${PHP_VER}-mysql php${PHP_VER}-mbstring \
    php${PHP_VER}-bcmath php${PHP_VER}-curl php${PHP_VER}-xml php${PHP_VER}-zip php${PHP_VER}-gd \
    php${PHP_VER}-redis php${PHP_VER}-opcache
  # Enable OPcache for better performance (applied to FPM + CLI)
  local ini_dir="/etc/php/${PHP_VER}"
  for sapi in fpm cli; do
    local conf="${ini_dir}/${sapi}/conf.d/99-meet-opcache.ini"
    [ -d "${ini_dir}/${sapi}/conf.d" ] || continue
    cat > "$conf" <<'OPC'
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=192
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.validate_timestamps=1
opcache.revalidate_freq=2
opcache.jit=tracing
opcache.jit_buffer_size=64M
OPC
  done
  systemctl enable --now php${PHP_VER}-fpm
  if ! command -v composer >/dev/null 2>&1; then
    php -r "copy('https://getcomposer.org/installer','/tmp/composer-setup.php');"
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi
}

step_deploy(){
  mkdir -p "$APP_DIR"
  cp -a "$SRC_DIR/backend" "$APP_DIR/"
  cp -a "$SRC_DIR/public"  "$APP_DIR/"
  cp -a "$SRC_DIR/db"      "$APP_DIR/"
  [ -d "$SRC_DIR/scripts" ] && cp -a "$SRC_DIR/scripts" "$APP_DIR/" || true
  [ -d "$SRC_DIR/config" ]  && cp -a "$SRC_DIR/config"  "$APP_DIR/" || true
  cp -a "$SRC_DIR/composer.json" "$APP_DIR/"
  [ -f "$SRC_DIR/composer.lock" ] && cp -a "$SRC_DIR/composer.lock" "$APP_DIR/" || true
  ( cd "$APP_DIR" && COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction )
  chown -R www-data:www-data "$APP_DIR" "$REC_DIR"
}

step_db(){
  mysql -uroot meet < "$APP_DIR/db/schema.sql"
  # Apply every migration file present (in order)
  if [ -d "$APP_DIR/db/migrations" ]; then
    for m in $(ls -1 "$APP_DIR/db/migrations"/*.sql 2>/dev/null | sort); do
      mysql -uroot meet < "$m" || warn "Migration skipped (may already be applied): $(basename "$m")"
    done
  fi
  local hash
  hash="$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$ADMIN_PASSWORD")"
  mysql -uroot meet <<SQL
INSERT INTO users (email,password_hash,name,role)
VALUES ('$ADMIN_EMAIL','$hash','Admin','admin')
ON DUPLICATE KEY UPDATE role='admin';
INSERT INTO nodes (name,host,ssh_user,ssh_port,region,is_main,status,last_seen)
VALUES ('Primary server','$PUBLIC_IP','root',22,'main',1,'online',NOW())
ON DUPLICATE KEY UPDATE is_main=1,status='online',last_seen=NOW();
SQL
}

step_livekit(){
  if [ ! -x /usr/local/bin/livekit-server ] || ! livekit-server --version 2>/dev/null | grep -q "$LIVEKIT_VERSION"; then
    local tb="livekit_${LIVEKIT_VERSION}_linux_amd64.tar.gz"
    curl -fsSL --retry 3 -o "/tmp/$tb" \
      "https://github.com/livekit/livekit/releases/download/v${LIVEKIT_VERSION}/${tb}"
    tar -xzf "/tmp/$tb" -C /tmp
    install -m 0755 /tmp/livekit-server /usr/local/bin/livekit-server
    rm -f "/tmp/$tb"
  fi
  mkdir -p /etc/livekit
  envsubst < "$SRC_DIR/config/livekit.yaml.tmpl" > /etc/livekit/livekit.yaml
  cat > /etc/systemd/system/livekit.service <<UNIT
[Unit]
Description=LiveKit Server
After=network.target redis-server.service
Wants=redis-server.service
[Service]
ExecStart=/usr/local/bin/livekit-server --config /etc/livekit/livekit.yaml
Restart=always
RestartSec=2
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable livekit
  systemctl restart livekit
}

step_coturn(){
  apt-get install -y coturn
  sed -i 's/^#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn 2>/dev/null || true
  grep -q '^TURNSERVER_ENABLED=1' /etc/default/coturn 2>/dev/null || echo 'TURNSERVER_ENABLED=1' >> /etc/default/coturn
  envsubst < "$SRC_DIR/config/turnserver.conf.tmpl" > /etc/turnserver.conf
  systemctl enable coturn
  systemctl restart coturn || true
}

SS=/etc/ssl/meet
step_nginx(){
  apt-get install -y nginx certbot python3-certbot-nginx
  mkdir -p "$SS" /var/www/certbot
  if [ ! -f "$SS/fullchain.pem" ]; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -keyout "$SS/privkey.pem" -out "$SS/fullchain.pem" \
      -subj "/CN=$APP_DOMAIN" >/dev/null 2>&1
  fi
  cat > /etc/nginx/sites-available/meet.conf <<NGINX
server {
    listen 80;
    server_name $APP_DOMAIN $LIVEKIT_DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $APP_DOMAIN;
    ssl_certificate     $SS/fullchain.pem;
    ssl_certificate_key $SS/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    root /var/www/meet/public;
    index index.html;
    client_max_body_size 20m;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    gzip on;
    gzip_vary on;
    gzip_comp_level 6;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_types text/plain text/css application/javascript application/json image/svg+xml application/manifest+json font/ttf font/otf;

    # Shared assets carrying ?v= : long-lived immutable cache
    location ^~ /assets/ {
        access_log off;
        add_header Cache-Control "public, max-age=31536000, immutable" always;
        try_files \$uri =404;
    }
    location ~* \.(?:css|js|svg|woff2|woff|ttf|otf|eot|png|jpg|jpeg|gif|webp|ico)\$ {
        access_log off;
        add_header Cache-Control "public, max-age=31536000, immutable" always;
        try_files \$uri =404;
    }
    # HTML pages: never cached (the ?v= on assets busts the cache)
    location ~* \.html\$ {
        add_header Cache-Control "no-cache" always;
        try_files \$uri =404;
    }

    location / { try_files \$uri \$uri/ \$uri.html =404; }
    location /api/ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME /var/www/meet/backend/api/index.php;
        fastcgi_param REQUEST_URI \$request_uri;
        fastcgi_read_timeout 120s;
    }
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $LIVEKIT_DOMAIN;
    ssl_certificate     $SS/fullchain.pem;
    ssl_certificate_key $SS/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / {
        proxy_pass http://127.0.0.1:7880;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}
NGINX
  ln -sf /etc/nginx/sites-available/meet.conf /etc/nginx/sites-enabled/meet.conf
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable nginx
  systemctl restart nginx
}

step_tls(){
  [ "${ENABLE_TLS,,}" = "y" ] || { warn "TLS skipped (ENABLE_TLS=$ENABLE_TLS) — nginx keeps the self-signed cert."; return 0; }
  local LE=""
  if certbot certonly --webroot -w /var/www/certbot -d "$APP_DOMAIN" -d "$LIVEKIT_DOMAIN" \
       --non-interactive --agree-tos -m "$ADMIN_EMAIL" 2>/tmp/cb.log; then
    LE="/etc/letsencrypt/live/$APP_DOMAIN"
  elif certbot certonly --webroot -w /var/www/certbot -d "$LIVEKIT_DOMAIN" \
       --non-interactive --agree-tos -m "$ADMIN_EMAIL" 2>>/tmp/cb.log; then
    LE="/etc/letsencrypt/live/$LIVEKIT_DOMAIN"
  else
    warn "Could not issue a Let's Encrypt certificate (check DNS) — keeping the self-signed cert. See /tmp/cb.log"; return 0
  fi
  if [ -n "$LE" ] && [ -f "$LE/fullchain.pem" ]; then
    sed -i "s#$SS/fullchain.pem#$LE/fullchain.pem#g; s#$SS/privkey.pem#$LE/privkey.pem#g" \
      /etc/nginx/sites-available/meet.conf
    nginx -t && systemctl reload nginx && ok "TLS enabled via Let's Encrypt"
  fi
}

step_firewall(){
  ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp
  ufw allow 7881/tcp; ufw allow 50000:50200/udp
  ufw allow 3478/tcp; ufw allow 3478/udp; ufw allow 5349/tcp
  ufw allow 49152:49252/udp
  ufw --force enable
}

step_cleanup_timer(){
  # Cleanup timer: archive ended meetings to history, delete the room row after
  # one hour, prune history after 30 days.
  [ -f "$SRC_DIR/scripts/cleanup.php" ] || { warn "cleanup.php not found — skipping the timer."; return 0; }
  cp -a "$SRC_DIR/scripts/cleanup.php" "$APP_DIR/scripts/" 2>/dev/null || { mkdir -p "$APP_DIR/scripts"; cp -a "$SRC_DIR/scripts/cleanup.php" "$APP_DIR/scripts/"; }
  chown -R www-data:www-data "$APP_DIR/scripts"
  cat > /etc/systemd/system/meet-cleanup.service <<UNIT
[Unit]
Description=Meet cleanup (archive ended rooms to history, delete room row after 1h, prune history after 30d)
After=network.target mysql.service
[Service]
Type=oneshot
ExecStart=/usr/bin/php $APP_DIR/scripts/cleanup.php
User=www-data
Group=www-data
UNIT
  cat > /etc/systemd/system/meet-cleanup.timer <<UNIT
[Unit]
Description=Run meet cleanup hourly
[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
Persistent=true
[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now meet-cleanup.timer
}

# ============================================================================
#  Run the steps in order (with retries)
# ============================================================================
declare -i N=0
TOTAL=13
run(){ N+=1; local title="$1" fn="$2"
  log "=== Step $N/$TOTAL: $title ==="
  ( retry 2 "$title" "$fn" ) &
  local pid=$!
  _spin "$pid" "$(printf '%s' "$title")"
  if wait "$pid"; then
    say "\r  ${CG}✓${C0} %s\033[K\n" "$title"; ok "$title"
  else
    say "\r  ${CR}✗${C0} %s\033[K\n" "$title"; die "Failed permanently: $title"
  fi
}

say "  ${CD}Installing — only a summary of each step is shown (full log: %s)${C0}\n\n" "$LOG_FILE"

run "Base packages + remove Docker"      step_base
run "Generate/load secrets (.env)"       step_env
run "MySQL"                              step_mysql
run "Redis"                             step_redis
run "PHP ${PHP_VER}-FPM + Composer"      step_php
run "Deploy application files"           step_deploy
run "Schema + migrations + admin"        step_db
run "LiveKit ${LIVEKIT_VERSION}"         step_livekit
run "coturn (TURN/STUN)"                 step_coturn
run "nginx"                             step_nginx
run "TLS certificate"                    step_tls
run "Firewall (ufw)"                     step_firewall
run "Periodic cleanup timer"             step_cleanup_timer

# ============================================================================
#  Final verification + self-healing
# ============================================================================
declare -A HEAL=(
  [mysql]=step_mysql [redis-server]=step_redis [php${PHP_VER}-fpm]=step_php
  [livekit]=step_livekit [coturn]=step_coturn [nginx]=step_nginx
)
SERVICES="mysql redis-server php${PHP_VER}-fpm livekit coturn nginx"

log "Final verification and self-healing"
say "\n  ${CD}────────────────────────────────────────${C0}\n"
( FAILED=""
for s in $SERVICES; do
  for attempt in 1 2 3; do
    if systemctl is-active --quiet "$s"; then break; fi
    if [ "$attempt" = 1 ]; then warn "$s is down — attempting restart"; systemctl restart "$s" 2>/dev/null || true; sleep 2; continue; fi
    warn "$s still down — reinstalling (${HEAL[$s]:-none})"
    fn="${HEAL[$s]:-}"; [ -n "$fn" ] && "$fn" 2>/dev/null || true; sleep 2
  done
done ) &
_spin "$!" "Checking services and self-healing"
wait "$!" 2>/dev/null || true

FAILED=""
for s in $SERVICES; do
  if systemctl is-active --quiet "$s"; then ok "service $s is running"; else err "service $s is down"; FAILED="$FAILED $s"; fi
done
say "\r  ${CG}✓${C0} Service check\033[K\n"

# Functional checks
sleep 2
LK="$(curl -sS http://127.0.0.1:7880/ -o /dev/null -w '%{http_code}' 2>/dev/null || echo 000)"
[ "$LK" != 000 ] && ok "LiveKit HTTP responds ($LK)" || { err "LiveKit is not responding"; FAILED="$FAILED livekit-http"; }
API="$(curl -sS -k https://127.0.0.1/api/auth/me -H "Host: $APP_DOMAIN" -o /dev/null -w '%{http_code}' 2>/dev/null || echo 000)"
if [ "$API" = 401 ] || [ "$API" = 200 ]; then ok "API responds ($API)"; else err "API is not responding ($API)"; FAILED="$FAILED api"; fi

# ============================================================================
#  Save credentials + final report
# ============================================================================
set -a; . "$ENV_FILE"; set +a
cat > "$CRED_FILE" <<CRED
Meeting Platform — installation credentials ($(date))
================================================
Site:          https://$APP_DOMAIN
LiveKit:       wss://$LIVEKIT_DOMAIN
Public IP:     $PUBLIC_IP
------------------------------------------------
Admin (email): $ADMIN_EMAIL
Admin (pass):  $ADMIN_PASSWORD    <- change it after first login
------------------------------------------------
DB user:       meet / $DB_PASSWORD
DB root:       $DB_ROOT_PASSWORD
Redis pass:    $REDIS_PASSWORD
LiveKit key:   $LIVEKIT_API_KEY
LiveKit secret:$LIVEKIT_API_SECRET
TURN secret:   $TURN_SECRET
================================================
Secrets are also stored in: $ENV_FILE
CRED
chmod 600 "$CRED_FILE"

say "\n"
say "  ${CD}════════════════════════════════════════${C0}\n"
if [ -z "$FAILED" ]; then
  say "  ${CG}${CB}✓ Installation complete — all services are running${C0}\n"
else
  say "  ${CR}${CB}✗ Installation finished with problems in:%s${C0}\n" "$FAILED"
  say "  ${CD}Inspect: journalctl -u <service> -n50   and the log: %s${C0}\n" "$LOG_FILE"
fi
say "  ${CD}────────────────────────────────────────${C0}\n"
say "  Site:     ${CB}https://%s${C0}\n" "$APP_DOMAIN"
say "  Admin:    %s\n" "$ADMIN_EMAIL"
say "  Details:  ${CD}%s${C0}  ${CD}(full passwords are there)${C0}\n" "$CRED_FILE"
[ "${ENABLE_TLS,,}" = "y" ] || say "  ${CY}TLS:${C0} ${CD}to issue a certificate later, point DNS then run: ENABLE_TLS=y bash install.sh${C0}\n"
say "  ${CD}════════════════════════════════════════${C0}\n\n"
