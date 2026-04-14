---
name: create-deployment
description: Met en place le déploiement complet d'un projet sur l'infra Proxmox/K3s (Dockerfile, manifests K3s, route Traefik, DNS OVH, repo Gitea + CI) et écrit une deploy-memory pour les déploiements futurs. À utiliser UNIQUEMENT au premier déploiement d'un projet ; pour une mise à jour, utiliser la commande /deploy.
---

# create-deployment

Skill de setup initial du déploiement d'un projet sur l'infra perso (Proxmox → Gateway Traefik → K3s).

Contexte infra complet : `~/dev/perso/proxmox/CLAUDE.md` (à lire si besoin des ports/domaines/conventions).

## Quand l'utiliser

- Premier déploiement d'un projet (pas de `.claude/deploy-memory.md` existant)
- L'utilisateur demande explicitement "setup deploy", "crée le déploiement", etc.

**NE PAS** utiliser pour une simple mise à jour — dans ce cas `/deploy` lit la memory et fait juste le rollout.

## Étapes

1. **Analyse minimale** (1-2 Bash max) : stack (Node/Python/Go/Rust…), port applicatif, build command. Pas d'exploration exhaustive.

2. **Dockerfile** à la racine si absent. Pin des versions, multi-stage si pertinent.

3. **Gitea Actions** `.gitea/workflows/deploy.yml` :
   - Build + push vers `git.arthurbarre.fr/ordinarthur/<app>:<sha>`
   - `kubectl set image` via secret `KUBECONFIG`
   - Secret registry : `REGISTRY_PASSWORD`

4. **Manifests K3s** `k3s/<app>/` : namespace, deployment, service NodePort.
   - Prendre le prochain port libre listé dans `~/dev/perso/proxmox/CLAUDE.md` (table NodePorts)
   - Après usage, **mettre à jour** la table NodePorts dans ce CLAUDE.md

5. **Route Traefik** :
   - `~/dev/perso/proxmox/ansible/roles/traefik/templates/<app>.yml.j2`
   - Tâche dans `ansible/roles/traefik/tasks/main.yml`
   - Ajouter la ligne dans la table "Domaines & Traefik" du CLAUDE.md

6. **DNS OVH** : A record `<sub>.arthurbarre.fr` → `51.38.62.199` via API OVH (snippet dans CLAUDE.md).

7. **Repo Gitea** + secrets Actions via API Gitea (snippets dans CLAUDE.md) :
   - `KUBECONFIG` (base64, avec IP interne `10.10.10.5`)
   - `REGISTRY_PASSWORD`

8. **Apply** :
   ```bash
   kubectl --kubeconfig ~/dev/perso/proxmox/k3s/kubeconfig.yaml apply -f k3s/<app>/
   cd ~/dev/perso/proxmox/ansible && ansible-playbook playbooks/gateway.yml
   ```

9. **Vérif** : `curl -I https://<sub>.arthurbarre.fr` (200/301 attendu).

10. **ÉCRIRE la memory** — étape obligatoire — dans `.claude/deploy-memory.md` du projet déployé :

```markdown
# Deploy memory — <app>

## Infra
- Namespace : <ns>
- Deployment : <name>
- Container : <container>
- NodePort : <port>
- Image : git.arthurbarre.fr/ordinarthur/<app>
- Domaine : https://<sub>.arthurbarre.fr
- Manifests : k3s/<app>/
- Route Traefik : ansible/roles/traefik/templates/<app>.yml.j2

## Mise à jour (à suivre pour les prochains /deploy)
1. Push git → CI Gitea build + rollout auto
   OU manuel :
   ```bash
   TAG=$(git rev-parse --short HEAD)
   docker build -t git.arthurbarre.fr/ordinarthur/<app>:$TAG .
   docker push git.arthurbarre.fr/ordinarthur/<app>:$TAG
   kubectl --kubeconfig ~/dev/perso/proxmox/k3s/kubeconfig.yaml \
     -n <ns> set image deploy/<name> <container>=git.arthurbarre.fr/ordinarthur/<app>:$TAG
   kubectl --kubeconfig ~/dev/perso/proxmox/k3s/kubeconfig.yaml \
     -n <ns> rollout status deploy/<name>
   ```
2. Si changement route/domaine : `cd ~/dev/perso/proxmox/ansible && ansible-playbook playbooks/gateway.yml`
3. Vérif : `curl -I https://<sub>.arthurbarre.fr`

## Déjà fait — NE PAS refaire
Dockerfile, manifests K3s, route Traefik, DNS OVH, repo Gitea + secrets CI. Les prochains /deploy font uniquement build + rollout.
```

## Principes

- Minimiser les tool calls. Pas d'agent d'exploration du repo.
- Pin toutes les versions d'images.
- Pas de secrets en clair dans les manifests (`kubectl create secret`).
- Mettre à jour `~/dev/perso/proxmox/CLAUDE.md` (NodePort + table domaines) à chaque nouvelle app.
