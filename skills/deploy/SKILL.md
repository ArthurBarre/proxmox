---
name: deploy
description: "Automated deployment pipeline for Arthur's Proxmox/K3s infrastructure. Use this skill whenever the user wants to deploy an app, set up CI/CD, create Kubernetes manifests, configure Traefik routing, or push a project to production on the K3s cluster. Triggers on: 'deploy', 'mise en prod', 'deployer', 'k8s setup', 'create deployment', 'push to production', 'configurer le CI/CD', 'ajouter une app sur le cluster'. This skill handles the FULL deployment lifecycle: project analysis, Dockerfile creation, K8s manifests, Gitea repo + CI, Traefik route, DNS, and health verification."
---

# Deploy — Full-Stack Deployment on Proxmox/K3s

This skill automates the entire deployment pipeline for Arthur's infrastructure. It intelligently analyzes ANY project — regardless of language, framework, or structure — and generates everything needed to deploy it on the K3s cluster with CI/CD via Gitea Actions.

The skill adapts itself to the project. It does not follow a rigid template — it reads the actual code, understands the architecture, and produces deployment configs that match exactly what the project needs.

## Infrastructure Context

- **K3s master**: 10.10.10.5 (NodePorts for external access)
- **K3s worker**: 10.10.10.6 (Docker + Act Runner for CI)
- **Traefik gateway**: 10.10.10.2 (reverse proxy, Let's Encrypt)
- **PostgreSQL**: 10.10.10.3 (shared database server)
- **Gitea**: git.arthurbarre.fr (registry + CI/CD, user: ordinarthur)
- **Public IP**: 51.38.62.199 (ports 80/443 → Traefik)
- **Used NodePorts**: see `docs/ip-plan.md` for the current list — pick the next free one, never reuse

## Guardrails — actions interdites sans validation humaine

Ce skill déploie des apps. Il ne fait **PAS** d'ops sur l'infrastructure existante. Les actions suivantes sont **strictement interdites** sans que l'utilisateur les demande explicitement et confirme, même si elles semblent résoudre un problème :

**Jamais toucher au runtime d'un nœud K3s ou d'une VM :**
- Pas de modification de `/etc/docker/daemon.json`, `/etc/containerd/config.toml`, `/etc/systemd/resolved.conf`, `/etc/resolv.conf`, `/etc/hosts`
- Pas de `systemctl restart docker|containerd|k3s|k3s-agent|kubelet|networking` sur un nœud
- Pas de redémarrage de VM (`qm reboot`, `qm stop`, `shutdown`, `reboot`)
- Pas de modification de la config réseau d'un nœud (routes, iptables, nftables, firewall)
- Pas de modification de la config Tailscale

**Jamais utiliser un pod privilégié pour sortir du sandbox :**
- Pas de `securityContext: privileged: true` pour faire du `nsenter` / `chroot /host`
- Pas de `hostPath` monté sur `/`, `/etc`, `/var/run/docker.sock`, `/run/containerd`
- Pas de pods créés ad-hoc pour exécuter des commandes sur l'hôte
- Ces patterns existent pour des outils comme `node-problem-detector` — pas pour du debug improvisé

**Jamais faire de diagnostic spéculatif appliqué :**
- Une hypothèse de fix ≠ un fix. Si la cause n'est pas prouvée par des logs concrets, on ne touche à rien.
- En particulier : "le CI échoue en 10s donc c'est un pb de DNS" → c'est une hypothèse, pas un diagnostic. 10s peut venir de 100 causes (auth registry, image manquante, syntaxe workflow, permission kubeconfig, etc.).

**Règle d'escalade :** dès qu'un problème sort du périmètre "mon app ne build pas / mon manifest est invalide", on **s'arrête**, on présente les logs + l'hypothèse à l'utilisateur, et on attend une décision. L'infra partagée (K3s, Traefik, VMs, DNS, Tailscale) n'est jamais modifiée en autonomie pour "débloquer" un déploiement.

**Si une action interdite semble nécessaire :** ce n'est pas le problème du skill `deploy`. Documenter le symptôme, lister les hypothèses, proposer à l'utilisateur d'intervenir.

## Debug d'un CI Gitea qui échoue — playbook obligatoire

Dans l'ordre strict, sans sauter d'étape :

1. **Lire les logs du run.** `curl -s -H "Authorization: token $GITEA_TOKEN" https://git.arthurbarre.fr/api/v1/repos/ordinarthur/<app>/actions/tasks` puis récupérer les logs du job. Ou demander à l'utilisateur d'ouvrir `https://git.arthurbarre.fr/ordinarthur/<app>/actions` et coller les logs.
2. **Classer l'erreur.** Trois catégories, trois traitements :
   - **Syntaxe / workflow / Dockerfile / manifests** → c'est dans le repo de l'app, on corrige et on repush. Périmètre autorisé.
   - **Auth / secrets manquants** (`unauthorized`, `401`, `no such secret`) → vérifier les secrets Gitea via API, re-setter si besoin. Périmètre autorisé.
   - **Infra** (runner offline, network, DNS, registry unreachable, kubeconfig invalide) → **STOP**. Présenter le diagnostic à l'utilisateur. Ne rien modifier sur les nœuds.
3. **Avant toute hypothèse, vérifier le runner.** `kubectl --kubeconfig <cfg> get pods -A | grep runner` ou logs du service Act Runner. Si le runner est down, c'est une affaire d'ops, pas de déploiement.
4. **Reproduire localement si possible.** `docker build -f server/Dockerfile .` sur le Mac pour un pb de build — beaucoup moins destructif qu'un debug en prod.
5. **Un échec en 10s n'est pas un symptôme de DNS.** C'est presque toujours : workflow parse error, image pull auth, étape checkout qui fail. Regarder les logs, pas deviner.

## Automation philosophy

Everything that has an API or an SSH path must be done by the skill, not by the user. Specifically:
- DNS records → OVH API (creds at `~/.config/ovh/credentials.env`)
- Gitea repo + secrets → Gitea API (token at `~/.config/gitea/token`)
- K3s kubeconfig → SSH to master, rewrite loopback, base64, push
- Traefik route → edit Ansible template + task, run `gateway.yml`
- App deploy → push commits, CI does the rest

The only things that legitimately require the user are: (a) confirming the deployment plan, (b) providing third-party secrets (OAuth client secrets, API keys the skill cannot generate), (c) pre-existing CLAUDE.md conventions. Never end a deployment with a "manual checklist" for things the skill could have done.

## Step 1 — Deep project analysis

This is the most important step. You must actually READ the project files to understand its architecture. Do not guess — inspect.

### 1a. Determine project structure

Run a recursive listing of the project root (excluding node_modules, .git, dist, build, __pycache__, .venv). Then classify:

| Structure | Classification | Deploy pattern |
|-----------|---------------|----------------|
| Single root with `package.json` or `main.py` etc. | **Monolith** | Single image |
| `frontend/` + `backend/` (or `client/` + `server/`, `web/` + `api/`) | **Fullstack** | Two images + nginx proxy |
| Only static output (HTML/CSS/JS, no server) | **Static site** | Single image, nginx |
| Only a server (no frontend build) | **API-only** | Single image |
| `docker-compose.yml` with multiple services | **Multi-service** | Analyze each service |

### 1b. Detect language and framework

Read the actual dependency/config files — don't just check if they exist:

**JavaScript/TypeScript:**
- Read `package.json` → check `dependencies` for framework: `fastify`, `express`, `koa`, `hapi`, `next`, `nuxt`, `astro`, `@angular/core`, `react`, `vue`, `svelte`
- Check `scripts.build` and `scripts.start` to understand build/run commands
- Check for `tsconfig.json` → TypeScript project
- Lock file: `pnpm-lock.yaml` → pnpm, `yarn.lock` → yarn, `package-lock.json` → npm

**Python:**
- Read `requirements.txt` or `pyproject.toml` → check for `fastapi`, `flask`, `django`, `starlette`, `uvicorn`, `gunicorn`
- Check for `manage.py` → Django
- Check for `main.py`, `app.py`, `server.py` as entry point

**Go:**
- Read `go.mod` → check module name and deps (`gin`, `echo`, `fiber`, `chi`, `net/http`)
- Check for `main.go` and `cmd/` directory structure
- Look for `Makefile` with build targets

**Rust:**
- Read `Cargo.toml` → check for `actix-web`, `axum`, `rocket`, `warp`

**Other (PHP, Ruby, Java, etc.):**
- Read the main config file (`composer.json`, `Gemfile`, `pom.xml`, `build.gradle`)
- Adapt Dockerfile pattern accordingly

### 1c. Detect ports

Check these sources in order (first match wins):
1. Existing `Dockerfile` → `EXPOSE` directive
2. Server source code → `listen(PORT)`, `.listen(`, `port =`, `--port`, `addr =`
3. `.env` / `.env.example` → `PORT=`
4. `docker-compose.yml` → `ports:` mapping
5. Framework defaults: Fastify/Express → 3000, Vite dev → 5173, FastAPI → 8000, Django → 8000, Go HTTP → 8080, nginx → 80

### 1d. Detect health endpoint

Search the codebase:
1. Grep for route definitions containing `health` (`/health`, `/api/health`, `/healthz`, `/readyz`)
2. If found, note the exact path and method
3. If not found → default to `GET /` for static sites, and **create a `/health` endpoint** for APIs (suggest it to the user)

### 1e. Detect database needs

| Signal | ORM/Driver | Action needed |
|--------|-----------|---------------|
| `prisma/schema.prisma` | Prisma | Create DB + initContainer for migrations |
| `sequelize` in deps | Sequelize | Create DB + migration command |
| `typeorm` in deps | TypeORM | Create DB + migration command |
| `sqlalchemy` / `alembic` in deps | SQLAlchemy | Create DB + alembic upgrade head |
| `gorm` in go.mod | GORM | Create DB + auto-migrate |
| `pg`, `mysql2`, `mongodb` in deps | Raw driver | Create DB, no migration tool |
| `DATABASE_URL` in .env | Unknown | Ask user |
| None of the above | No DB | Skip DB step |

### 1f. Detect environment variables

1. Read `.env`, `.env.example`, `.env.local`, `.env.production` if they exist
2. Read config files that use `process.env.*`, `os.environ`, `os.Getenv`
3. Separate into:
   - **Build args** (needed at Docker build time): `VITE_*`, `NEXT_PUBLIC_*`, `NUXT_PUBLIC_*`, `REACT_APP_*`
   - **Runtime config** (non-secret, goes in ConfigMap): `NODE_ENV`, `PORT`, `LOG_LEVEL`, `CORS_ORIGINS`
   - **Secrets** (goes in K8s Secret): `DATABASE_URL`, `JWT_SECRET`, `*_API_KEY`, `*_SECRET*`, passwords

### 1g. Detect storage needs

Search for:
- File upload handling (`multer`, `formidable`, `busboy`, `UploadFile`, `multipart`)
- Static file serving from a data directory (`/uploads`, `/media`, `/data`, `/storage`)
- MinIO/S3 client usage → may not need PVC if using object storage
- If found → PVC needed, ask user for size

### 1h. Check existing deployment files

Before generating anything, check what already exists:
- `.gitignore` (CRITICAL — see Step 7a)
- `Dockerfile` / `backend/Dockerfile` / `frontend/Dockerfile`
- `docker-compose.yml` / `docker-compose.prod.yml`
- `k8s/` directory with manifests
- `.gitea/workflows/` or `.github/workflows/`
- `nginx.conf` or `nginx-prod.conf`

If files exist, ask the user: adapt existing ones or regenerate from scratch?

### 1i. Present analysis report

After all detection, present a structured summary to the user:

```
Projet: <name>
Type: <monolith|fullstack|static|api-only>
Framework: <detected framework + version>
Langage: <language>
Package manager: <npm|pnpm|yarn|pip|go mod|cargo>
Port(s): <detected ports>
Health endpoint: <path or "à créer">
Base de données: <ORM detected or "aucune">
Variables d'env: <count> détectées (<count> secrets, <count> build args)
Stockage: <PVC needed or "non">
Fichiers existants: <list of existing deploy files>
```

Wait for user confirmation before proceeding.

## Step 2 — Gather deployment config

Use AskUserQuestion to collect missing info. Adapt questions to what was detected — don't ask about databases if none was detected, don't ask about build args if there are none.

**Always ask:**
1. **Nom de l'app** — propose a name based on the folder name (used for namespace, images, services)
2. **Domaine** — two options:
   - Sous-domaine de `arthurbarre.fr` (perso/infra) → which subdomain?
   - Domaine dédié (pro/client) → full domain?
3. **NodePort** — suggest the next available (scan ip-plan.md in proxmox repo to find the last used one)

**Ask only if relevant:**
4. **Database** — only if DB was detected. Suggest: `postgresql://<app>:<password>@10.10.10.3:5432/<app>`
5. **Secrets** — list the ones detected, ask user to confirm values or say "je les mettrai moi-même dans Gitea"
6. **Build args** — list detected build args, ask for production values (e.g., `VITE_API_BASE_URL=https://<domain>/api`)
7. **Replicas** — default 1, only ask if user seems to want HA
8. **PVC size** — only if storage detected, default 5Gi

## Step 3 — Generate Dockerfile(s)

Read `references/dockerfile-patterns.md` for base patterns, but **adapt them to the actual project**:

- Use the EXACT package manager detected (don't use npm if the project uses pnpm)
- Use the EXACT build command from `package.json` scripts (not a generic `npm run build`)
- Use the EXACT entry point from the project (`dist/server.js`, `dist/index.js`, `build/main.js`, etc.)
- If a Dockerfile already exists and looks correct, keep it — don't regenerate
- For frontend builds that need env vars at build time, add the correct `ARG` directives
- If the project has a custom nginx.conf, keep it; if not, generate one appropriate for the framework (SPA needs `try_files` fallback, static site might not)

Also generate `.dockerignore` if missing.

## Step 4 — Generate K8s manifests

Read `references/k8s-patterns.md` for structural patterns, but adapt everything:

- **Resource limits**: match the project weight — a Go binary needs less RAM than a Node.js app
- **Health probes**: use the ACTUAL health endpoint detected, with appropriate timeouts (heavier apps need longer `initialDelaySeconds`)
- **initContainers**: only if ORM migrations needed — use the ACTUAL migration command (`npx prisma db push`, `alembic upgrade head`, `python manage.py migrate`, etc.)
- **ConfigMap**: include ALL detected non-secret env vars with production values
- **proxy.conf** (fullstack only): adapt routing based on the actual API prefix the project uses (might be `/api/`, `/v1/`, or something custom — READ the frontend API client to find out)
- **Number of deployments**: match the actual project structure — could be 1, 2, 3+

## Step 5 — Generate Gitea CI workflow

Read `references/ci-patterns.md` for the base structure, but adapt:

- **Build commands**: match the actual Dockerfiles (build args, context paths)
- **Secrets creation**: include ONLY the secrets that were actually detected
- **Deployment names**: match the ACTUAL deployment names from the generated K8s manifests
- **Rollout targets**: list ALL deployments that need rollout monitoring
- If the project has tests, add a test step before building

## Step 6 — Generate Traefik route (and wire it up)

### 6a. Create the template

Create `<proxmox-repo>/ansible/roles/traefik/templates/<app-name>.yml.j2`:

```yaml
# Dynamic config — <domain> → <App Name> (K3s NodePort)
http:
  routers:
    <app-name>:
      rule: "Host(`<domain>`)"
      entryPoints:
        - websecure
      service: <app-name>
      tls:
        certResolver: letsencrypt

    <app-name>-www:
      rule: "Host(`www.<domain>`)"
      entryPoints:
        - websecure
      service: <app-name>
      tls:
        certResolver: letsencrypt

  services:
    <app-name>:
      loadBalancer:
        servers:
          - url: "http://10.10.10.5:<nodeport>"
```

For WebSocket-heavy apps (signaling, realtime), Traefik natively forwards WS upgrades — no extra config needed. Use `rate-limit` middleware for public apps, drop it for Tailscale-only routes.

### 6b. Wire the template into the Ansible role (DO THIS, don't just remind)

Edit `<proxmox-repo>/ansible/roles/traefik/tasks/main.yml` and append a deploy task for the new template (follow the exact pattern of the existing ones, e.g. `wetalk`):

```yaml
- name: Deploy <app-name>.arthurbarre.fr dynamic config
  template:
    src: <app-name>.yml.j2
    dest: "{{ traefik_config_dir }}/dynamic/<app-name>.yml"
    mode: "0644"
```

Insert it BEFORE the `Create Traefik systemd service` task (which must remain last among the template tasks).

### 6c. Create DNS record via OVH API (DO THIS, don't just remind)

Credentials live at `~/.config/ovh/credentials.env` (Application Key, Secret, Consumer Key). Use the pattern from the root `CLAUDE.md` — a single `source ~/.config/ovh/credentials.env` + two `curl`s (create A record, refresh zone). Target is always `51.38.62.199`.

After creation, verify: `dig +short <subdomain>.arthurbarre.fr A` → should return `51.38.62.199`.

### 6d. Run the Ansible playbook (DO THIS)

The `gateway.yml` playbook has no tags — run it fully. It is idempotent:

```bash
cd <proxmox-repo>/ansible && ansible-playbook playbooks/gateway.yml
```

Do NOT use `--tags traefik` (no such tag exists). SSH to the gateway goes through Tailscale — the first call of the session may trigger a Tailscale SSH auth prompt in the browser; subsequent calls are passwordless.

## Step 7 — Create Gitea repo, push, and configure secrets

### 7a. Write `.gitignore` FIRST — before any `git` command

**Critical friction point:** if `git init && git add -A` runs before `.gitignore` exists, `node_modules/`, `dist/`, etc. will be staged. `git rm --cached` doesn't help on a pristine repo with no commits — the files stay indexed until you `git reset` and re-add.

Always create `.gitignore` BEFORE running `git init`. Minimum content (adapt to the stack):

```
node_modules
dist
build
.venv
__pycache__
.DS_Store
.env
.env.local
```

### 7b. Load secrets

```bash
# Registry password (for CI image push) — single-line env file
source <proxmox-repo>/.secrets   # exports REGISTRY_PASSWORD

# Gitea API token (for repo + secrets management) — raw token string
GITEA_TOKEN=$(cat ~/.config/gitea/token)
```

### 7c. Create repo via API and push

```bash
curl -s -X POST "https://git.arthurbarre.fr/api/v1/user/repos" \
  -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "<app-name>", "private": false, "auto_init": false}'

cd <project-path>
# .gitignore MUST already exist at this point (see 7a)
git init
git add -A
git commit -m "feat: initial commit with deployment setup"
git remote add origin https://git.arthurbarre.fr/ordinarthur/<app-name>.git
git push -u origin main
```

Sanity check before committing: `git diff --cached --name-only | grep -c "^node_modules/"` must be `0`. If not, fix `.gitignore`, then `git reset && git add -A`.

### 7d. Configure Gitea secrets (BOTH are automatable — do it, don't remind)

**REGISTRY_PASSWORD** — from `.secrets`:

```bash
curl -s -X PUT "https://git.arthurbarre.fr/api/v1/repos/ordinarthur/<app-name>/actions/secrets/REGISTRY_PASSWORD" \
  -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"data\": \"$REGISTRY_PASSWORD\"}"
```

**KUBECONFIG** — fetch from the K3s master via Tailscale SSH, rewrite the loopback to the internal IP (`10.10.10.5`) so Act Runner on the worker can reach it, base64-encode, then push:

```bash
KUBECONFIG_B64=$(ssh arthur@100.78.207.119 "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed 's/127.0.0.1/10.10.10.5/' | base64)

curl -s -X PUT "https://git.arthurbarre.fr/api/v1/repos/ordinarthur/<app-name>/actions/secrets/KUBECONFIG" \
  -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"data\": \"$KUBECONFIG_B64\"}"
```

(First Tailscale SSH of the session may require browser auth — harmless, re-run the command after auth.)

**App-specific secrets** — for each detected secret (e.g. `DATABASE_URL`, `JWT_SECRET`, OAuth client secrets, etc.), call the same PUT endpoint. Only ask the user for values that aren't derivable (e.g. OAuth client secrets from third-party providers).

## Step 8 — Update infra documentation

Update these files in the proxmox repo:
- `docs/ip-plan.md` — add new NodePort, domain mapping, and "Domaines actifs" entry
- `docs/production-state.md` — add new service to deployed services list

## Step 9 — Verify deployment health

After the user confirms CI has run (or check Gitea API for workflow status):

1. `curl -s -o /dev/null -w "%{http_code}" https://<domain>/` → expect 200
2. `curl -s https://<domain>/health` → expect `{"status":"ok"}` (if API)
3. `curl -sI https://<domain>/ | grep -i "strict-transport"` → verify HTTPS

If verification fails, provide targeted troubleshooting:
- **CI failed** → check `https://git.arthurbarre.fr/ordinarthur/<app>/actions`
- **Pod not running** → `kubectl -n <ns> get pods`, `kubectl -n <ns> logs <pod>`
- **502/504** → Traefik can't reach NodePort → check service: `kubectl -n <ns> get svc`
- **DNS not resolving** → A record not yet propagated, check with `dig <domain>`
- **TLS error** → Let's Encrypt rate limit or DNS issue, check Traefik logs

## Reference Files

These contain structural templates. Always adapt them to the actual project:
- `references/dockerfile-patterns.md` — Dockerfile base patterns by language/framework
- `references/k8s-patterns.md` — K8s manifest structures (simple + fullstack + TLS routing)
- `references/ci-patterns.md` — Gitea Actions workflow structures
