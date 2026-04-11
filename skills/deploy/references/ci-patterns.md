# Gitea CI/CD Patterns

Base structures for `.gitea/workflows/deploy.yml`. Adapt every step to the actual project: the number of images to build, the build args needed, the secrets to inject, the deployment names to rollout, and optionally a test step if the project has tests.

The CI must mirror exactly what was generated in the K8s manifests — same deployment names, same namespace, same secrets.

## Table of Contents
- [Simple Pattern (single image)](#simple-pattern)
- [Fullstack Pattern (multiple images)](#fullstack-pattern)
- [Required Gitea Secrets](#required-gitea-secrets)

---

## Simple Pattern

Use for: static sites, SPAs, single APIs, monoliths.
Reference: douzoute (aurelie-portfolio).

```yaml
name: Build & Deploy to K3s

on:
  push:
    branches: [main]

env:
  REGISTRY: git.arthurbarre.fr
  IMAGE: git.arthurbarre.fr/ordinarthur/{{APP_NAME}}

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Login to Gitea Container Registry
        run: |
          echo "${{ secrets.REGISTRY_PASSWORD }}" | \
            docker login ${{ env.REGISTRY }} -u ordinarthur --password-stdin

      - name: Build Docker image
        run: |
          docker build -t ${{ env.IMAGE }}:${{ github.sha }} -t ${{ env.IMAGE }}:latest .

      - name: Push to registry
        run: |
          docker push ${{ env.IMAGE }}:${{ github.sha }}
          docker push ${{ env.IMAGE }}:latest

      - name: Install kubectl
        run: |
          curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
          chmod +x kubectl && mv kubectl /usr/local/bin/kubectl

      - name: Configure kubeconfig
        run: |
          mkdir -p ~/.kube
          echo "${{ secrets.KUBECONFIG }}" | base64 -d > ~/.kube/config

      - name: Create image pull secret
        run: |
          kubectl -n {{NAMESPACE}} create secret docker-registry gitea-registry-secret \
            --docker-server=${{ env.REGISTRY }} \
            --docker-username=ordinarthur \
            --docker-password="${{ secrets.REGISTRY_PASSWORD }}" \
            --dry-run=client -o yaml | kubectl apply -f -

      # Include this step ONLY if the app has secrets (DATABASE_URL, JWT, API keys, etc.)
      # - name: Create app secrets
      #   run: |
      #     kubectl -n {{NAMESPACE}} create secret generic {{APP_NAME}}-secrets \
      #       --from-literal=DATABASE_URL="${{ secrets.DATABASE_URL }}" \
      #       --dry-run=client -o yaml | kubectl apply -f -

      - name: Deploy to K3s
        run: |
          kubectl apply -f k8s/namespace.yml
          kubectl apply -f k8s/service.yml
          kubectl apply -f k8s/deployment.yml

          kubectl -n {{NAMESPACE}} set image deployment/{{APP_NAME}} \
            {{APP_NAME}}=${{ env.IMAGE }}:${{ github.sha }}

          kubectl -n {{NAMESPACE}} rollout status deployment/{{APP_NAME}} --timeout=120s

      - name: Cleanup old images
        run: |
          docker image prune -f
```

---

## Fullstack Pattern

Use for: apps with separate frontend and backend images.
Reference: freedge.

```yaml
name: Build & Deploy to K3s

on:
  push:
    branches: [main]

env:
  REGISTRY: git.arthurbarre.fr
  BACKEND_IMAGE: git.arthurbarre.fr/ordinarthur/{{APP_NAME}}-backend
  FRONTEND_IMAGE: git.arthurbarre.fr/ordinarthur/{{APP_NAME}}-frontend
  REGISTRY_USER: ordinarthur

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Login to Gitea Container Registry
        run: |
          echo "${{ secrets.REGISTRY_PASSWORD }}" | \
            docker login ${{ env.REGISTRY }} -u ${{ env.REGISTRY_USER }} --password-stdin

      - name: Build backend image
        run: |
          docker build \
            -t ${{ env.BACKEND_IMAGE }}:${{ github.sha }} \
            -t ${{ env.BACKEND_IMAGE }}:latest \
            ./backend

      - name: Build frontend image
        run: |
          docker build \
            --build-arg VITE_API_BASE_URL=https://{{DOMAIN}}/api \
            -t ${{ env.FRONTEND_IMAGE }}:${{ github.sha }} \
            -t ${{ env.FRONTEND_IMAGE }}:latest \
            ./frontend

      - name: Push backend image
        run: |
          docker push ${{ env.BACKEND_IMAGE }}:${{ github.sha }}
          docker push ${{ env.BACKEND_IMAGE }}:latest

      - name: Push frontend image
        run: |
          docker push ${{ env.FRONTEND_IMAGE }}:${{ github.sha }}
          docker push ${{ env.FRONTEND_IMAGE }}:latest

      - name: Install kubectl
        run: |
          curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
          chmod +x kubectl
          mv kubectl /usr/local/bin/kubectl

      - name: Configure kubeconfig
        run: |
          mkdir -p ~/.kube
          echo "${{ secrets.KUBECONFIG }}" | base64 -d > ~/.kube/config

      - name: Apply namespace and shared resources
        run: |
          kubectl apply -f k8s/namespace.yml
          kubectl apply -f k8s/configmap.yml
          kubectl apply -f k8s/pvc.yml
          kubectl apply -f k8s/service.yml

      - name: Create image pull secret
        run: |
          kubectl -n {{NAMESPACE}} create secret docker-registry gitea-registry-secret \
            --docker-server=${{ env.REGISTRY }} \
            --docker-username=${{ env.REGISTRY_USER }} \
            --docker-password="${{ secrets.REGISTRY_PASSWORD }}" \
            --dry-run=client -o yaml | kubectl apply -f -

      - name: Create app secrets
        run: |
          kubectl -n {{NAMESPACE}} create secret generic {{APP_NAME}}-secrets \
            --from-literal=DATABASE_URL="${{ secrets.DATABASE_URL }}" \
            --dry-run=client -o yaml | kubectl apply -f -

      - name: Deploy workloads
        run: |
          kubectl apply -f k8s/deployment.yml
          kubectl -n {{NAMESPACE}} set image deployment/{{APP_NAME}}-backend \
            {{APP_NAME}}-backend=${{ env.BACKEND_IMAGE }}:${{ github.sha }}
          kubectl -n {{NAMESPACE}} set image deployment/{{APP_NAME}}-frontend \
            {{APP_NAME}}-frontend=${{ env.FRONTEND_IMAGE }}:${{ github.sha }}
          kubectl -n {{NAMESPACE}} rollout status deployment/{{APP_NAME}}-backend --timeout=180s
          kubectl -n {{NAMESPACE}} rollout status deployment/{{APP_NAME}}-frontend --timeout=180s
          kubectl -n {{NAMESPACE}} rollout status deployment/{{APP_NAME}}-proxy --timeout=180s

      - name: Cleanup old images
        run: |
          docker image prune -f
```

---

## Required Gitea Secrets

Tell the user to configure these in **Gitea repo settings → Actions → Secrets**:

### Always required
| Secret | Description | How to get |
|--------|-------------|------------|
| `REGISTRY_PASSWORD` | Gitea API token for container registry | Gitea → Settings → Applications → Generate Token |
| `KUBECONFIG` | Base64-encoded kubeconfig for K3s | `cat ~/.kube/config \| base64 -w 0` from k3s-master |

### App-specific (if database/secrets needed)
| Secret | Description | Example |
|--------|-------------|---------|
| `DATABASE_URL` | PostgreSQL connection string | `postgresql://appname:password@10.10.10.3:5432/appname` |
| `JWT_SECRET` | JWT signing key | Generate with `openssl rand -hex 32` |
| Other app secrets | As detected during project analysis | Varies |

### Creating the PostgreSQL database

If the app needs a database, run on the db VM (10.10.10.3):

```sql
CREATE USER {{APP_NAME}} WITH PASSWORD 'secure-password-here';
CREATE DATABASE {{APP_NAME}} OWNER {{APP_NAME}};
```

Or via Ansible playbook pattern (like gitea-db.yml):
```yaml
- hosts: databases
  become: true
  vars_prompt:
    - name: db_password
      prompt: "Password for {{APP_NAME}} database user"
      private: true
  tasks:
    - name: Create database user
      community.postgresql.postgresql_user:
        name: "{{APP_NAME}}"
        password: "{{ db_password }}"
    - name: Create database
      community.postgresql.postgresql_db:
        name: "{{APP_NAME}}"
        owner: "{{APP_NAME}}"
```
