#!/usr/bin/env bash
# ============================================================================
#  install.sh — مثبِّت منصّة الاجتماعات (LiveKit + PHP + MySQL + nginx)
#  • قابل لإعادة الاستخدام على أي سيرفر Ubuntu 22.04/24.04 (بصلاحية root)
#  • يعمل من داخل مجلد المشروع، أو يحمّل الحزمة (.zip) من BUNDLE_URL
#  • idempotent: يمكن إعادة تشغيله بأمان — لا يفقد بيانات ولا أسرارًا
#  • ذاتي الإصلاح: يتحقّق من كل خدمة وما لا يعمل يعيد تشغيله ثم إعادة تثبيته
#
#  الاستخدام:
#    sudo bash install.sh                       # تفاعلي (يسأل عن الدومين…)
#    sudo APP_DOMAIN=meet.site.com \
#         LIVEKIT_DOMAIN=lk.site.com \
#         ADMIN_EMAIL=admin@site.com \
#         ADMIN_PASSWORD=Str0ng! \
#         MEET_NONINTERACTIVE=1 bash install.sh # صامت
#    curl -fsSL <رابط>/install.sh | sudo BUNDLE_URL=<رابط .zip> bash
# ============================================================================
set -Eeuo pipefail

# ---- إصدارات مثبّتة ----
PHP_VER="${PHP_VER:-8.2}"
LIVEKIT_VERSION="${LIVEKIT_VERSION:-1.13.7}"

# ---- مصدر الحزمة الافتراضي (يُستخدم عند التشغيل عبر curl|bash) ----
# لو شغّلت السكربت من داخل مجلد المشروع، تُستخدم الملفات المحلية ويُتجاهل هذا الرابط.
BUNDLE_URL="${BUNDLE_URL:-https://github.com/hooda77/domain/raw/refs/heads/main/meet-platform.zip}"

# ---- مسارات ----
APP_DIR="/var/www/meet"
REC_DIR="/var/lib/meet/recordings"
ENV_FILE="$APP_DIR/.env"
CRED_FILE="/root/meet-credentials.txt"
LOG_FILE="/var/log/meet-install.log"

# ---- ألوان وتسجيل ----
if [ -t 1 ]; then C0='\033[0m'; C1='\033[1;36m'; CG='\033[1;32m'; CY='\033[1;33m'; CR='\033[1;31m'; else C0='' C1='' CG='' CY='' CR=''; fi
_ts(){ date '+%H:%M:%S'; }
log(){ printf "${C1}==>${C0} %s\n" "$*"; printf '[%s] STEP %s\n' "$(_ts)" "$*" >>"$LOG_FILE" 2>/dev/null || true; }
ok(){  printf "${CG} ✓${C0} %s\n" "$*"; }
warn(){ printf "${CY} !${C0} %s\n" "$*"; }
err(){ printf "${CR} ✗${C0} %s\n" "$*" >&2; }
die(){ err "$*"; echo "راجع السجل: $LOG_FILE"; exit 1; }

export DEBIAN_FRONTEND=noninteractive
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
: >"$LOG_FILE" 2>/dev/null || true
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'err "فشل عند السطر $LINENO (الأمر: $BASH_COMMAND)"' ERR

# ============================================================================
#  0) فحوص أولية
# ============================================================================
[ "$(id -u)" = "0" ] || die "شغّل السكربت بصلاحية root (استخدم sudo)."
if ! command -v apt-get >/dev/null 2>&1; then die "هذا المثبّت لـ Ubuntu/Debian فقط (apt-get غير موجود)."; fi
. /etc/os-release 2>/dev/null || true
log "النظام: ${PRETTY_NAME:-غير معروف}"

# ============================================================================
#  1) قراءة الإعدادات (env أو تفاعليًا)
# ============================================================================
NONINTERACTIVE="${MEET_NONINTERACTIVE:-0}"
# عند التشغيل عبر «curl | bash» يكون stdin هو الأنبوب لا الطرفية،
# لذا نقرأ من /dev/tty مباشرة إن كانت متاحة (وإلا نستخدم الافتراضي)
ask(){ # ask VAR "السؤال" "الافتراضي"
  local __var="$1" __q="$2" __def="${3:-}" __ans=""
  local __cur="${!__var:-}"
  if [ -n "$__cur" ]; then eval "$__var=\$__cur"; return; fi
  if [ "$NONINTERACTIVE" = "1" ] || [ ! -r /dev/tty ]; then eval "$__var=\$__def"; return; fi
  read -rp "$__q [${__def}]: " __ans </dev/tty >/dev/tty 2>&1 || true
  eval "$__var=\${__ans:-\$__def}"
}

