#!/usr/bin/env bash
#
# career-ops.sh — Proxmox VE LXC installer for career-ops
# Run on the PROXMOX HOST (not inside a container).
#
# One-liner:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/USER/REPO/main/install/career-ops.sh)"
#
# Style: inspired by community-scripts.github.io/ProxmoxVE, but intentionally
# self-contained (no sourcing of third-party remote functions) so the whole
# thing is readable top to bottom before you run it as root.
#
# IMPORTANT — read this before running:
#   - career-ops is an interactive AI-CLI skill, NOT a background job-search
#     daemon. This script gives you a container with Node.js, an AI coding
#     CLI (OpenCode), Ollama, and career-ops cloned and ready. You still run
#     the actual job-search pipeline yourself, interactively, inside the
#     container.
#   - portals.yml ships EMPTY. Scanning a job board's pages/API without
#     checking its Terms of Service is on you, not on this script. See
#     templates/portals.example.yml inside the container after install.
#   - Only the upstream repo (github.com/santifer/career-ops) is used.
#     Random forks are not vetted by this script and are not fetched.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config (override via environment variables before running, e.g.
#   CTID=150 HOSTNAME=career-ops-de bash career-ops.sh
# )
# ---------------------------------------------------------------------------
APP="career-ops"
REPO_URL="https://github.com/santifer/career-ops.git"
REPO_RAW_BASE="https://raw.githubusercontent.com/HatchetMan111/Career-Ops-Proxmox/main"
GUEST_INSTALL_URL="${REPO_RAW_BASE}/install/career-ops-guest.sh"

CTID="${CTID:-}"
HOSTNAME_="${HOSTNAME:-career-ops}"
CORES="${CORES:-2}"
RAM_MB="${RAM_MB:-2048}"
DISK_GB="${DISK_GB:-8}"
BRIDGE="${BRIDGE:-vmbr0}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
OS_TEMPLATE_PATTERN="debian-12-standard"
UNPRIVILEGED="${UNPRIVILEGED:-1}"
WITH_OLLAMA="${WITH_OLLAMA:-yes}"     # yes|no — install local Ollama in the CT
NONINTERACTIVE="${NONINTERACTIVE:-0}" # 1 = skip whiptail, use env/defaults

# ---------------------------------------------------------------------------
# Logging / error handling — full chain, never just the last line
# ---------------------------------------------------------------------------
LOG_FILE="/tmp/${APP}-install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

msg_info()  { echo -e "\e[36m[INFO]\e[0m  $*"; }
msg_ok()    { echo -e "\e[32m[ OK ]\e[0m  $*"; }
msg_err()   { echo -e "\e[31m[FAIL]\e[0m  $*" >&2; }

on_error() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]:-?}
  local cmd=${BASH_COMMAND:-?}
  msg_err "Installation abgebrochen (Exit-Code $exit_code) in Zeile $line_no"
  msg_err "Fehlgeschlagener Befehl: $cmd"
  msg_err "----- Aufrufkette (Bash call stack) -----"
  local i=0
  while caller $i >&2; do ((i++)); done
  msg_err "------------------------------------------"
  msg_err "Vollständiges Log: $LOG_FILE"
  msg_err "Für ein detailliertes Trace-Log erneut ausführen mit:"
  msg_err "  bash -x $0 2>&1 | tee ${LOG_FILE}.trace"
  exit "$exit_code"
}
trap on_error ERR

require_root() {
  if [[ $EUID -ne 0 ]]; then
    msg_err "Dieses Skript muss als root auf dem Proxmox-Host laufen."
    exit 1
  fi
}

require_pve() {
  if ! command -v pct >/dev/null 2>&1; then
    msg_err "'pct' wurde nicht gefunden — läuft das hier wirklich auf einem Proxmox-VE-Host?"
    exit 1
  fi
}

pick_ctid() {
  if [[ -z "$CTID" ]]; then
    CTID=$(pvesh get /cluster/nextid)
    msg_info "Keine CTID gesetzt, nutze nächste freie ID: $CTID"
  fi
  if pct status "$CTID" &>/dev/null; then
    msg_err "CTID $CTID existiert bereits. Setze CTID=<freie-id> und starte erneut."
    exit 1
  fi
}

