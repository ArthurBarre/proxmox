#!/usr/bin/env python3
"""
Corrige les monitors internes d'Uptime-Kuma : supprime les anciens (Tailscale)
et les recrée avec les IPs LAN 10.10.10.x.
"""
import os
from uptime_kuma_api import UptimeKumaApi, MonitorType

api = UptimeKumaApi("http://100.79.77.93:3001")
api.login("arthurbarre.js@gmail.com", os.environ["KUMA_PWD"])

# Notifier Telegram existant
tg_id = next(n["id"] for n in api.get_notifications() if "Telegram" in n["name"])

# Anciens monitors Tailscale à supprimer
OLD = [
    "Proxmox host (ping)",
    "K3s master (ping)",
    "K3s worker (ping)",
    "DB postgres (ping)",
    "Docker VM (ping)",
    "K3s API (:6443)",
    "Postgres (:5432)",
    "Traefik :443",
]
mons = {m["name"]: m for m in api.get_monitors()}
for name in OLD:
    if name in mons:
        api.delete_monitor(mons[name]["id"])
        print(f"[del] {name}")

# Nouveaux monitors LAN
NEW = [
    ("Gateway Traefik (ping)", "10.10.10.2", None),
    ("DB postgres host (ping)", "10.10.10.3", None),
    ("Docker VM (ping)", "10.10.10.4", None),
    ("K3s master (ping)", "10.10.10.5", None),
    ("K3s worker (ping)", "10.10.10.6", None),
    ("K3s API (:6443)", "10.10.10.5", 6443),
    ("Postgres (:5432)", "10.10.10.3", 5432),
    ("Traefik :443", "10.10.10.2", 443),
]
for name, host, port in NEW:
    if port is None:
        api.add_monitor(type=MonitorType.PING, name=name, hostname=host,
                        interval=60, retryInterval=30, maxretries=2,
                        notificationIDList=[tg_id])
    else:
        api.add_monitor(type=MonitorType.PORT, name=name, hostname=host, port=port,
                        interval=60, retryInterval=30, maxretries=2,
                        notificationIDList=[tg_id])
    print(f"[new] {name} → {host}{':'+str(port) if port else ''}")

api.disconnect()
print("done")
