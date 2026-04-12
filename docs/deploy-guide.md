# Guide de deploiement — Proxmox / K3s

Ce document decrit le pipeline complet pour deployer une application sur l'infra K3s, depuis l'analyse du projet jusqu'a la verification en production. Il documente aussi les pieges courants et les conventions obligatoires.

## Table des matieres

- [Architecture reseau](#architecture-reseau)
- [Contraintes et conventions](#contraintes-et-conventions)
- [Pipeline de deploiement](#pipeline-de-deploiement)
  - [1. Analyse du projet](#1-analyse-du-projet)
  - [2. Dockerfile](#2-dockerfile)
  - [3. Manifestes K8s](#3-manifestes-k8s)
  - [4. CI/CD Gitea Actions](#4-cicd-gitea-actions)
  - [5. Route Traefik](#5-route-traefik)
  - [6. Repo Gitea et secrets](#6-repo-gitea-et-secrets)
  - [7. DNS](#7-dns)
  - [8. Verification](#8-verification)
- [Patterns de reference](#patterns-de-reference)
  - [Dockerfile patterns](#dockerfile-patterns)
  - [K8s patterns](#k8s-patterns)
  - [CI patterns](#ci-patterns)
- [Troubleshooting](#troubleshooting)
- [Lecons apprises](#lecons-apprises)

---

## Architecture reseau

```
Internet
    │
    ▼ 51.38.62.199 :80/:443
┌──────────────────────────────────────────┐
│  gateway (10.10.10.2)                    │
│  Traefik v3.4 — reverse proxy + TLS     │
│  Let's Encrypt (certResolver)            │
└────────────┬─────────────────────────────┘
             │ proxy vers NodePorts
             ▼
┌──────────────────────────────────────────┐
│  k3s-master (10.10.10.5)                │
│  K3s control plane                       │
│  NodePorts : 30080-30094                 │
└────────────┬─────────────────────────────┘
             │
┌──────────────────────────────────────────┐
│  k3s-worker (10.10.10.6)                │
│  Pods applicatifs + Act Runner (CI)      │
└──────────────────────────────────────────┘

Autres VMs :
  db (10.10.10.3)     — PostgreSQL 15
  docker (10.10.10.4) — Services legacy + MinIO
```

### IPs et Tailscale

| VM | IP privee | Tailscale | Role |
|---|---|---|---|
| gateway | 10.10.10.2 | 100.106.59.13 | Traefik |
| db | 10.10.10.3 | 100.114.242.60 | PostgreSQL |
| docker | 10.10.10.4 | 100.79.77.93 | Docker legacy |
| k3s-master | 10.10.10.5 | 100.78.207.119 | Control plane |
| k3s-worker | 10.10.10.6 | — | Worker + CI runner |

### NodePorts utilises

| Port | Service |
|---|---|
| 30080 | Gitea |
| 30081 | Douzoute |
| 30082 | Freedge |
| 30083 | Rebours |
| 30094 | We Talk |

Le prochain NodePort disponible : **30095**.

---

## Contraintes et conventions

### 1. Reseau Tailscale

Tous les services internes (Gitea, K3s API, Supabase) sont derriere Tailscale. Ils ne sont **pas accessibles** depuis des environnements externes (CI/CD local sur un runner hors Tailscale, etc.).

Le CI runner Act tourne sur **k3s-worker (10.10.10.6)** qui est sur le reseau prive `10.10.10.0/24` mais **n'est PAS sur Tailscale**. C'est pourquoi le kubeconfig CI doit utiliser l'IP interne.

### 2. SSH

- **Utilisateur** : `arthur` (pas le username macOS local)
- **Acces** : via Tailscale uniquement
- Exemple : `ssh arthur@100.78.207.119`

### 3. Gitea — HTTPS uniquement

Gitea tourne dans K3s — il n'y a pas d'utilisateur unix `git` sur le host. Le SSH `git@git.arthurbarre.fr` ne fonctionne **jamais**.

```bash
# CORRECT
git remote add origin https://git.arthurbarre.fr/ordinarthur/<repo>.git

# INCORRECT — ne fonctionne pas
git remote add origin git@git.arthurbarre.fr:ordinarthur/<repo>.git
```

### 4. Kubeconfig — deux versions

**Usage local** (depuis macOS via Tailscale) :
```bash
mkdir -p ~/.kube
ssh arthur@100.78.207.119 "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed 's/127.0.0.1/100.78.207.119/' > ~/.kube/config
```

**Secret CI Gitea Actions** (`KUBECONFIG`) — doit utiliser l'IP interne `10.10.10.5` car le runner est sur le reseau prive :
```bash
ssh arthur@100.78.207.119 "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed 's/127.0.0.1/10.10.10.5/' | base64 | tr -d '\n'
```

> **Ne jamais utiliser les IPs Tailscale (100.x.x.x) dans le kubeconfig CI** — le runner ne peut pas les atteindre.

### 5. Ansible

Le `ansible.cfg` utilise des chemins relatifs. Toujours lancer depuis le bon repertoire :

```bash
cd ~/dev/perso/proxmox/ansible
ansible-playbook playbooks/gateway.yml
```

Erreurs courantes :
- `ansible-playbook ansible/playbooks/gateway.yml` (depuis la racine du repo) → **role not found**
- `ansible-playbook -i ansible/inventory/hosts ...` → **unable to parse inventory** (le fichier s'appelle `hosts.yml`)

### 6. Token Gitea

- Stocke dans `~/.config/gitea/token`
- Utilise pour : creation de repo, auth registry, configuration des secrets
- L'utilisateur Gitea est `ordinarthur`

---

## Pipeline de deploiement

### 1. Analyse du projet

Avant de generer quoi que ce soit, analyser le projet pour determiner :

| Element | Sources a inspecter |
|---|---|
| **Type** (monolith, fullstack, static, API) | Structure des dossiers |
| **Framework** | `package.json`, `requirements.txt`, `go.mod`, `Cargo.toml` |
| **Package manager** | Presence de `pnpm-lock.yaml`, `yarn.lock`, `package-lock.json` |
| **Port(s)** | `Dockerfile` (EXPOSE), code source (listen), `.env` (PORT) |
| **Health endpoint** | Grep `/health`, `/healthz`, `/readyz` dans le code |
| **Base de donnees** | Prisma, TypeORM, SQLAlchemy, `DATABASE_URL` |
| **Variables d'env** | `.env*`, `process.env.*`, `os.environ` |
| **Build args** | `VITE_*`, `NEXT_PUBLIC_*`, `REACT_APP_*` |
| **Stockage** | multer, uploads, MinIO/S3 client |

Classification :

| Structure | Pattern |
|---|---|
| Racine unique avec `package.json` / `main.py` | Monolith — 1 image |
| `frontend/` + `backend/` | Fullstack — 2 images + nginx proxy |
| Build statique (HTML/CSS/JS) | Static — 1 image nginx |
| Serveur uniquement | API-only — 1 image |

### 2. Dockerfile

Principes :
- Utiliser le **vrai** package manager du projet (npm/pnpm/yarn)
- Utiliser la **vraie** commande de build (`package.json` scripts)
- Pour les SPA/static : multi-stage build → nginx
- Pour les apps avec path aliases (ex: `@/` dans Vite) : **ne pas utiliser `tsc` standalone** dans le Dockerfile, laisser le bundler (Vite/esbuild) gerer la compilation TypeScript
- Ajouter `.npmrc` au `COPY` si le projet en a un (ex: `legacy-peer-deps=true`)
- Toujours generer un `.dockerignore`

Exemple SPA (Vite + React) :
```dockerfile
FROM node:22-alpine AS build
WORKDIR /app
COPY package*.json .npmrc ./
RUN npm ci
COPY . .
ARG VITE_SUPABASE_URL
ARG VITE_SUPABASE_ANON_KEY
RUN ./node_modules/.bin/vite build

FROM nginx:alpine
COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=3s CMD wget -q --spider http://localhost/ || exit 1
CMD ["nginx", "-g", "daemon off;"]
```

### 3. Manifestes K8s

Fichiers a generer dans `k8s/` :

| Fichier | Contenu |
|---|---|
| `namespace.yml` | Namespace dedie |
| `deployment.yml` | Deployment(s) avec probes, resources, imagePullSecrets |
| `service.yml` | Service NodePort |
| `configmap.yml` | Variables non-secretes (si necessaire) |
| `pvc.yml` | PersistentVolumeClaim (si stockage necessaire) |

Points importants :
- `imagePullSecrets: [{name: gitea-registry-secret}]` — toujours inclure
- Les images viennent de `git.arthurbarre.fr/ordinarthur/<app>`
- Health probes sur le vrai endpoint detecte
- Resource limits adaptes au type d'app (voir table ci-dessous)

| Type | CPU req | CPU limit | Mem req | Mem limit |
|---|---|---|---|---|
| Static/SPA | 50m | 200m | 64Mi | 128Mi |
| Node.js API | 100m | 500m | 128Mi | 512Mi |
| Python API | 100m | 500m | 128Mi | 512Mi |
| Go API | 50m | 200m | 32Mi | 128Mi |
| Nginx proxy | 25m | 100m | 32Mi | 64Mi |

### 4. CI/CD Gitea Actions

Workflow dans `.gitea/workflows/deploy.yml`. Structure :

```yaml
name: Build & Deploy to K3s

on:
  push:
    branches: [main]

env:
  REGISTRY: git.arthurbarre.fr
  IMAGE: ordinarthur/<app-name>

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Login to Gitea Registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ordinarthur
          password: ${{ secrets.REGISTRY_PASSWORD }}

      - name: Build and push image
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ env.IMAGE }}:latest
            ${{ env.REGISTRY }}/${{ env.IMAGE }}:${{ github.sha }}

      # CRITIQUE : le runner Act n'a PAS kubectl pre-installe
      - name: Install kubectl
        run: |
          curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
          chmod +x kubectl && mv kubectl /usr/local/bin/kubectl

      - name: Deploy to K3s
        run: |
          mkdir -p ~/.kube
          echo "${{ secrets.KUBECONFIG }}" | base64 -d > ~/.kube/config
          chmod 600 ~/.kube/config

          kubectl apply -f k8s/namespace.yml

          kubectl -n <namespace> create secret docker-registry gitea-registry \
            --docker-server=$REGISTRY \
            --docker-username=ordinarthur \
            --docker-password=${{ secrets.REGISTRY_PASSWORD }} \
            --dry-run=client -o yaml | kubectl apply -f -

          kubectl apply -f k8s/service.yml
          kubectl apply -f k8s/deployment.yml

          kubectl -n <namespace> set image deployment/<app> \
            <app>=$REGISTRY/$IMAGE:${{ github.sha }}

          kubectl -n <namespace> rollout status deployment/<app> --timeout=120s
```

### 5. Route Traefik

Creer un template Jinja2 dans le repo proxmox :

**Fichier** : `ansible/roles/traefik/templates/<app>.yml.j2`

```yaml
http:
  routers:
    <app>:
      rule: "Host(`<domain>`)"
      entryPoints:
        - websecure
      service: <app>
      tls:
        certResolver: letsencrypt

  services:
    <app>:
      loadBalancer:
        servers:
          - url: "http://10.10.10.5:<nodeport>"
```

Ajouter la tache de deploiement dans `ansible/roles/traefik/tasks/main.yml` :

```yaml
- name: Deploy <app> route config
  ansible.builtin.template:
    src: <app>.yml.j2
    dest: /etc/traefik/dynamic/<app>.yml
    owner: root
    group: root
    mode: "0644"
```

Puis deployer :
```bash
cd ~/dev/perso/proxmox/ansible && ansible-playbook playbooks/gateway.yml
```

### 6. Repo Gitea et secrets

```bash
GITEA_TOKEN=$(cat ~/.config/gitea/token)

# Creer le repo
curl -X POST "https://git.arthurbarre.fr/api/v1/user/repos" \
  -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "<app>", "private": false, "auto_init": false}'

# Push (HTTPS uniquement)
git remote add origin https://git.arthurbarre.fr/ordinarthur/<app>.git
git push -u origin main

# Secret: REGISTRY_PASSWORD
curl -X PUT "https://git.arthurbarre.fr/api/v1/repos/ordinarthur/<app>/actions/secrets/REGISTRY_PASSWORD" \
  -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"data\": \"$GITEA_TOKEN\"}"

# Secret: KUBECONFIG (IP interne !)
KUBECONFIG_B64=$(ssh arthur@100.78.207.119 "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed 's/127.0.0.1/10.10.10.5/' | base64 | tr -d '\n')
curl -X PUT "https://git.arthurbarre.fr/api/v1/repos/ordinarthur/<app>/actions/secrets/KUBECONFIG" \
  -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"data\": \"$KUBECONFIG_B64\"}"
```

Secrets supplementaires (selon le projet) : ajouter manuellement dans Gitea → Settings → Actions → Secrets.

### 7. DNS

Ajouter un **A record** chez OVH :

| Type | Nom | Valeur | TTL |
|---|---|---|---|
| A | `<subdomain>` | `51.38.62.199` | 3600 |

Pour un domaine dedie (ex: `freedge.app`), configurer les NS ou A record chez le registrar du domaine.

### 8. Verification

```bash
# HTTP status
curl -s -o /dev/null -w "%{http_code}" https://<domain>/

# Health (si API)
curl -s https://<domain>/health

# TLS
curl -sI https://<domain>/ | grep -i "strict-transport"

# Pods
kubectl -n <namespace> get pods
kubectl -n <namespace> logs <pod>
```

---

## Patterns de reference

### Dockerfile patterns

| Type | Base image build | Base image runtime | Port |
|---|---|---|---|
| SPA / Static | `node:22-alpine` | `nginx:alpine` | 80 |
| Node.js API | `node:20-slim` | `node:20-slim` | 3000 |
| Node.js + Prisma | `node:20-slim` + openssl | `node:20-slim` + openssl | 3000 |
| Python (FastAPI) | `python:3.12-slim` | `python:3.12-slim` | 8000 |
| Go | `golang:1.22-alpine` | `alpine:3.19` | 8080 |

### K8s patterns

**Simple** (1 deployment, 1 service NodePort) : static sites, SPAs, APIs monolithiques.

**Fullstack** (backend + frontend + nginx proxy) : 3 deployments, 2 ClusterIP + 1 NodePort. Le proxy nginx route `/api/*` vers le backend et `/` vers le frontend.

### CI patterns

**Simple** : build 1 image → push → install kubectl → deploy → rollout.

**Fullstack** : build 2 images → push → install kubectl → deploy → rollout 3 deployments.

---

## Troubleshooting

| Symptome | Cause probable | Solution |
|---|---|---|
| `kubectl: command not found` en CI | Act runner n'a pas kubectl | Ajouter step "Install kubectl" |
| `dial tcp 100.x.x.x:6443: i/o timeout` en CI | Kubeconfig utilise IP Tailscale | Regenerer avec IP interne `10.10.10.5` |
| `failed to look up local user git` | Git remote en SSH | Passer en HTTPS |
| `role traefik not found` | Ansible lance depuis le mauvais dossier | `cd ~/dev/perso/proxmox/ansible` |
| `Unable to parse inventory` | Fichier `hosts` au lieu de `hosts.yml` | Utiliser le bon nom de fichier |
| `User arthurbarre not found` sur SSH | Mauvais username | Utiliser `arthur` |
| `npm ci` echoue (peer deps) | `.npmrc` non copie dans Docker | Ajouter `.npmrc` au `COPY` |
| `tsc` ne resout pas `@/` path alias | `baseUrl`/`paths` retires de tsconfig | Ne pas utiliser `tsc` standalone, laisser le bundler gerer |
| `REGISTRY_PASSWORD` manquant en CI | Secret non configure | `curl -X PUT` via API Gitea |
| 502/504 en prod | Traefik ne peut pas atteindre le NodePort | Verifier le service K8s et la route Traefik |
| DNS ne resout pas | A record non propage | Verifier avec `dig <domain>` |

---

## Lecons apprises

Ces points viennent d'erreurs reelles rencontrees lors de deploiements :

1. **Le runner Act n'a rien de pre-installe** — toujours installer les outils necessaires (`kubectl`, etc.) dans le workflow.

2. **Deux kubeconfigs differents** — local (Tailscale IP) vs CI (IP interne). Le runner CI est sur le reseau prive mais pas sur Tailscale.

3. **Gitea = HTTPS only** — le SSH ne marchera jamais car il n'y a pas d'utilisateur `git` unix (Gitea est un pod K3s).

4. **Ansible = chemins relatifs** — toujours lancer depuis `~/dev/perso/proxmox/ansible/`, jamais depuis la racine du repo.

5. **Path aliases TypeScript (`@/`)** — fonctionnent avec Vite (qui les resout via `vite.config.ts`) mais pas avec `tsc` standalone sans `baseUrl`/`paths`. Pour les builds Docker, utiliser uniquement le bundler.

6. **`.npmrc` dans Docker** — si le projet utilise `legacy-peer-deps=true`, il faut copier `.npmrc` avant `npm ci` dans le Dockerfile.

7. **Secrets CI** — `REGISTRY_PASSWORD` et `KUBECONFIG` sont toujours necessaires. Les configurer via l'API Gitea ou l'interface web avant le premier push.
