# Production State — 21 avril 2026

Cette page documente l'état réel constaté sur l'infra live afin d'aligner la
doc du repo avec ce qui tourne effectivement sur le Proxmox.

## VMs actives

| VM ID | Nom | IP privée | RAM | CPU | Disque | Rôle |
|---|---|---|---|---|---|---|
| 100 | gateway | 10.10.10.2 | 1 Go | 1 | 10 Go | Traefik public |
| 101 | db | 10.10.10.3 | 2 Go | 2 | 30 Go | PostgreSQL 15 |
| 102 | docker | 10.10.10.4 | 4 Go | 2 | 40 Go | Services legacy Docker |
| 103 | k3s-master | 10.10.10.5 | 4 Go | 2 | 30 Go | Control plane K3s + workloads |
| 104 | k3s-worker | 10.10.10.6 | **8 Go** (+ 2 Go swap) | 2 | — | Worker K3s + Gitea + Act Runner |

> **Note RAM worker** : bumpée de 4 Go → 8 Go le 21 avril 2026 suite à un OOM
> kill du pod Gitea pendant un build CI (voir section "Incidents" plus bas).
> Ballooning désactivé (`--balloon 0`) pour garantir les 8 Go en permanence.

## Services K3s actifs

| Namespace | Service | Exposition |
|---|---|---|
| `gitea` | Gitea | NodePort `30080` |
| `gitea` | Gitea SSH | NodePort `30022` |
| `portfolio` | Douzoute | NodePort `30081` |
| `freedge` | Freedge proxy | NodePort `30082` |
| `rebours` | Rebours (SSR + API + proxy) | NodePort `30083` |
| `wetalk` | We Talk (podcast communautaire) | NodePort `30094` |
| `anydrop` | AnyDrop (partage P2P) | NodePort `30097` |

## Services Docker actifs sur la VM `docker`

| Service | Port | Statut |
|---|---|---|
| `portfolio-web` | `8082` | actif |
| `uptime-kuma` | `3001` | actif |
| `minio` | `9000-9001` | actif |

## Routes Traefik observées sur la gateway

### Codifiées dans ce repo

- `rebours.studio` → K3s `10.10.10.5:30083`
- `git.arthurbarre.fr` → `10.10.10.5:30080`
- `douzoute.arthurbarre.fr` → `10.10.10.5:30081`
- `freedge.app` → `10.10.10.5:30082`
- `arthurbarre.fr` → `10.10.10.4:8082`
- `we-talk.arthurbarre.fr` → K3s `10.10.10.5:30094`
- `anydrop.arthurbarre.fr` → K3s `10.10.10.5:30097`

### Dérive live constatée

La gateway contient encore un fichier dynamique manuel `douzoute.yml` qui
pointe vers l'ancien service Docker `10.10.10.4:8083`. Ce service n'existe plus.

La source de vérité souhaitée est désormais :

- `aurelie.yml.j2` pour `douzoute.arthurbarre.fr` → K3s `30081`
- aucune dépendance Docker restante pour `douzoute`

Un prochain passage de ménage infra pourra supprimer ce fichier live obsolète
du host gateway.

## Accès et conventions opérationnelles

### SSH

- **Utilisateur SSH sur toutes les VMs** : `arthur` (PAS le username macOS local)
- **Accès** : via Tailscale uniquement (IPs `100.x.x.x`)
- Exemple : `ssh arthur@100.78.207.119` (k3s-master)

### Gitea (git.arthurbarre.fr)

- **Git push/pull** : utiliser **HTTPS** (pas SSH `git@`)
  - `git remote add origin https://git.arthurbarre.fr/ordinarthur/<repo>.git`
  - Le SSH `git@git.arthurbarre.fr` ne fonctionne PAS (Gitea tourne en K3s, pas de user `git` sur le host)
- **Registry Docker** : `git.arthurbarre.fr/ordinarthur/<image>`
- **Token API** : stocké dans `~/.config/gitea/token`
- **Utilisateur** : `ordinarthur`

### Kubeconfig

- Le kubeconfig n'est **PAS stocké en local** par défaut
- Pour le récupérer :
  ```bash
  mkdir -p ~/.kube
  ssh arthur@100.78.207.119 "sudo cat /etc/rancher/k3s/k3s.yaml" | sed 's/127.0.0.1/100.78.207.119/' > ~/.kube/config
  ```
- Pour l'encoder en base64 (secret Gitea Actions) : `cat ~/.kube/config | base64`

### Ansible

- **Dossier de travail obligatoire** : `~/dev/perso/proxmox/ansible/`
  - Le `ansible.cfg` utilise des chemins relatifs (`inventory = inventory/hosts.yml`, `roles_path = roles`)
  - Lancer les playbooks **depuis ce dossier** : `cd ~/dev/perso/proxmox/ansible && ansible-playbook playbooks/gateway.yml`
- **Inventaire** : `inventory/hosts.yml` (PAS `hosts`)

### Réseau depuis Claude Code

- Les services internes (Gitea, Supabase, K3s) sont sur le réseau Tailscale et **ne sont PAS accessibles depuis Claude Code**
- Les opérations réseau (git push, curl vers Gitea/Supabase, kubectl) doivent être exécutées **manuellement par l'utilisateur**
- Le skill deploy doit générer les commandes et les présenter à l'utilisateur, sans tenter de les exécuter

## Incidents et runbooks

### 21 avril 2026 — OOM kill sur k3s-worker

**Symptôme** : `git.arthurbarre.fr` retourne 502 Bad Gateway, `kubectl get nodes`
montre `k3s-worker NotReady`. SSH vers le worker timeout.

**Cause racine** : pression mémoire — la VM avait 4 Go RAM sans swap. Le build
Docker d'une image CI (Next.js + Payload) a fait déborder la RAM. OOM killer a
tué le pod Gitea, puis systemd-logind est devenu indisponible, et kubelet a
arrêté de poster son status au master.

**Résolution** :
1. `ssh arthur@100.78.207.119 "sudo kubectl cordon k3s-worker && sudo kubectl drain k3s-worker --ignore-daemonsets --delete-emptydir-data --force"`
2. `ssh root@100.78.114.17 "qm reset 104"` (hard reset, guest agent down)
3. `ssh root@100.78.114.17 "qm set 104 --memory 8192 --balloon 0"` + redémarrage
4. Ajout de 2 Go swap sur le worker (`/swapfile` persisté dans `/etc/fstab`)
5. `sudo kubectl uncordon k3s-worker`

**Prévention** : le worker a maintenant 8 Go + 2 Go swap. Pour éviter le retour
du problème, ajouter des `resources.limits.memory` sur les pods gros consommateurs
(Gitea, Act Runner) reste recommandé.

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
