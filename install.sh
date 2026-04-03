#!/bin/bash
set -e

# --- Couleurs ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERREUR]${NC} $1"; exit 1; }

# --- Vérif root ---
[ "$EUID" -ne 0 ] && log_error "Lance en root"

# --- Variables ---
PAPERLESS_VERSION="2.13.5"
PAPERLESS_DIR="/opt/paperless"
PAPERLESS_USER="paperless"
PAPERLESS_PORT="8000"
TIMEZONE="Europe/Paris"
OCR_LANGUAGE="fra+eng"
ALLOWED_HOSTS="localhost,127.0.0.1"

# =============================================================================
log_info "1/13 Update système"
apt update -qq && apt upgrade -y -qq

# =============================================================================
log_info "2/13 Dépendances"
apt install -y -qq \
 python3 python3-pip python3-dev python3-venv \
 imagemagick fonts-liberation gnupg \
 libpq-dev default-libmysqlclient-dev \
 pkg-config libmagic-dev libzbar0 poppler-utils \
 unpaper ghostscript icc-profiles-free qpdf \
 libxml2 pngquant zlib1g \
 tesseract-ocr tesseract-ocr-fra tesseract-ocr-eng \
 build-essential python3-setuptools python3-wheel \
 curl redis-server

# =============================================================================
log_info "3/13 Redis"
systemctl enable redis-server --quiet
systemctl start redis-server
redis-cli ping | grep -q PONG || log_error "Redis KO"

# =============================================================================
log_info "4/13 User"
id "$PAPERLESS_USER" &>/dev/null || adduser "$PAPERLESS_USER" --system --home "$PAPERLESS_DIR" --group

# =============================================================================
log_info "5/13 Download"
cd /tmp
ARCHIVE="paperless-ngx-v${PAPERLESS_VERSION}.tar.xz"
URL="https://github.com/paperless-ngx/paperless-ngx/releases/download/v${PAPERLESS_VERSION}/${ARCHIVE}"

[ -f "$ARCHIVE" ] || curl -LO "$URL"
tar -xf "$ARCHIVE"

# FIX ROBUSTE
EXTRACTED_DIR=$(find /tmp -maxdepth 1 -type d -name "paperless-ngx*" | head -n 1)
[ -z "$EXTRACTED_DIR" ] && log_error "Extraction introuvable"

