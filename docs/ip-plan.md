# Plan d'adressage IP

## Réseau privé — 10.10.10.0/24 (vmbr1)

| IP | Hostname | Rôle | VM ID | Tailscale |
|---|---|---|---|---|
| 10.10.10.1 | proxmox | Hyperviseur (host) | — | 100.78.114.17 |
| 10.10.10.2 | gateway | Traefik v3.4 (reverse proxy) | 100 | 100.106.59.13 |
| 10.10.10.3 | db | PostgreSQL 15 | 101 | 100.114.242.60 |
| 10.10.10.4 | docker | Docker host (rebours.studio, monitoring) | 102 | 100.79.77.93 |
| 10.10.10.5 | k3s-master | K3s control plane | 103 | 100.78.207.119 |
| 10.10.10.6-9 | k3s-worker-N | K3s workers (réservé) | 104-107 | — |
| 10.10.10.10+ | — | VMs à la volée (Terraform) | 110+ | — |

## Ports exposés sur IP publique (51.38.62.199)

| Port | Protocole | Destination | Service |
|---|---|---|---|
| 80 | TCP | → 10.10.10.2:80 | Traefik (HTTP redirect) |
| 443 | TCP | → 10.10.10.2:443 | Traefik (HTTPS) |
| 41641 | UDP | host | Tailscale WireGuard |

## Ports accessibles via Tailscale uniquement

| Port | Machine | Service |
|---|---|---|
| 8006 | proxmox | Interface web Proxmox |
| 22 | toutes | SSH |
| 6443 | k3s-master | API Kubernetes |
| 8080 | gateway | Dashboard Traefik |
| 5432 | db | PostgreSQL |
| 3001 | docker | Uptime Kuma |
| 30080 | k3s (NodePort) | Gitea |

## Convention de noms de domaine

| Type | Domaine | Exemple | Usage |
|---|---|---|---|
| Outils perso / infra | `*.arthurbarre.fr` | `git.arthurbarre.fr`, `ci.arthurbarre.fr` | Gitea, monitoring, dashboards, outils internes |
| Projets clients / pro | domaine dédié du projet | `rebours.studio`, `aureliebarre.fr` | Sites et apps en production pour des tiers |

### Règle pour le skill de déploiement automatique

Lors du déploiement d'un nouveau service, le skill doit demander (via `AskUserQuestion`) :

- **Projet perso / infra** → sous-domaine de `arthurbarre.fr` (ex: `xxx.arthurbarre.fr`)
- **Projet pro / client** → nom de domaine dédié fourni par le client (ex: `monsite.com`)

### Domaines actifs

| Domaine | Service | Cible |
|---|---|---|
| `rebours.studio` | Site vitrine + API | VM docker (10.10.10.4:8080 / :3000) |
| `git.arthurbarre.fr` | Gitea (Git, registry, CI) | K3s NodePort (10.10.10.5:30080) |
| `aureliebarre.fr` | Portfolio Aurélie | K3s NodePort (10.10.10.5:30081) |
