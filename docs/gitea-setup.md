# Gitea — Setup & Procédures

Gitea est déployé sur K3s et accessible sur `https://git.arthurbarre.fr`.
Il sert de forge Git, container registry, et plateforme CI/CD (Gitea Actions).

---

## Architecture

```
Internet :443 → Traefik (10.10.10.2) → git.arthurbarre.fr → K3s NodePort 30080 → Gitea pod
                                                                                   → PostgreSQL (10.10.10.3) DB: gitea
CI/CD: Gitea Actions → Act Runner (pod K3s, worker) → Docker socket → Build image
                                                     → kubectl → K3s deploy
```

---

## Composants déployés

| Composant | Namespace | Image | Notes |
|---|---|---|---|
| Gitea | gitea | gitea/gitea:1.23-rootless | Config via ConfigMap + Secrets |
| Act Runner | gitea | gitea/act_runner:latest | Schedulé sur k3s-worker (Docker installé) |
| PVC | gitea | — | 10Gi local-path pour les repos git |

---

## Accès

- **UI** : https://git.arthurbarre.fr
- **API** : https://git.arthurbarre.fr/api/v1
- **Registry** : git.arthurbarre.fr (Container Package Registry)
- **User admin** : `ordinarthur`

---

## Fichiers de configuration

| Fichier | Description |
|---|---|
| `k3s/manifests/gitea/namespace.yml` | Namespace `gitea` |
| `k3s/manifests/gitea/configmap.yml` | Config `app.ini` (DB, server, actions) |
| `k3s/manifests/gitea/pvc.yml` | Stockage persistant 10Gi |
| `k3s/manifests/gitea/deployment.yml` | Pod Gitea (initContainer pour config writable) |
| `k3s/manifests/gitea/service.yml` | NodePort 30080 (HTTP) + 30022 (SSH) |
| `k3s/manifests/gitea/act-runner.yml` | Runner CI schedulé sur k3s-worker |
| `ansible/playbooks/gitea-db.yml` | Création DB PostgreSQL pour Gitea |
| `ansible/roles/traefik/templates/gitea.yml.j2` | Route Traefik → git.arthurbarre.fr |

---

## Secrets K8s (namespace `gitea`)

Secret : `gitea-secrets`

| Clé | Description |
|---|---|
| `db-password` | Mot de passe PostgreSQL user `gitea` |
| `secret-key` | Clé secrète Gitea (openssl rand -hex 32) |
| `internal-token` | Token interne Gitea (openssl rand -hex 32) |
| `runner-token` | Token d'enregistrement du runner (généré dans l'UI) |

---

## Procédures

### Déployer Gitea from scratch

```bash
# 1. Créer la base de données PostgreSQL
cd ansible
ansible-playbook playbooks/gitea-db.yml

# 2. Créer le namespace et les secrets K8s
SECRET_KEY=$(openssl rand -hex 32)
INTERNAL_TOKEN=$(openssl rand -hex 32)

kubectl apply -f k3s/manifests/gitea/namespace.yml

kubectl -n gitea create secret generic gitea-secrets \
  --from-literal=db-password='<MOT_DE_PASSE_DB>' \
  --from-literal=secret-key=$SECRET_KEY \
  --from-literal=internal-token=$INTERNAL_TOKEN \
  --from-literal=runner-token=placeholder

# 3. Déployer
kubectl apply -f k3s/manifests/gitea/pvc.yml
kubectl apply -f k3s/manifests/gitea/configmap.yml
kubectl apply -f k3s/manifests/gitea/deployment.yml
kubectl apply -f k3s/manifests/gitea/service.yml

# 4. Déployer la route Traefik
ansible-playbook playbooks/gateway.yml
```

### Enregistrer le runner

1. Aller sur https://git.arthurbarre.fr/user/settings/actions/runners
2. Créer un nouveau runner, copier le token
3. Mettre à jour le secret K8s :

```bash
SECRET_KEY=$(kubectl -n gitea get secret gitea-secrets -o jsonpath='{.data.secret-key}' | base64 -d)
INTERNAL_TOKEN=$(kubectl -n gitea get secret gitea-secrets -o jsonpath='{.data.internal-token}' | base64 -d)
DB_PASSWORD=$(kubectl -n gitea get secret gitea-secrets -o jsonpath='{.data.db-password}' | base64 -d)

kubectl -n gitea delete secret gitea-secrets
kubectl -n gitea create secret generic gitea-secrets \
  --from-literal=db-password="$DB_PASSWORD" \
  --from-literal=secret-key=$SECRET_KEY \
  --from-literal=internal-token=$INTERNAL_TOKEN \
  --from-literal=runner-token=<TOKEN>

kubectl apply -f k3s/manifests/gitea/act-runner.yml
```

