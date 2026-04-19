# MinIO

Stockage S3 self-hosted, namespace `minio`. Migré depuis la VM Docker (102) en avril 2026.

## Architecture

- **Image** : `minio/minio:RELEASE.2024-09-22T00-33-43Z` — pin avant le bump
  glibc-x86-64-v2 (les versions plus récentes crashent sur les CPU exposés via
  Proxmox). À garder.
- **Storage** : PVC `local-path` 10 Gi (RWO) — donc strategy `Recreate`
- **NodePort** : `30102` (S3 API), `30103` (Console)
- **Routes Traefik** :
  - `https://minio.arthurbarre.fr` → S3 API (publique, rate-limit)
  - `https://minio-console.arthurbarre.fr` → Console (publique, login admin)

## Recréer from scratch

```bash
KC=~/dev/perso/proxmox/k3s/kubeconfig.yaml

# 1) namespace + PVC
kubectl --kubeconfig $KC apply -f namespace.yml -f pvc.yml

# 2) credentials (générer un pwd robuste)
PWD=$(openssl rand -base64 24 | tr -d '/+=')
kubectl --kubeconfig $KC -n minio create secret generic minio-credentials \
  --from-literal=root-user=admin \
  --from-literal=root-password="$PWD"
echo "MinIO admin password: $PWD"  # → password manager

# 3) deploy + service
kubectl --kubeconfig $KC apply -f deployment.yml -f service.yml

# 4) route Traefik (déjà templatée)
cd ../../../ansible && ansible-playbook playbooks/gateway.yml

# 5) DNS A records (si new install)
#    minio.arthurbarre.fr → 51.38.62.199
#    minio-console.arthurbarre.fr → 51.38.62.199
#    (snippet OVH dans CLAUDE.md proxmox)
```

## Gérer les buckets

Via mc CLI (depuis n'importe quel pod ayant `minio/mc`) :

```bash
docker run --rm --entrypoint=mc \
  -e MC_HOST_kuma=http://admin:$PWD@minio.arthurbarre.fr \
  minio/mc:latest mb -p kuma/<bucket-name>
```

Ou via la console : https://minio-console.arthurbarre.fr (login `admin` + pwd).

## Backup

PVC monté sur `/data` dans le pod. Le PV est sur le node où le pod est schedulé
(local-path). Pour backup :

```bash
kubectl --kubeconfig $KC -n minio exec deploy/minio -- \
  tar czf - /data | gzip > minio-backup-$(date +%F).tar.gz
```
