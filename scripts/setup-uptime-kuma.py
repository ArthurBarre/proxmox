#!/usr/bin/env python3
"""
Configuration idempotente d'Uptime-Kuma : monitors pour toute l'infra + notifier
Telegram.

Usage :
  KUMA_PWD='...' TG_BOT_TOKEN='...' TG_CHAT_ID='...' python3 setup-uptime-kuma.py

Variables d'env requises :
  KUMA_PWD     mot de passe Uptime-Kuma (user arthurbarre.js@gmail.com)
  TG_BOT_TOKEN token bot Telegram (créé via @BotFather, finit par _bot)
  TG_CHAT_ID   chat_id Telegram du destinataire (récup via /getUpdates)

- Se connecte à http://100.79.77.93:3001 (Tailscale ou LAN)
- Crée/met à jour le notifier Telegram
- Crée/met à jour les monitors listés ci-dessous (idempotent : skip si présent).
"""
import os
import sys
from uptime_kuma_api import UptimeKumaApi, MonitorType, NotificationType

KUMA_URL = os.environ.get("KUMA_URL", "http://100.79.77.93:3001")
KUMA_USER = os.environ.get("KUMA_USER", "arthurbarre.js@gmail.com")
KUMA_PWD = os.environ["KUMA_PWD"]

TG_BOT_TOKEN = os.environ["TG_BOT_TOKEN"]
TG_CHAT_ID = os.environ["TG_CHAT_ID"]

# Intervalle : 60s, retry 2x, up-after 1 check (notif ASAP)
DEFAULT_INTERVAL = 60
DEFAULT_RETRY = 2
DEFAULT_RETRY_INTERVAL = 30

# --- monitors ---------------------------------------------------------------
# HTTP monitors (public domains)
HTTP_MONITORS = [
    # name, url, accepted_statuses, max_redirects
    ("PWA — os.arthurbarre.fr", "https://os.arthurbarre.fr/", ["200-299"], 3),
    ("API — api.os.arthurbarre.fr/health", "https://api.os.arthurbarre.fr/health", ["200-299"], 0),
    ("Gitea — git.arthurbarre.fr", "https://git.arthurbarre.fr/", ["200-299"], 3),
    ("Rebours — rebours.studio", "https://rebours.studio/", ["200-299"], 3),
    ("Freedge — freedge.app", "https://freedge.app/", ["200-299"], 3),
    ("Portfolio — arthurbarre.fr", "https://arthurbarre.fr/", ["200-299"], 3),
    ("Douzoute — douzoute.arthurbarre.fr", "https://douzoute.arthurbarre.fr/", ["200-299"], 3),
    ("WeTalk — we-talk.arthurbarre.fr", "https://we-talk.arthurbarre.fr/", ["200-299"], 3),
    ("AnyDrop — anydrop.arthurbarre.fr", "https://anydrop.arthurbarre.fr/", ["200-299"], 3),
    ("Supabase API — supabase.arthurbarre.fr", "https://supabase.arthurbarre.fr/rest/v1/", ["200-299","300-399","400-499"], 0),
    ("Uptime-Kuma (self) — uptime.arthurbarre.fr", "https://uptime.arthurbarre.fr/", ["200-299","300-399","401","403"], 3),
]

# Port/keyword monitors via LAN interne 10.10.10.0/24
# (Uptime-Kuma tourne sur la VM Docker 10.10.10.4 qui est sur le même LAN)
PORT_MONITORS = [
    # name, hostname, port
    ("Gateway Traefik (ping)", "10.10.10.2", None),
    ("DB postgres host (ping)", "10.10.10.3", None),
    ("Docker VM (ping)", "10.10.10.4", None),
    ("K3s master (ping)", "10.10.10.5", None),
    ("K3s worker (ping)", "10.10.10.6", None),
    ("K3s API (:6443)", "10.10.10.5", 6443),
    ("Postgres (:5432)", "10.10.10.3", 5432),
    ("Traefik :443", "10.10.10.2", 443),
]

# --- cert expiry monitors (via HTTP monitors using certExpiryNotification) ---
# Uptime-Kuma inclut nativement le monitoring de cert expiry sur tous les
# monitors HTTP(S). On active les alertes sur expiration.

# ---------------------------------------------------------------------------

def main() -> int:
    print(f"[kuma] connexion à {KUMA_URL}")
    api = UptimeKumaApi(KUMA_URL)
    api.login(KUMA_USER, KUMA_PWD)
    print("[kuma] login OK")

    # 1) Telegram notifier --------------------------------------------------
    existing_notifs = {n["name"]: n for n in api.get_notifications()}
    TG_NAME = "Telegram — Arthur infra alerts"
    if TG_NAME in existing_notifs:
        print(f"[notif] '{TG_NAME}' existe déjà (id={existing_notifs[TG_NAME]['id']})")
        tg_id = existing_notifs[TG_NAME]["id"]
    else:
        res = api.add_notification(
            name=TG_NAME,
            type=NotificationType.TELEGRAM,
            isDefault=True,
            applyExisting=True,
            telegramBotToken=TG_BOT_TOKEN,
            telegramChatID=TG_CHAT_ID,
        )
        tg_id = res["id"]
        print(f"[notif] '{TG_NAME}' créé (id={tg_id})")

    # 2) Monitors HTTP ------------------------------------------------------
    existing_mons = {m["name"]: m for m in api.get_monitors()}
    created, skipped = 0, 0

    for name, url, codes, max_redirects in HTTP_MONITORS:
        if name in existing_mons:
            skipped += 1
            continue
        api.add_monitor(
            type=MonitorType.HTTP,
            name=name,
            url=url,
            interval=DEFAULT_INTERVAL,
            retryInterval=DEFAULT_RETRY_INTERVAL,
            maxretries=DEFAULT_RETRY,
            accepted_statuscodes=codes,
            maxredirects=max_redirects,
            notificationIDList=[tg_id],
            expiryNotification=True,  # alerte cert SSL
            ignoreTls=False,
        )
        created += 1
        print(f"[http]  + {name}")

    # 3) Monitors ping / port ----------------------------------------------
    for name, host, port in PORT_MONITORS:
        if name in existing_mons:
            skipped += 1
            continue
        if port is None:
            api.add_monitor(
                type=MonitorType.PING,
                name=name,
                hostname=host,
                interval=DEFAULT_INTERVAL,
                retryInterval=DEFAULT_RETRY_INTERVAL,
                maxretries=DEFAULT_RETRY,
                notificationIDList=[tg_id],
            )
        else:
            api.add_monitor(
                type=MonitorType.PORT,
                name=name,
                hostname=host,
                port=port,
                interval=DEFAULT_INTERVAL,
                retryInterval=DEFAULT_RETRY_INTERVAL,
                maxretries=DEFAULT_RETRY,
                notificationIDList=[tg_id],
            )
        created += 1
        print(f"[net]   + {name}")

    print(f"\n[done] créés={created} déjà-là={skipped}")
    api.disconnect()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyError as e:
        print(f"ERR: variable d'env manquante: {e}", file=sys.stderr)
        sys.exit(2)
    except Exception as e:
        print(f"ERR: {e}", file=sys.stderr)
        sys.exit(1)
