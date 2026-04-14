# Proxmox Infrastructure — Context

## Architecture

```
Internet :443/:80 → Proxmox (51.38.62.199) → Gateway VM (Traefik) → K3s NodePorts
```

Hôte Proxmox : `ns3142338` — SSH via `ssh root@100.78.114.17` (Tailscale)

## VMs

| VM ID | Nom | IP privée | IP Tailscale | Rôle | RAM | Disque |
|-------|-----|-----------|--------------|------|-----|--------|
| 100 | gateway | 10.10.10.2 | 100.106.59.13 | Traefik reverse proxy | 1G | 10G |
| 101 | db | 10.10.10.3 | 100.114.242.60 | PostgreSQL 15 | 2G | 30G |
| 102 | docker | 10.10.10.4 | 100.79.77.93 | Docker legacy (portfolio, uptime-kuma) | 4G | 40G |
| 103 | k3s-master | 10.10.10.5 | 100.78.207.119 | K3s control plane | 4G | 30G |
| 104 | k3s-worker | 10.10.10.6 | 100.121.251.87 | K3s worker node | 4G | 30G |

## Accès SSH

- **Depuis le Mac** : `ssh arthur@<IP_TAILSCALE>` (toutes les VMs sauf Proxmox)
- **Proxmox hôte** : `ssh root@100.78.114.17`
- **Worker depuis Proxmox** : `ssh root@100.78.114.17` puis `ssh arthur@10.10.10.6`
- **Clés SSH** : authentification par clé uniquement, pas de mot de passe
- **User** : `arthur` sur toutes les VMs, `root` ou `ordinarthur` sur l'hôte Proxmox

## Kubectl

```bash
kubectl --kubeconfig k3s/kubeconfig.yaml <commande>
# ou
export KUBECONFIG=$(pwd)/k3s/kubeconfig.yaml
```

## Ansible

Toujours lancer depuis le dossier `ansible/` :
```bash
cd ansible && ansible-playbook playbooks/<playbook>.yml
```

Playbooks disponibles : `site.yml` (tout), `base.yml`, `gateway.yml`, `db.yml`, `docker.yml`, `k3s.yml`, `monitoring.yml`

## NodePorts

| Port | Service | Namespace |
|------|---------|-----------|
| 30022 | Gitea SSH | gitea |
| 30080 | Gitea HTTP | gitea |
| 30081 | Douzoute (portfolio) | portfolio |
| 30082 | Freedge | freedge |
| 30083 | Rebours | rebours |
| 30090 | Headlamp | headlamp |
| 30091 | Grafana | monitoring |
| 30092 | Ntfy | monitoring |
| 30093 | Loki | monitoring |
| 30094 | Supabase Kong (API) | supabase |
| 30095 | Supabase Studio | supabase |
| 30096 | We Talk | wetalk |
| 30097 | AnyDrop | anydrop |

Prochain port dispo : **30098**

## Domaines & Traefik

| Domaine | Destination | Accès |
|---------|-------------|-------|
| `git.arthurbarre.fr` | 10.10.10.5:30080 | Public (rate-limit) |
| `freedge.app` | 10.10.10.5:30082 | Public (rate-limit) |
| `rebours.studio` | 10.10.10.5:30083 | Public (rate-limit) |
| `douzoute.arthurbarre.fr` | 10.10.10.5:30081 | Public (rate-limit) |
| `arthurbarre.fr` | 10.10.10.4:8082 | Public (rate-limit, Docker legacy) |
| `grafana.arthurbarre.fr` | 10.10.10.5:30091 | Tailscale only |
| `headlamp.arthurbarre.fr` | 10.10.10.5:30090 | Tailscale only |
| `ntfy.arthurbarre.fr` | 10.10.10.5:30092 | Tailscale only |
| `supabase.arthurbarre.fr` | 10.10.10.5:30094 | Public (rate-limit) |
| `studio.supabase.arthurbarre.fr` | 10.10.10.5:30095 | Tailscale only |
| `we-talk.arthurbarre.fr` | 10.10.10.5:30096 | Public (rate-limit) |
| `anydrop.arthurbarre.fr` | 10.10.10.5:30097 | Public (rate-limit) |

Traefik config : `ansible/roles/traefik/templates/`
Dashboard Traefik : `100.106.59.13:8080` (Tailscale uniquement)

## Stack Monitoring

- **Prometheus** : collecte métriques (ClusterIP interne)
- **Grafana** : dashboards (ID 1860 = Node Exporter, ID 15759 = K8s overview)
- **AlertManager** : règles d'alerte → Ntfy
- **Ntfy** : push notifications iPhone
- **Node Exporter** : DaemonSet K8s + service systemd sur gateway/db/docker
- **kube-state-metrics** : métriques K8s
- **Loki + Promtail** : centralisation des logs

## Déploiement d'une nouvelle app

