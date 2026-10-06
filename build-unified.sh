#!/bin/bash
# Bouwt IPTV-player + Nuvio TV in één IPK (com.lennylxx.iptv).
# Gebruik:  bash build-unified.sh            (alleen bouwen)
#           bash build-unified.sh --install  (bouwen + installeren op device "lg")
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

NUVIO_DIR="${NUVIO_DIR:-/home/mustafa/NuvioTVSmart}"
DEVICE="${DEVICE:-lg}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YEL}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

command -v node >/dev/null 2>&1 || error "Node.js nodig (gebruik: nvm use 20)"
command -v ares-package >/dev/null 2>&1 || error "ares-package niet gevonden (npm install -g @webos-tools/cli)"
[ -d "$NUVIO_DIR" ] || error "Nuvio-map niet gevonden: $NUVIO_DIR (zet NUVIO_DIR=... of verplaats de clone daarheen)"
[ -f "$NUVIO_DIR/package.json" ] || error "$NUVIO_DIR lijkt geen NuvioTVSmart-repo"

# ---------------------------------------------------------------
# 1. Nuvio bouwen en de gestagede webOS-app overnemen
# ---------------------------------------------------------------
if [ ! -f "$NUVIO_DIR/local.properties" ]; then
  warn "Geen $NUVIO_DIR/local.properties gevonden. Zie local.example.properties."
  warn "Zonder die instellingen kan o.a. de Nuvio QR-login ontbreken of falen."
fi

info "Nuvio: dependencies + package:webos (levert de staging-map op)..."
(
  cd "$NUVIO_DIR"
  [ -d node_modules ] || npm install
  npm run package:webos
)

STAGE="$NUVIO_DIR/.cache/webos-package/app"
[ -f "$STAGE/index.html" ] && [ -f "$STAGE/app.bundle.js" ] \
  || error "Nuvio-staging ontbreekt in $STAGE (package:webos mislukt?)"

NUVIO_OUT="$SCRIPT_DIR/.nuvio-embedded"
rm -rf "$NUVIO_OUT"
cp -r "$STAGE" "$NUVIO_OUT"

# Een tweede appinfo/icons in een submap zijn overbodig (en kunnen ares-package verwarren)
rm -f "$NUVIO_OUT/appinfo.json" "$NUVIO_OUT/icon.png" "$NUVIO_OUT/largeIcon.png" "$NUVIO_OUT/splash.png"

# Nuvio's eigen services (torrent/P2P en plugins) kunnen hier niet mee: service-id's
# moeten met het app-id beginnen. Schakel de plugin-service uit in de embedded versie.
if grep -q "__NUVIO_WEBOS_PLUGIN_SERVICE_ENABLED__ = true" "$NUVIO_OUT/index.html"; then
  sed -i 's/__NUVIO_WEBOS_PLUGIN_SERVICE_ENABLED__ = true/__NUVIO_WEBOS_PLUGIN_SERVICE_ENABLED__ = false/' "$NUVIO_OUT/index.html"
else
  warn "Plugin-service-vlag niet gevonden in Nuvio index.html; controleer handmatig."
fi

# Groene knop (404) = terug naar IPTV
cat > "$NUVIO_OUT/return-to-iptv.js" <<'EOF'
document.addEventListener('keydown', function (e) {
  if (e.keyCode === 404) {
    e.preventDefault();
    e.stopPropagation();
    window.location.href = '../index.html';
  }
}, true);
EOF
if grep -q '<script src="boot-guard.js"></script>' "$NUVIO_OUT/index.html"; then
  sed -i 's#<script src="boot-guard.js"></script>#<script src="return-to-iptv.js"></script>\n  <script src="boot-guard.js"></script>#' "$NUVIO_OUT/index.html"
else
  warn "boot-guard.js-tag niet gevonden; terugknop (groen) niet geïnjecteerd."
fi

# ---------------------------------------------------------------
# 2. IPTV-app bouwen (zelfde stappen als build.sh)
# ---------------------------------------------------------------
[ -d node_modules ] || { info "IPTV: npm install..."; npm install; }

# Nuvio heeft deze permissies nodig; toevoegen als ze ontbreken (idempotent)
node -e "
const fs=require('fs');const f='appinfo.json';const a=JSON.parse(fs.readFileSync(f,'utf8'));
if(!a.requiredPermissions){a.requiredPermissions=['internet','media.operation','media.query'];
fs.writeFileSync(f,JSON.stringify(a,null,2)+'\n');console.log('requiredPermissions toegevoegd');}
"

info "IPTV: lint (Chromium 53 gate)..."
npm run lint

info "IPTV: build (typecheck + esbuild)..."
npm run build

info "IPTV: service bouwen..."
rm -rf build/bundled-service
npx tsc -p bundled-service/tsconfig.json
node scripts/service-compat-gate.mjs build/bundled-service
node scripts/run-service-smoke.mjs
cp bundled-service/package.json build/bundled-service/
cp bundled-service/src/services.json build/bundled-service/
cp bundled-service/src/setup/setup-page.html build/bundled-service/setup/

# ---------------------------------------------------------------
# 3. Nuvio in dist/nuvio zetten en pakken
# ---------------------------------------------------------------
info "Nuvio inbouwen in dist/nuvio..."
rm -rf dist/nuvio
cp -r "$NUVIO_OUT" dist/nuvio

info "IPK maken..."
rm -f ./*.ipk
ares-package --no-minify -e "*preview-libs.js" dist build/bundled-service -o .

IPK=$(ls -t ./*.ipk 2>/dev/null | head -1)
[ -n "$IPK" ] || error "Geen IPK gemaakt"
info "Klaar: $IPK ($(du -h "$IPK" | cut -f1))"

if [ "$1" = "--install" ]; then
  info "Installeren op $DEVICE..."
  ares-install -d "$DEVICE" "$IPK"
  ares-launch -d "$DEVICE" --close com.lennylxx.iptv 2>/dev/null || true
  sleep 1
  ares-launch -d "$DEVICE" com.lennylxx.iptv
  info "App draait op $DEVICE"
fi
