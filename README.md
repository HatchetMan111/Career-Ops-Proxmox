# career-ops auf Proxmox VE

Ein LXC-Installer im Stil der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE/),
für [santifer/career-ops](https://github.com/santifer/career-ops) — jede Person hostet ihre **eigene** Instanz,
keine geteilte Infrastruktur, keine fremden Bewerbungsdaten auf deinem Server.

## Bevor du installierst — bitte lesen

- **career-ops sucht keine Jobs von allein.** Es ist eine Skill-Definition für eine interaktive
  AI-Coding-CLI (Claude Code, Codex, **OpenCode** …). Dieser Installer richtet dir Node.js, OpenCode
  und optional Ollama ein — die eigentliche Pipeline (Scannen, Bewerten, CV anpassen) startest du
  selbst, interaktiv, im Container.
- **`portals.yml` ist leer.** Automatisiertes Abgreifen von Jobportalen kann gegen deren
  Nutzungsbedingungen verstoßen (StepStone, Indeed, Xing, Bundesagentur für Arbeit — jeweils unterschiedlich).
  Das ist eine bewusste, manuelle Entscheidung, die dieses Skript dir nicht abnimmt.
- **Nur das offizielle Repo.** Es kursieren Forks (`career-ops-ui`, `career-ops-hermes` u.ä.) mit
  auffällig professionellem Multi-Sprach-Marketing — typisches Muster für ungeprüfte/SEO-Spam-Forks.
  Dieser Installer klont ausschließlich `github.com/santifer/career-ops`.
- **Ollama = lokale Modell-Qualität, keine Garantie.** Kleinere Open-Weight-Modelle sind bei
  Deutsch-Ausgaben und komplexem Reasoning oft merklich schwächer als Claude/GPT-Klasse. OpenCode
  verlangt laut eigener Doku ein Kontextfenster von 64k+ — viele kleine Modell-Tags liegen darunter.
  Teste selbst, bevor du dich darauf verlässt.
- **Web-UI ist experimentell.** Die native career-ops-Web-UI war zum Zeitpunkt dieses Installers laut
  Roadmap ein Release Candidate. Der Installer versucht, sie automatisch zu erkennen und zu starten;
  falls das fehlschlägt, nutzt du career-ops einfach über die CLI (`opencode .` im Projektordner).
- **Kein echter Deploy-Test in dieser Umgebung.** Die Skripte sind syntaktisch geprüft
  (`bash -n`, ShellCheck, keine Warnungen), aber **nicht** auf einem echten Proxmox-Host installiert
  und rebootet worden — dafür fehlt hier ein echter PVE-Host. Bitte selbst in einer Testumgebung
  verifizieren, bevor produktiv genutzt.

## Installation

Auf dem Proxmox-Host als root:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Career-Ops-Proxmox/main/install/career-ops.sh)"
```

Optional per Umgebungsvariable vorkonfigurieren (überspringt die whiptail-Abfragen für die jeweilige Option):

```bash
CTID=150 HOSTNAME=career-ops-de RAM_MB=8192 WITH_OLLAMA=yes \
  bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Career-Ops-Proxmox/main/install/career-ops.sh)"
```

| Variable | Default | Bedeutung |
|---|---|---|
| `CTID` | nächste freie ID | Proxmox Container-ID |
| `HOSTNAME` | `career-ops` | Hostname im Netz |
| `CORES` | `2` | vCPUs |
| `RAM_MB` | `2048` | RAM in MB — **mit Ollama realistisch 8192+** |
| `DISK_GB` | `8` | Disk in GB |
| `BRIDGE` | `vmbr0` | Netzwerk-Bridge |
| `STORAGE` | `local-lvm` | Storage für Rootfs |
| `WITH_OLLAMA` | `yes` | `yes`/`no` — lokales Ollama installieren |
| `NONINTERACTIVE` | `0` | `1` = keine whiptail-Dialoge, nur ENV/Defaults |

## Nach der Installation

```bash
# In den Container
pct enter <CTID>

# Interaktiv mit career-ops arbeiten
cd /opt/career-ops
opencode .

# Erst NACHDEM du die ToS geprüft hast: Portale eintragen
nano portals.yml

# Falls Ollama installiert: Modell laden (Beispiel)
ollama pull qwen2.5-coder:14b
```

Web-UI (falls vom Installer gefunden): `http://<Container-IP>:3210`
IP herausfinden: `pct exec <CTID> -- hostname -I`

## Update

Kein automatisches Update-Skript enthalten (bewusst — career-ops entwickelt sich schnell,
ein stiller Auto-Pull auf `main` kann deine Konfiguration/Modes brechen). Manuelles Update:

```bash
pct exec <CTID> -- bash -c "cd /opt/career-ops && git fetch --tags && git checkout \$(git tag -l 'v*' --sort=-v:refname | head -1) && npm ci --omit=dev"
pct exec <CTID> -- systemctl restart career-ops-web 2>/dev/null || true
```

## Deinstallation

```bash
pct stop <CTID>
pct destroy <CTID>
```

Das entfernt den kompletten Container inkl. aller lokal gespeicherten Bewerbungsdaten unwiderruflich.

## Dateien in diesem Repo

- `install/career-ops.sh` — läuft auf dem Proxmox-Host, erstellt den LXC (Ziel des Einzeilers)
- `install/career-ops-guest.sh` — läuft im Container, installiert Node/Ollama/career-ops/OpenCode
- `install/career-ops-web.service.template` — Referenz, wie die systemd-Unit aussieht, die
  `career-ops-guest.sh` zur Laufzeit generiert (nur falls eine Web-UI im Repo gefunden wird)
