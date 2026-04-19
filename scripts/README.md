# scripts/

Petits utilitaires d'admin pour l'infra Proxmox/K3s.

## Setup environnement

```bash
cd scripts
python3 -m venv .venv-uptime
.venv-uptime/bin/pip install uptime-kuma-api
```

(Le venv est gitignoré.)

## `setup-uptime-kuma.py`

Configure Uptime-Kuma de manière **idempotente** : crée 19 monitors (HTTP
publics, ping VMs LAN, ports TCP) et un notifier Telegram lié à chaque monitor.
Skip silencieusement les monitors déjà présents.

```bash
KUMA_PWD='<pwd Uptime-Kuma>' \
TG_BOT_TOKEN='<token @BotFather>' \
TG_CHAT_ID='<ton chat_id>' \
.venv-uptime/bin/python setup-uptime-kuma.py
```

**Récupérer le `TG_CHAT_ID`** : envoie `/start` à ton bot, puis :

```bash
curl -s "https://api.telegram.org/bot${TG_BOT_TOKEN}/getUpdates" \
  | jq '.result[].message.chat.id'
```

## `fix-internal-monitors.py`

Migration one-shot : remplace les 8 monitors internes (Proxmox/K3s/Postgres)
qui pointaient sur des IPs Tailscale par les IPs LAN privées 10.10.10.x.
Plus fiable car Uptime-Kuma tourne sur la même VM (10.10.10.4) que le LAN.

```bash
KUMA_PWD='<pwd>' .venv-uptime/bin/python fix-internal-monitors.py
```

À ne pas re-exécuter — gardé pour historique.