### Créer un repo et pousser du code (via API + HTTPS)

SSH port 22 n'est pas forwardé vers Gitea (seuls 80/443). Utiliser HTTPS avec token personnel.

```bash
# 1. Créer un token API
curl -s -X POST https://git.arthurbarre.fr/api/v1/users/ordinarthur/tokens \
  -H "Content-Type: application/json" \
  -u 'ordinarthur:<MOT_DE_PASSE>' \
  -d '{"name":"cli-push","scopes":["write:repository","read:user"]}'
# → noter le champ "sha1"

# 2. Créer le repo
curl -s -X POST https://git.arthurbarre.fr/api/v1/user/repos \
  -H "Content-Type: application/json" \
  -u 'ordinarthur:<MOT_DE_PASSE>' \
  -d '{"name":"mon-projet","private":false,"auto_init":false}'

# 3. Configurer le remote et pousser
git remote add gitea https://ordinarthur:<TOKEN>@git.arthurbarre.fr/ordinarthur/mon-projet.git
git push gitea main
```

### Créer le secret K8s pour pull les images du registry Gitea

À faire une fois par namespace qui déploie des images depuis Gitea :

```bash
kubectl -n <NAMESPACE> create secret docker-registry gitea-registry-secret \
  --docker-server=git.arthurbarre.fr \
  --docker-username=ordinarthur \
  --docker-password=<TOKEN_API>
```

---

## Dépannage

### PostgreSQL : erreur de socket
Symptôme : `connection to server on socket "/run/postgresql/.s.PGSQL.5432" failed`
Cause : `listen_addresses` dans `postgresql.conf` mal formaté (manque les guillemets).
Fix :
```bash
ssh arthur@100.114.242.60 "sudo sed -i \"s/listen_addresses = 10.10.10.3, 127.0.0.1/listen_addresses = '10.10.10.3, 127.0.0.1'/\" /etc/postgresql/15/main/postgresql.conf && sudo systemctl restart postgresql@15-main"
```

### Mot de passe avec $ dans les secrets K8s
Toujours utiliser des guillemets simples pour les mots de passe contenant `$` :
```bash
--from-literal=db-password='monMotDePasse$Avec$Dollar'
```

### Gitea : certificat TLS K3s invalide pour l'IP Tailscale
Symptôme : `x509: certificate is valid for 10.10.10.5, not 100.78.207.119`
Fix : ajouter le TLS SAN et régénérer les certificats :
```bash
echo 'tls-san:
  - 100.78.207.119
  - 10.10.10.5' | ssh arthur@100.78.207.119 "sudo tee /etc/rancher/k3s/config.yaml"
ssh arthur@100.78.207.119 "sudo k3s certificate rotate && sudo systemctl restart k3s"
# Puis re-récupérer le kubeconfig
ssh arthur@100.78.207.119 "sudo cat /etc/rancher/k3s/k3s.yaml" > k3s/kubeconfig.yaml
sed -i '' 's/127.0.0.1/100.78.207.119/' k3s/kubeconfig.yaml
```

### Runner : docker.sock absent sur le node
Symptôme : `hostPath type check failed: /var/run/docker.sock is not a socket file`
Cause : Docker n'est pas installé sur le node K3s worker.
Fix : installer Docker via un pod privilégié nsenter :
```bash
kubectl run docker-install --image=debian:12 --restart=Never --overrides='{
  "spec": {
    "nodeName": "k3s-worker",
    "hostPID": true, "hostNetwork": true,
    "containers": [{"name": "docker-install", "image": "debian:12",
      "command": ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "--", "bash", "-c",
        "curl -fsSL https://get.docker.com | sh && systemctl enable docker && systemctl start docker"],
      "securityContext": {"privileged": true}}]
  }
}'
kubectl logs -f docker-install
kubectl delete pod docker-install
```

---

## Notes pour le skill de déploiement automatique

Quand le skill déploie un nouveau projet sur ce cluster, il doit :

1. **Créer le repo Gitea** via API (`POST /api/v1/user/repos`)
2. **Déterminer le domaine** (AskUserQuestion) :
   - Projet perso / infra → `xxx.arthurbarre.fr`
   - Projet pro / client → domaine dédié fourni
3. **Générer le Dockerfile** selon le framework détecté
4. **Générer les manifests K8s** (namespace, deployment, service NodePort, secret registry)
5. **Générer le workflow Gitea Actions** (`.gitea/workflows/deploy.yml`)
6. **Ajouter la route Traefik** dans `ansible/roles/traefik/templates/` + relancer `gateway.yml`
7. **Créer le secret registry** dans le namespace K8s (`gitea-registry-secret`)
8. **Pousser le code** via HTTPS avec token API
9. **Vérifier le premier pipeline** (`kubectl -n <ns> rollout status`)