# IP العام (كشف تلقائي)
detect_ip(){ curl -fsS4 https://api.ipify.org 2>/dev/null || curl -fsS4 https://ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}'; }
PUBLIC_IP="${PUBLIC_IP:-$(detect_ip)}"

# لو يوجد .env سابق حمّل قيمه (حفاظًا على الأسرار والدومين)
if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; ok "تم العثور على إعداد سابق ($ENV_FILE) — سيُعاد استخدام الأسرار."; fi

ask APP_DOMAIN     "دومين الموقع"           "${APP_DOMAIN:-meet.example.com}"
ask LIVEKIT_DOMAIN "دومين LiveKit"          "${LIVEKIT_DOMAIN:-livekit.${APP_DOMAIN}}"
ask ADMIN_EMAIL    "بريد الأدمن"            "${ADMIN_EMAIL:-admin@${APP_DOMAIN}}"
ask ADMIN_PASSWORD "كلمة مرور الأدمن"       "${ADMIN_PASSWORD:-$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-14)}"
ask PUBLIC_IP      "IP العام للسيرفر"       "${PUBLIC_IP:-127.0.0.1}"
ask ENABLE_TLS     "إصدار شهادة TLS تلقائيًا عبر Let's Encrypt؟ (y/n) — يتطلب توجيه DNS للنطاقين" "${ENABLE_TLS:-y}"

log "الإعدادات: APP=$APP_DOMAIN  LIVEKIT=$LIVEKIT_DOMAIN  IP=$PUBLIC_IP  TLS=$ENABLE_TLS"

# ============================================================================
#  2) تحديد مصدر ملفات المشروع (محلي أو تنزيل الحزمة)
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "$PWD")"
find_src(){ # يبحث عن مجلد يحوي backend/ و public/
  for d in "$SCRIPT_DIR" "$SCRIPT_DIR/.." "$PWD"; do
    if [ -d "$d/backend" ] && [ -d "$d/public" ]; then (cd "$d" && pwd); return 0; fi
  done
  return 1
}
if SRC_DIR="$(find_src)"; then
  ok "مصدر الملفات محليًا: $SRC_DIR"
elif [ -n "${BUNDLE_URL:-}" ]; then
  log "تنزيل الحزمة من: $BUNDLE_URL"
  TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
  curl -fL --retry 3 -o "$TMPD/bundle.zip" "$BUNDLE_URL" || die "تعذّر تنزيل الحزمة من BUNDLE_URL"
  mkdir -p "$TMPD/x"
  # فكّ الضغط: unzip إن وُجد، وإلا ثبّته، وإلا استخدم python3 كخطة بديلة
  if ! command -v unzip >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y unzip >/dev/null 2>&1 || true
  fi
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$TMPD/bundle.zip" -d "$TMPD/x" || die "تعذّر فكّ الحزمة (unzip)"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$TMPD/bundle.zip" "$TMPD/x" || die "تعذّر فكّ الحزمة (python3)"
  else
    die "لا يوجد unzip ولا python3 لفكّ الحزمة."
  fi
  # ابحث عن جذر المشروع داخل ما فُكّ (قد يكون داخل مجلد فرعي)
  ROOT="$(find "$TMPD/x" -maxdepth 3 -type d -name backend -printf '%h\n' 2>/dev/null | head -1)"
  [ -n "$ROOT" ] && [ -d "$ROOT/public" ] || die "لم أجد backend/ و public/ داخل الحزمة"
  SRC_DIR="$ROOT"; ok "تم فكّ الحزمة: $SRC_DIR"
else
  die "لا توجد ملفات المشروع محليًا ولا BUNDLE_URL. ضع install.sh بجوار backend/ و public/ أو مرّر BUNDLE_URL=<رابط .zip>."
fi

# ============================================================================
#  آلية إعادة المحاولة العامة
# ============================================================================
retry(){ # retry <مرّات> <وصف> <أمر...>
  local n="$1" desc="$2"; shift 2
  local i=1
  while [ "$i" -le "$n" ]; do
    if "$@"; then return 0; fi
    warn "«$desc» فشل (محاولة $i/$n) — إعادة خلال 3ث…"; sleep 3; i=$((i+1))
  done
  return 1
}

