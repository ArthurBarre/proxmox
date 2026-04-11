# Production State — 11 avril 2026

Cette page documente l'état réel constaté sur l'infra live afin d'aligner la
doc du repo avec ce qui tourne effectivement sur le Proxmox.

## VMs actives

| VM ID | Nom | IP privée | Rôle |
|---|---|---|---|
| 100 | gateway | 10.10.10.2 | Traefik public |
| 101 | db | 10.10.10.3 | PostgreSQL 15 |
| 102 | docker | 10.10.10.4 | Services legacy Docker |
| 103 | k3s-master | 10.10.10.5 | Control plane K3s |
| 104 | k3s-worker | 10.10.10.6 | Worker K3s + Act Runner |

## Services K3s actifs

| Namespace | Service | Exposition |
|---|---|---|
| `gitea` | Gitea | NodePort `30080` |
| `gitea` | Gitea SSH | NodePort `30022` |
| `portfolio` | Douzoute | NodePort `30081` |
| `freedge` | Freedge proxy | NodePort `30082` |

## Services Docker actifs sur la VM `docker`

| Service | Port | Statut |
|---|---|---|
| `rebours-nginx` | `8080` | actif |
| `rebours-app` | `3000` | actif |
| `portfolio-web` | `8082` | actif |
| `uptime-kuma` | `3001` | actif |
| `minio` | `9000-9001` | actif |

## Routes Traefik observées sur la gateway

### Codifiées dans ce repo

- `rebours.studio` → `10.10.10.4:8080` / `:3000`
- `git.arthurbarre.fr` → `10.10.10.5:30080`
- `douzoute.arthurbarre.fr` → `10.10.10.5:30081`
- `freedge.app` → `10.10.10.5:30082`
- `arthurbarre.fr` → `10.10.10.4:8082`

### Dérive live constatée

La gateway contient encore un fichier dynamique manuel `douzoute.yml` qui
pointe vers l'ancien service Docker `10.10.10.4:8083`. Ce service n'existe plus.

La source de vérité souhaitée est désormais :

- `aurelie.yml.j2` pour `douzoute.arthurbarre.fr` → K3s `30081`
- aucune dépendance Docker restante pour `douzoute`

Un prochain passage de ménage infra pourra supprimer ce fichier live obsolète
du host gateway.

## Modèle de déploiement actuel

- nouvelles apps : repo Gitea + Gitea Actions + K3s
- repo `proxmox` : infra, routes gateway, doc, runbooks
- VM docker : hébergement des services legacy non encore migrés

## Exemple live : freedge

- domaine : `freedge.app`
- app repo : `ordinarthur/freedge`
- images :
  - `git.arthurbarre.fr/ordinarthur/freedge-backend`
  - `git.arthurbarre.fr/ordinarthur/freedge-frontend`
- namespace : `freedge`
- base PostgreSQL : `freedge`
- NodePort : `30082`
- gateway Traefik : `/etc/traefik/dynamic/freedge.yml`