ensure_template() {
  msg_info "Prüfe LXC-Template ($OS_TEMPLATE_PATTERN)…"
  pveam update >/dev/null 2>&1 || true
  local tmpl
  tmpl=$(pveam available --section system | awk '{print $2}' | grep "^${OS_TEMPLATE_PATTERN}" | sort -V | tail -n1 || true)
  if [[ -z "$tmpl" ]]; then
    msg_err "Kein Template gefunden, das zu '${OS_TEMPLATE_PATTERN}' passt."
    exit 1
  fi
  if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$tmpl"; then
    msg_info "Lade Template $tmpl herunter…"
    pveam download "$TEMPLATE_STORAGE" "$tmpl"
  fi
  TEMPLATE_PATH="${TEMPLATE_STORAGE}:vztmpl/${tmpl}"
  msg_ok "Template bereit: $TEMPLATE_PATH"
}

interactive_overrides() {
  [[ "$NONINTERACTIVE" == "1" ]] && return 0
  command -v whiptail >/dev/null 2>&1 || { msg_info "whiptail nicht verfügbar, nutze Defaults/ENV-Werte."; return 0; }

  CTID=$(whiptail --inputbox "Container-ID" 8 58 "$CTID" --title "$APP Setup" 3>&1 1>&2 2>&3) || exit 1
  HOSTNAME_=$(whiptail --inputbox "Hostname" 8 58 "$HOSTNAME_" --title "$APP Setup" 3>&1 1>&2 2>&3) || exit 1
  CORES=$(whiptail --inputbox "vCPUs" 8 58 "$CORES" --title "$APP Setup" 3>&1 1>&2 2>&3) || exit 1
  RAM_MB=$(whiptail --inputbox "RAM in MB (Hinweis: Ollama braucht deutlich mehr als 2048!)" 9 66 "$RAM_MB" --title "$APP Setup" 3>&1 1>&2 2>&3) || exit 1
  DISK_GB=$(whiptail --inputbox "Disk in GB" 8 58 "$DISK_GB" --title "$APP Setup" 3>&1 1>&2 2>&3) || exit 1

  if whiptail --yesno "Lokales Ollama im Container installieren?\n(Alternative: später auf externen Ollama-Host zeigen)" 10 66 --title "$APP Setup"; then
    WITH_OLLAMA="yes"
  else
    WITH_OLLAMA="no"
  fi
}

warn_resources() {
  if [[ "$WITH_OLLAMA" == "yes" && "$RAM_MB" -lt 8192 ]]; then
    msg_info "ACHTUNG: Ollama mit brauchbaren Modellen (13B+) braucht realistisch 8-16GB+ RAM."
    msg_info "Mit ${RAM_MB}MB wirst du auf sehr kleine/schwache Modelle beschränkt sein."
    msg_info "Ohne GPU-Passthrough läuft Inferenz zudem auf CPU — erwarte Minuten statt Sekunden pro Bewertung."
  fi
}

create_container() {
  msg_info "Erstelle LXC $CTID ($HOSTNAME_)…"
  pct create "$CTID" "$TEMPLATE_PATH" \
    --hostname "$HOSTNAME_" \
    --cores "$CORES" \
    --memory "$RAM_MB" \
    --swap 512 \
    --rootfs "${STORAGE}:${DISK_GB}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged "$UNPRIVILEGED" \
    --features "nesting=1" \
    --onboot 1 \
    --startup "order=1"
  msg_ok "Container $CTID angelegt."

  msg_info "Starte Container…"
  pct start "$CTID"

  msg_info "Warte auf Netzwerk im Container…"
  local tries=0
  until pct exec "$CTID" -- getent hosts github.com >/dev/null 2>&1; do
    ((tries++))
    if [[ $tries -gt 30 ]]; then
      msg_err "Container hat nach 60s keine funktionierende Netzwerkverbindung."
      exit 1
    fi
    sleep 2
  done
  msg_ok "Netzwerk im Container ist da."
}

