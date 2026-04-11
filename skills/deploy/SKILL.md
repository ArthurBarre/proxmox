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
- **Used NodePorts**: 30080 (Gitea), 30081 (Douzoute), 30082 (Freedge)

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

## Step 6 — Generate Traefik route

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

Remind the user to:
1. Add a deploy task in the Traefik role for this new template
2. Run the Ansible playbook: `ansible-playbook ansible/playbooks/gateway.yml`
3. Point the DNS (A record) to 51.38.62.199

## Step 7 — Create Gitea repo and push

```bash
# Create repo via API
curl -X POST "https://git.arthurbarre.fr/api/v1/user/repos" \
  -H "Authorization: token <GITEA_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"name": "<app-name>", "private": false, "auto_init": false}'

# Initialize and push
cd <project-path>
git init  # if not already a git repo
git remote add origin git@git.arthurbarre.fr:ordinarthur/<app-name>.git  # or HTTPS
git add -A
git commit -m "Initial commit"
git push -u origin main
```

**Before pushing**, remind the user to configure Gitea secrets:
- Go to `https://git.arthurbarre.fr/ordinarthur/<app-name>/settings/actions/secrets`
- Add `REGISTRY_PASSWORD` and `KUBECONFIG` (always needed)
- Add app-specific secrets (list them explicitly)

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