1. Créer les manifests dans `k3s/manifests/<namespace>/` (namespace, deployment, service NodePort, pvc si besoin)
2. Créer la route Traefik dans `ansible/roles/traefik/templates/<app>.yml.j2`
3. Ajouter la tâche de déploiement dans `ansible/roles/traefik/tasks/main.yml`
4. `kubectl apply -f k3s/manifests/<namespace>/ --kubeconfig k3s/kubeconfig.yaml`
5. `cd ansible && ansible-playbook playbooks/gateway.yml`
6. Créer le DNS via l'API OVH (automatisé, voir ci-dessous)

## Gitea API (repos + Actions secrets)

Token stocké dans `~/.config/gitea/token` (raw token, une ligne). Registry password pour le CI : `source <proxmox-repo>/.secrets` → exporte `REGISTRY_PASSWORD`.

```bash
GITEA_TOKEN=$(cat ~/.config/gitea/token)
# Créer un repo
curl -s -X POST "https://git.arthurbarre.fr/api/v1/user/repos" \
  -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"<app>","private":false,"auto_init":false}'
# Ajouter un secret Actions
curl -s -X PUT "https://git.arthurbarre.fr/api/v1/repos/ordinarthur/<app>/actions/secrets/<NAME>" \
  -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" \
  -d "{\"data\":\"$VALUE\"}"
```

## KUBECONFIG pour le CI

Le Act Runner tourne sur la VM worker et doit joindre l'API K3s via l'IP interne (pas `127.0.0.1`). Récupération automatisée :

```bash
KUBECONFIG_B64=$(ssh arthur@100.78.207.119 "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed 's/127.0.0.1/10.10.10.5/' | base64)
# Puis push dans le secret Gitea KUBECONFIG (voir ci-dessus)
```

Premier SSH Tailscale de la session peut demander une auth navigateur — une fois validé, les appels suivants sont passwordless.

## OVH DNS API

Credentials stockés dans `~/.config/ovh/credentials.env` (Application Key, Secret, Consumer Key).

Création automatique d'un A record :
```bash
source ~/.config/ovh/credentials.env
ZONE="arthurbarre.fr" SUBDOMAIN="<sub>" TARGET="51.38.62.199"
METHOD="POST" URL="https://eu.api.ovh.com/1.0/domain/zone/$ZONE/record"
BODY="{\"fieldType\":\"A\",\"subDomain\":\"$SUBDOMAIN\",\"target\":\"$TARGET\",\"ttl\":3600}"
TSTAMP=$(date +%s)
SIG="\$1\$$(printf "${OVH_APPLICATION_SECRET}+${OVH_CONSUMER_KEY}+${METHOD}+${URL}+${BODY}+${TSTAMP}" | shasum -a 1 | cut -d' ' -f1)"
curl -s -X POST -H "Content-Type: application/json" \
  -H "X-Ovh-Application: $OVH_APPLICATION_KEY" -H "X-Ovh-Timestamp: $TSTAMP" \
  -H "X-Ovh-Signature: $SIG" -H "X-Ovh-Consumer: $OVH_CONSUMER_KEY" \
  -d "$BODY" "$URL"
# Puis refresh la zone (même pattern avec POST /domain/zone/$ZONE/refresh)
```

## Conventions

- **Images** : toujours pinner une version (pas `:latest`)
- **Secrets** : via `kubectl create secret`, jamais dans les manifests
- **Storage** : `local-path` StorageClass, PVC liés à un node spécifique
- **Réseau** : 10.10.10.0/24 privé, Tailscale 100.64.0.0/10 pour admin
- **Registre** : `git.arthurbarre.fr/<org>/<app>:<tag>` (Gitea Container Registry)

## Supabase (self-hosted)

Namespace `supabase` — basé sur [supabase-community/supabase-kubernetes](https://github.com/supabase-community/supabase-kubernetes)

**Services** : PostgreSQL, Auth (GoTrue), PostgREST, Realtime, Storage, Imgproxy, Meta (pg-meta), Kong (API gateway), Studio

**Manifests** : `k3s/manifests/supabase/`

**Secrets** : `supabase-secrets` (généré via `k3s/manifests/supabase/generate-secrets.sh`)
- `jwt-secret`, `anon-key`, `service-role-key`, `postgres-password`, `postgrest-db-uri`, `auth-db-uri`, `storage-db-uri`, `secret-key-base`, `google-oauth-secret`

**DB superuser** : `supabase_admin` (pas `postgres`)

**Google OAuth** : configuré via GoTrue (`GOTRUE_EXTERNAL_GOOGLE_*`), Client ID Google Cloud Console projet We Talk, redirect URI `https://supabase.arthurbarre.fr/auth/v1/callback`

**Accès** :
- API publique : `https://supabase.arthurbarre.fr` (Kong, NodePort 30094)
- Studio : `https://studio.supabase.arthurbarre.fr` (Tailscale only, NodePort 30095)

## Terraform

```bash
cd terraform && terraform plan && terraform apply
```

Provider : `bpg/proxmox`, endpoint : `https://100.78.114.17:8006/`
Template VM : ID 9000 (Debian 12 cloud-init)
