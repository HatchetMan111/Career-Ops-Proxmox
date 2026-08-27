#!/usr/bin/env bash
#
# career-ops-guest.sh — runs INSIDE the LXC container (called by career-ops.sh
# via `pct exec`). Not meant to be run standalone on a normal machine unless
# you know what you're doing — it installs system-wide packages and services.
#
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/santifer/career-ops.git}"
WITH_OLLAMA="${WITH_OLLAMA:-yes}"
INSTALL_DIR="/opt/career-ops"
NODE_MAJOR="20"
WEB_PORT_FILE="/root/.career-ops-web-port"

msg_info()  { echo -e "\e[36m[GUEST INFO]\e[0m  $*"; }
msg_ok()    { echo -e "\e[32m[GUEST  OK ]\e[0m  $*"; }
msg_err()   { echo -e "\e[31m[GUEST FAIL]\e[0m  $*" >&2; }

on_error() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]:-?}
  local cmd=${BASH_COMMAND:-?}
  msg_err "Guest-Installation abgebrochen (Exit-Code $exit_code) in Zeile $line_no"
  msg_err "Fehlgeschlagener Befehl: $cmd"
  msg_err "----- Aufrufkette -----"
  local i=0
  while caller $i >&2; do ((i++)); done
  msg_err "------------------------"
  exit "$exit_code"
}
trap on_error ERR

# ---------------------------------------------------------------------------
msg_info "Aktualisiere Paketquellen und installiere Basis-Abhängigkeiten…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl git ca-certificates gnupg build-essential

# ---------------------------------------------------------------------------
msg_info "Installiere Node.js ${NODE_MAJOR}.x…"
if ! command -v node >/dev/null 2>&1 || [[ "$(node -v | grep -oE '^v[0-9]+' | tr -d v)" -lt "$NODE_MAJOR" ]]; then
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get install -y nodejs
fi
msg_ok "Node $(node -v), npm $(npm -v)"

# ---------------------------------------------------------------------------
if [[ "$WITH_OLLAMA" == "yes" ]]; then
  msg_info "Installiere Ollama (offizielles Installskript)…"
  curl -fsSL https://ollama.com/install.sh | sh
  systemctl enable --now ollama
  msg_ok "Ollama läuft (systemd: ollama). Modelle NICHT vorinstalliert — siehe Hinweis am Ende."
else
  msg_info "WITH_OLLAMA=no — überspringe Ollama-Installation."
fi

# ---------------------------------------------------------------------------
msg_info "Klone career-ops (offizielles Upstream-Repo: ${REPO_URL})…"
rm -rf "$INSTALL_DIR"
git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Versuche, auf das neueste Release zu pinnen statt auf einen bewegten main-Branch
LATEST_TAG=$(git ls-remote --tags --refs "$REPO_URL" \
  | awk -F/ '{print $NF}' \
  | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
  | sort -V | tail -n1 || true)
if [[ -n "$LATEST_TAG" ]]; then
  msg_info "Pinne auf Release $LATEST_TAG…"
  git fetch --depth 1 origin "refs/tags/${LATEST_TAG}:refs/tags/${LATEST_TAG}" 2>/dev/null || true
  git checkout "$LATEST_TAG" 2>/dev/null || msg_info "Konnte Tag nicht auschecken, bleibe auf main."
else
  msg_info "Kein Versions-Tag gefunden, bleibe auf main (weniger reproduzierbar — für Updates: erneut ausführen)."
fi

msg_info "Installiere npm-Abhängigkeiten…"
npm ci --omit=dev 2>/dev/null || npm install --omit=dev

# Playwright-Systemabhängigkeiten (falls das Projekt Playwright nutzt)
if grep -q '"playwright"' package.json 2>/dev/null; then
  msg_info "Installiere Playwright-Browser + System-Abhängigkeiten (Chromium)…"
  npx playwright install --with-deps chromium
fi

# ---------------------------------------------------------------------------
msg_info "Richte leere, sichere Standard-Konfiguration ein (keine Portale aktiv)…"
if [[ -f templates/portals.example.yml ]]; then
  cp templates/portals.example.yml portals.example.yml.reference
fi
cat > portals.yml <<'EOF'
# portals.yml — bewusst leer ausgeliefert.
#
# Trage hier NUR Jobportale ein, deren Nutzungsbedingungen du geprüft hast.
# Eine Beispielkonfiguration liegt (falls vorhanden) in
# portals.example.yml.reference — NICHT blind kopieren.
portals: []
EOF
msg_ok "portals.yml ist leer. Aktivierung von Portalen ist eine bewusste, manuelle Entscheidung."

# ---------------------------------------------------------------------------
msg_info "Installiere OpenCode CLI (model-agnostisch, kompatibel mit Ollama)…"
npm install -g opencode-ai

if [[ "$WITH_OLLAMA" == "yes" ]]; then
  mkdir -p /root/.config/opencode
  cat > /root/.config/opencode/opencode.json <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (local)",
      "options": { "baseURL": "http://localhost:11434/v1" },
      "models": {
        "qwen2.5-coder:14b": {}
      }
    }
  }
}
EOF
  msg_info "OpenCode ist auf Ollama vorkonfiguriert (Platzhaltermodell: qwen2.5-coder:14b)."
  msg_info "UNGETESTET mit career-ops speziell — Qualität für JD-Bewertung/Anschreiben selbst prüfen."
  msg_info "OpenCode braucht laut Doku 64k+ Kontextfenster — kleine Modell-Tags oft darunter, ollama pull entsprechend wählen."
fi

# ---------------------------------------------------------------------------
msg_info "Suche nach einer nativen Web-UI im Repo (Stand: laut Roadmap Release Candidate)…"
WEB_SCRIPT=""
if [[ -f package.json ]] && command -v node >/dev/null; then
  WEB_SCRIPT=$(node -e "
    const p = require('./package.json');
    const s = p.scripts || {};
    const hit = Object.keys(s).find(k => /web/i.test(k) && !/dashboard/i.test(k));
    process.stdout.write(hit || '');
  " 2>/dev/null || true)
fi

if [[ -n "$WEB_SCRIPT" ]]; then
  msg_ok "Gefundenes Web-UI-Skript: npm run $WEB_SCRIPT"
  WEB_PORT=3210
  echo "$WEB_PORT" > "$WEB_PORT_FILE"

  cat > /etc/systemd/system/career-ops-web.service <<EOF
[Unit]
Description=career-ops Web UI (opt-in, alpha upstream feature)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
Environment=PORT=${WEB_PORT}
Environment=HOST=0.0.0.0
ExecStart=/usr/bin/npm run ${WEB_SCRIPT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now career-ops-web
  msg_info "career-ops-web gestartet. ANNAHME: die App liest den PORT aus der Umgebungsvariable PORT."
  msg_info "Falls das nicht stimmt (Port hart codiert), prüfe web/README.md im Repo und passe die systemd-Unit an:"
  msg_info "  /etc/systemd/system/career-ops-web.service"
else
  msg_info "Keine Web-UI im aktuellen Checkout gefunden (2.0-Web-UI ist laut Upstream-Roadmap noch RC/nicht überall released)."
  msg_info "Kein Problem — career-ops wird ohnehin primär über die AI-CLI bedient:"
  msg_info "  cd ${INSTALL_DIR} && opencode ."
  rm -f "$WEB_PORT_FILE"
fi

msg_ok "Guest-Installation abgeschlossen."