run_guest_install() {
  msg_info "Lade Guest-Install-Skript in den Container und führe es aus…"
  pct exec "$CTID" -- bash -c "
    set -e
    apt-get update -y >/dev/null
    apt-get install -y curl ca-certificates >/dev/null
    curl -fsSL '${GUEST_INSTALL_URL}' -o /root/career-ops-guest.sh
    chmod +x /root/career-ops-guest.sh
    WITH_OLLAMA='${WITH_OLLAMA}' REPO_URL='${REPO_URL}' /root/career-ops-guest.sh
  "
}

verify_install() {
  msg_info "Verifiziere Installation…"

  local svc_active
  svc_active=$(pct exec "$CTID" -- systemctl is-active career-ops-web 2>/dev/null || echo "unknown")
  if [[ "$svc_active" == "active" ]]; then
    msg_ok "systemd-Service career-ops-web ist aktiv."
  else
    msg_info "systemd-Service career-ops-web ist Status '$svc_active' (kein Problem, falls keine Web-UI im Repo gefunden wurde — siehe Ausgabe des Guest-Skripts oben)."
  fi

  local ollama_active
  if [[ "$WITH_OLLAMA" == "yes" ]]; then
    ollama_active=$(pct exec "$CTID" -- systemctl is-active ollama 2>/dev/null || echo "unknown")
    if [[ "$ollama_active" == "active" ]]; then
      msg_ok "Ollama-Service ist aktiv."
    else
      msg_err "Ollama-Service ist NICHT aktiv (Status: $ollama_active)."
    fi
  fi

  CT_IP=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
  DETECTED_PORT=$(pct exec "$CTID" -- bash -c "cat /root/.career-ops-web-port 2>/dev/null || true")

  if [[ -n "${DETECTED_PORT:-}" ]]; then
    msg_info "Teste HTTP-Health-Check auf Port ${DETECTED_PORT}…"
    if pct exec "$CTID" -- bash -c "curl -fsS -m 5 http://localhost:${DETECTED_PORT} >/dev/null"; then
      msg_ok "Web-UI antwortet auf http://${CT_IP}:${DETECTED_PORT}"
    else
      msg_err "Web-UI antwortet NICHT auf Port ${DETECTED_PORT} — prüfe 'pct exec ${CTID} -- journalctl -u career-ops-web -n 50'."
    fi
  else
    msg_info "Kein automatisch erkannter Web-UI-Port. career-ops steuerst du in diesem Fall über die AI-CLI im Container (siehe README)."
  fi
}

print_summary() {
  echo
  echo "==================================================================="
  echo " career-ops — Installation abgeschlossen"
  echo "==================================================================="
  echo " Container-ID:   $CTID"
  echo " Hostname:       $HOSTNAME_"
  echo " IP-Adresse:     ${CT_IP:-unbekannt, siehe: pct exec $CTID -- hostname -I}"
  if [[ -n "${DETECTED_PORT:-}" ]]; then
    echo " Web-UI:         http://${CT_IP}:${DETECTED_PORT}"
  else
    echo " Web-UI:         nicht gefunden/aktiviert — Nutzung über AI-CLI:"
    echo "                   pct enter $CTID"
    echo "                   cd /opt/career-ops && opencode ."
  fi
  echo " Ollama:         $( [[ "$WITH_OLLAMA" == "yes" ]] && echo "installiert (systemd: ollama)" || echo "nicht installiert" )"
  echo " Log-Datei:      $LOG_FILE"
  echo "==================================================================="
  echo " WICHTIG:"
  echo " - portals.yml ist LEER. Trage Jobportale erst nach eigener ToS-Prüfung ein:"
  echo "   pct exec $CTID -- nano /opt/career-ops/portals.yml"
  echo " - career-ops sucht keine Jobs von allein. Die eigentliche Pipeline"
  echo "   (Scan/Bewertung/CV-Tailoring) startest du interaktiv über die AI-CLI."
  echo "==================================================================="
}

main() {
  require_root
  require_pve
  interactive_overrides
  pick_ctid
  warn_resources
  ensure_template
  create_container
  run_guest_install
  verify_install
  print_summary
}

main "$@"
