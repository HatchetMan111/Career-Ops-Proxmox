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
NODE_MAJOR="22"
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

# HINWEIS: Wir pinnen bewusst NICHT auf den letzten Git-Tag mehr.
# Bei career-ops hängen die Tags weit hinter main zurück (z.B. Tag v1.6.0,
# während main schon bei 1.29.0 war) — ein Pin auf den letzten Tag hätte in
# der Praxis Monate alten Code ohne die Web-UI ausgeliefert. Stattdessen
# tracken wir main und schreiben die exakte Commit-SHA mit, damit du bei
# Bedarf reproduzierbar auf genau diesen Stand zurück kannst.
#
# Optional: COMMIT=<sha> vor dem Aufruf setzen, um einen bestimmten Commit
# zu erzwingen (z.B. für ein späteres, geprüftes Update).
if [[ -n "${COMMIT:-}" ]]; then
  msg_info "Checke expliziten Commit aus: $COMMIT"
  git fetch --depth 1 origin "$COMMIT"
  git checkout "$COMMIT"
fi
INSTALLED_COMMIT=$(git rev-parse HEAD)
echo "$INSTALLED_COMMIT" > .installed_commit
msg_ok "Installierter Commit: $INSTALLED_COMMIT (main, ungetaggt — siehe Hinweis oben)"

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
msg_info "Prüfe auf offizielle Web-UI (web/package.json, benötigt Node >=22)…"
WEB_PORT=3000
if [[ -f web/package.json ]]; then
  msg_ok "web/ gefunden — baue Next.js-Production-Build (das kann etwas dauern)…"
  (
    cd web
    npm ci
    npm run build
  )
  echo "$WEB_PORT" > "$WEB_PORT_FILE"

  cat > /etc/systemd/system/career-ops-web.service <<EOF
[Unit]
Description=career-ops Web UI (opt-in, alpha upstream feature)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}/web
Environment=CAREER_OPS_ROOT=${INSTALL_DIR}
ExecStart=/usr/bin/npx next start -H 0.0.0.0 -p ${WEB_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now career-ops-web
  msg_ok "career-ops-web gestartet: Next.js Production-Build, Port ${WEB_PORT}, Bind 0.0.0.0."
  msg_info "Die Web-UI ist laut Upstream 'alpha' — sie liest/schreibt dieselben Dateien wie die CLI, kein eigener Server-State."
else
  msg_info "Kein web/-Verzeichnis in diesem Checkout gefunden — Web-UI wird übersprungen."
  msg_info "career-ops wird primär über die AI-CLI bedient: cd ${INSTALL_DIR} && opencode ."
  rm -f "$WEB_PORT_FILE"
fi

msg_ok "Guest-Installation abgeschlossen."
