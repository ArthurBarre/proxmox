# Plan d'adressage IP

## Réseau privé — 10.10.10.0/24 (vmbr1)

| IP | Hostname | Rôle | VM ID | Tailscale |
|---|---|---|---|---|
| 10.10.10.1 | proxmox | Hyperviseur (host) | — | 100.78.114.17 |
| 10.10.10.2 | gateway | Traefik v3.4 (reverse proxy) | 100 | 100.106.59.13 |
| 10.10.10.3 | db | PostgreSQL 15 | 101 | 100.114.242.60 |
| 10.10.10.4 | docker | Docker host (monitoring) | 102 | 100.79.77.93 |
| 10.10.10.5 | k3s-master | K3s control plane | 103 | 100.78.207.119 |
| 10.10.10.6 | k3s-worker | K3s worker + Docker pour Act Runner | 104 | — |
| 10.10.10.7-9 | k3s-worker-N | K3s workers additionnels (réservé) | 105-107 | — |
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
| 30081 | k3s (NodePort) | Douzoute |
| 30082 | k3s (NodePort) | Freedge |
| 30083 | k3s (NodePort) | Rebours |
| 8082 | docker | arthurbarre.fr (portfolio legacy) |
| 30094 | k3s (NodePort) | We Talk |
| 9000-9001 | docker | MinIO (usage interne / admin) |

## Convention de noms de domaine

| Type | Domaine | Exemple | Usage |
|---|---|---|---|
| Outils perso / infra | `*.arthurbarre.fr` | `git.arthurbarre.fr`, `ci.arthurbarre.fr` | Gitea, monitoring, dashboards, outils internes |
| Projets clients / pro | domaine dédié du projet | `rebours.studio` | Sites et apps en production pour des tiers |

### Règle pour le skill de déploiement automatique

Lors du déploiement d'un nouveau service, le skill doit demander (via `AskUserQuestion`) :

- **Projet perso / infra** → sous-domaine de `arthurbarre.fr` (ex: `xxx.arthurbarre.fr`)
- **Projet pro / client** → nom de domaine dédié fourni par le client (ex: `monsite.com`)

### Domaines actifs

| Domaine | Service | Cible |
|---|---|---|
| `rebours.studio` | Site vitrine + API | K3s NodePort (10.10.10.5:30083) |
| `arthurbarre.fr` | Portfolio legacy | VM docker (10.10.10.4:8082) |
| `git.arthurbarre.fr` | Gitea (Git, registry, CI) | K3s NodePort (10.10.10.5:30080) |
| `douzoute.arthurbarre.fr` | Portfolio Douzoute | K3s NodePort (10.10.10.5:30081) |
| `freedge.app` | Freedge | K3s NodePort (10.10.10.5:30082) |
| `we-talk.arthurbarre.fr` | We Talk (podcast communautaire) | K3s NodePort (10.10.10.5:30094) |
