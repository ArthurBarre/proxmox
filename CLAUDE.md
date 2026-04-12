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

Prochain port dispo : **30094**

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

Services Tailscale-only nécessitent une entrée `/etc/hosts` sur le client :
```
100.106.59.13 grafana.arthurbarre.fr headlamp.arthurbarre.fr ntfy.arthurbarre.fr
```

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
6. Ajouter le DNS chez OVH

## Conventions

- **Images** : toujours pinner une version (pas `:latest`)
- **Secrets** : via `kubectl create secret`, jamais dans les manifests
- **Storage** : `local-path` StorageClass, PVC liés à un node spécifique
- **Réseau** : 10.10.10.0/24 privé, Tailscale 100.64.0.0/10 pour admin
- **Registre** : `git.arthurbarre.fr/<org>/<app>:<tag>` (Gitea Container Registry)

## Terraform

```bash
cd terraform && terraform plan && terraform apply
```

Provider : `bpg/proxmox`, endpoint : `https://100.78.114.17:8006/`
Template VM : ID 9000 (Debian 12 cloud-init)