# =============================================================================
log_info "6/13 Copie"
mkdir -p "$PAPERLESS_DIR"
cp -r "$EXTRACTED_DIR"/* "$PAPERLESS_DIR/"
chown -R "$PAPERLESS_USER:$PAPERLESS_USER" "$PAPERLESS_DIR"

# =============================================================================
log_info "7/13 Dossiers"
for dir in media data consume; do
 mkdir -p "${PAPERLESS_DIR}/${dir}"
 chown "$PAPERLESS_USER:$PAPERLESS_USER" "${PAPERLESS_DIR}/${dir}"
done

# =============================================================================
log_info "8/13 Python venv"
sudo -Hu "$PAPERLESS_USER" python3 -m venv "${PAPERLESS_DIR}/venv"
sudo -Hu "$PAPERLESS_USER" "${PAPERLESS_DIR}/venv/bin/pip" install -q --upgrade pip
sudo -Hu "$PAPERLESS_USER" "${PAPERLESS_DIR}/venv/bin/pip" install -q -r "${PAPERLESS_DIR}/requirements.txt"

# =============================================================================
log_info "9/13 Config"
SECRET_KEY=$(openssl rand -base64 32)

cat > "${PAPERLESS_DIR}/paperless.conf" << EOF
PAPERLESS_REDIS=redis://localhost:6379
PAPERLESS_SECRET_KEY=${SECRET_KEY}
PAPERLESS_CONSUMPTION_DIR=${PAPERLESS_DIR}/consume
PAPERLESS_DATA_DIR=${PAPERLESS_DIR}/data
PAPERLESS_MEDIA_ROOT=${PAPERLESS_DIR}/media
PAPERLESS_DBENGINE=sqlite
PAPERLESS_OCR_LANGUAGE=${OCR_LANGUAGE}
PAPERLESS_TIME_ZONE=${TIMEZONE}
PAPERLESS_ALLOWED_HOSTS=${ALLOWED_HOSTS}
PAPERLESS_URL=http://localhost:${PAPERLESS_PORT}
EOF

chown "$PAPERLESS_USER:$PAPERLESS_USER" "${PAPERLESS_DIR}/paperless.conf"
chmod 600 "${PAPERLESS_DIR}/paperless.conf"

# =============================================================================
log_info "10/13 ImageMagick"
POLICY="/etc/ImageMagick-6/policy.xml"
[ -f "$POLICY" ] && sed -i '/pattern="PDF"/c\<policy domain="coder" rights="read|write" pattern="PDF" />' "$POLICY"

# =============================================================================
log_info "11/13 DB + static"
cd "${PAPERLESS_DIR}/src"
sudo -Hu "$PAPERLESS_USER" "${PAPERLESS_DIR}/venv/bin/python3" manage.py migrate --noinput

# 🔥 FIX IMPORTANT
sudo -Hu "$PAPERLESS_USER" "${PAPERLESS_DIR}/venv/bin/python3" manage.py collectstatic --noinput

# =============================================================================
log_info "12/13 Services"

VENV_BIN="${PAPERLESS_DIR}/venv/bin"
ENV_PATH="PATH=${VENV_BIN}:/usr/local/bin:/usr/bin:/bin"

cat > /etc/systemd/system/paperless-webserver.service << EOF
[Service]
User=${PAPERLESS_USER}
WorkingDirectory=${PAPERLESS_DIR}/src
EnvironmentFile=${PAPERLESS_DIR}/paperless.conf
Environment=${ENV_PATH}
ExecStart=${VENV_BIN}/python3 manage.py runserver 0.0.0.0:${PAPERLESS_PORT}
Restart=always
EOF

cat > /etc/systemd/system/paperless-consumer.service << EOF
[Service]
User=${PAPERLESS_USER}
WorkingDirectory=${PAPERLESS_DIR}/src
EnvironmentFile=${PAPERLESS_DIR}/paperless.conf
Environment=${ENV_PATH}
ExecStart=${VENV_BIN}/python3 manage.py document_consumer
Restart=always
EOF

cat > /etc/systemd/system/paperless-taskqueue.service << EOF
[Service]
User=${PAPERLESS_USER}
WorkingDirectory=${PAPERLESS_DIR}/src
EnvironmentFile=${PAPERLESS_DIR}/paperless.conf
Environment=${ENV_PATH}
ExecStart=${VENV_BIN}/celery -A paperless worker --loglevel=INFO
Restart=always
EOF

cat > /etc/systemd/system/paperless-scheduler.service << EOF
[Service]
User=${PAPERLESS_USER}
WorkingDirectory=${PAPERLESS_DIR}/src
EnvironmentFile=${PAPERLESS_DIR}/paperless.conf
Environment=${ENV_PATH}
ExecStart=${VENV_BIN}/celery -A paperless beat --loglevel=INFO
Restart=always
EOF

systemctl daemon-reload

# =============================================================================
log_info "13/13 Start services"

ALL_OK=true
for s in paperless-webserver paperless-consumer paperless-taskqueue paperless-scheduler; do
 systemctl enable $s --quiet
 systemctl start $s
 sleep 1
 if systemctl is-active --quiet $s; then
   log_success "$s OK"
 else
   echo -e "${RED}[ERREUR]${NC} $s KO"
   ALL_OK=false
 fi
done

# =============================================================================
echo ""
echo "http://localhost:${PAPERLESS_PORT}"
echo "Créer admin :"
echo "sudo -Hu ${PAPERLESS_USER} ${VENV_BIN}/python3 ${PAPERLESS_DIR}/src/manage.py createsuperuser"

$ALL_OK && log_success "Installation OK" || log_warning "Problèmes détectés"

echo ""
log_info "Création du compte administrateur Paperless"
echo "Veuillez entrer les identifiants :"

sudo -Hu ${PAPERLESS_USER} ${VENV_BIN}/python3 ${PAPERLESS_DIR}/src/manage.py createsuperuser