# ============================================================================
#  خطوات التثبيت (كل واحدة idempotent)
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
    php${PHP_VER}-bcmath php${PHP_VER}-curl php${PHP_VER}-xml php${PHP_VER}-zip php${PHP_VER}-gd
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
  # طبّق كل ملفات الهجرة الموجودة (بالترتيب)
  if [ -d "$APP_DIR/db/migrations" ]; then
    for m in $(ls -1 "$APP_DIR/db/migrations"/*.sql 2>/dev/null | sort); do
      mysql -uroot meet < "$m" || warn "هجرة تخطّت (قد تكون مطبّقة): $(basename "$m")"
    done
  fi
  local hash
  hash="$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$ADMIN_PASSWORD")"
  mysql -uroot meet <<SQL
INSERT INTO users (email,password_hash,name,role)
VALUES ('$ADMIN_EMAIL','$hash','Admin','admin')
ON DUPLICATE KEY UPDATE role='admin';
INSERT INTO nodes (name,host,ssh_user,ssh_port,region,is_main,status,last_seen)
VALUES ('السيرفر الأساسي','$PUBLIC_IP','root',22,'main',1,'online',NOW())
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
  [ "${ENABLE_TLS,,}" = "y" ] || { warn "تم تخطّي TLS (ENABLE_TLS=$ENABLE_TLS) — nginx على شهادة ذاتية."; return 0; }
  local LE=""
  if certbot certonly --webroot -w /var/www/certbot -d "$APP_DOMAIN" -d "$LIVEKIT_DOMAIN" \
       --non-interactive --agree-tos -m "$ADMIN_EMAIL" 2>/tmp/cb.log; then
    LE="/etc/letsencrypt/live/$APP_DOMAIN"
  elif certbot certonly --webroot -w /var/www/certbot -d "$LIVEKIT_DOMAIN" \
       --non-interactive --agree-tos -m "$ADMIN_EMAIL" 2>>/tmp/cb.log; then
    LE="/etc/letsencrypt/live/$LIVEKIT_DOMAIN"
  else
    warn "تعذّر إصدار شهادة Let's Encrypt (تحقّق من DNS) — يبقى على الشهادة الذاتية. راجع /tmp/cb.log"; return 0
  fi
  if [ -n "$LE" ] && [ -f "$LE/fullchain.pem" ]; then
    sed -i "s#$SS/fullchain.pem#$LE/fullchain.pem#g; s#$SS/privkey.pem#$LE/privkey.pem#g" \
      /etc/nginx/sites-available/meet.conf
    nginx -t && systemctl reload nginx && ok "TLS مُفعّل عبر Let's Encrypt"
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
  # مؤقّت تنظيف الاجتماعات المنتهية (حذف تلقائي بعد 24 ساعة)
  [ -f "$SRC_DIR/scripts/cleanup.php" ] || { warn "cleanup.php غير موجود — تخطّي المؤقّت."; return 0; }
  cp -a "$SRC_DIR/scripts/cleanup.php" "$APP_DIR/scripts/" 2>/dev/null || { mkdir -p "$APP_DIR/scripts"; cp -a "$SRC_DIR/scripts/cleanup.php" "$APP_DIR/scripts/"; }
  chown -R www-data:www-data "$APP_DIR/scripts"
  cat > /etc/systemd/system/meet-cleanup.service <<UNIT
[Unit]
Description=Meet cleanup (close expired rooms + delete >24h ended meetings)
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
#  تشغيل الخطوات بالترتيب (مع إعادة محاولة)
# ============================================================================
declare -i N=0
run(){ N+=1; log "$N) $1"; if retry 2 "$1" "$2"; then ok "$1"; else die "فشل نهائيًا: $1"; fi; }

run "حزم أساسية + إزالة Docker"        step_base
run "توليد/تحميل الأسرار (.env)"        step_env
run "MySQL"                             step_mysql
run "Redis"                             step_redis
run "PHP ${PHP_VER}-FPM + Composer"     step_php
run "نشر ملفات التطبيق"                 step_deploy
run "المخطط + الهجرات + الأدمن"         step_db
run "LiveKit ${LIVEKIT_VERSION}"        step_livekit
run "coturn (TURN/STUN)"                step_coturn
run "nginx"                             step_nginx
run "شهادة TLS"                         step_tls
run "الجدار الناري (ufw)"               step_firewall
run "مؤقّت التنظيف الدوري"              step_cleanup_timer

# ============================================================================
#  التحقّق النهائي + الإصلاح الذاتي
# ============================================================================
declare -A HEAL=(
  [mysql]=step_mysql [redis-server]=step_redis [php${PHP_VER}-fpm]=step_php
  [livekit]=step_livekit [coturn]=step_coturn [nginx]=step_nginx
)
SERVICES="mysql redis-server php${PHP_VER}-fpm livekit coturn nginx"

log "التحقّق النهائي والإصلاح الذاتي"
FAILED=""
for s in $SERVICES; do
  for attempt in 1 2 3; do
    if systemctl is-active --quiet "$s"; then break; fi
    if [ "$attempt" = 1 ]; then warn "$s متوقّف — محاولة إعادة التشغيل"; systemctl restart "$s" 2>/dev/null || true; sleep 2; continue; fi
    warn "$s ما زال متوقّفًا — إعادة تثبيت (${HEAL[$s]:-none})"
    fn="${HEAL[$s]:-}"; [ -n "$fn" ] && "$fn" 2>/dev/null || true; sleep 2
  done
  if systemctl is-active --quiet "$s"; then ok "خدمة $s تعمل"; else err "خدمة $s متوقّفة"; FAILED="$FAILED $s"; fi
done

# فحوص وظيفية
sleep 2
LK="$(curl -sS http://127.0.0.1:7880/ -o /dev/null -w '%{http_code}' 2>/dev/null || echo 000)"
[ "$LK" != 000 ] && ok "LiveKit HTTP يستجيب ($LK)" || { err "LiveKit لا يستجيب"; FAILED="$FAILED livekit-http"; }
API="$(curl -sS -k https://127.0.0.1/api/auth/me -H "Host: $APP_DOMAIN" -o /dev/null -w '%{http_code}' 2>/dev/null || echo 000)"
if [ "$API" = 401 ] || [ "$API" = 200 ]; then ok "الـ API يستجيب ($API)"; else err "الـ API لا يستجيب ($API)"; FAILED="$FAILED api"; fi

# ============================================================================
#  حفظ بيانات الدخول + التقرير
# ============================================================================
set -a; . "$ENV_FILE"; set +a
cat > "$CRED_FILE" <<CRED
منصّة الاجتماعات — بيانات التثبيت ($(date))
================================================
الموقع:        https://$APP_DOMAIN
LiveKit:       wss://$LIVEKIT_DOMAIN
IP العام:      $PUBLIC_IP
------------------------------------------------
أدمن (بريد):   $ADMIN_EMAIL
أدمن (كلمة):   $ADMIN_PASSWORD    ← غيّرها بعد أول دخول
------------------------------------------------
DB user:       meet / $DB_PASSWORD
DB root:       $DB_ROOT_PASSWORD
Redis pass:    $REDIS_PASSWORD
LiveKit key:   $LIVEKIT_API_KEY
LiveKit secret:$LIVEKIT_API_SECRET
TURN secret:   $TURN_SECRET
================================================
الأسرار محفوظة أيضًا في: $ENV_FILE
CRED
chmod 600 "$CRED_FILE"

echo
echo "=================================================="
if [ -z "$FAILED" ]; then
  printf "${CG}✓ التثبيت اكتمل وكل الخدمات تعمل${C0}\n"
else
  printf "${CR}✗ اكتمل التثبيت لكن مع مشاكل في:%s${C0}\n" "$FAILED"
  echo "  افحص: journalctl -u <الخدمة> -n50   والسجل: $LOG_FILE"
fi
echo "--------------------------------------------------"
echo "الموقع:   https://$APP_DOMAIN"
echo "الأدمن:   $ADMIN_EMAIL"
echo "البيانات: $CRED_FILE   (كلمات المرور كاملة هناك)"
echo "ملاحظة: التسجيل يتم من المتصفح (client-side) وينزل محليًا — لا يتطلّب Egress."
[ "${ENABLE_TLS,,}" = "y" ] || echo "TLS: لإصدار شهادة لاحقًا وجّه DNS ثم: ENABLE_TLS=y bash install.sh"
echo "=================================================="
