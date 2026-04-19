# Portfolio (arthurbarre.fr)

Site nginx static, namespace `portfolio`. Migré depuis la VM Docker (102) en
avril 2026.

## Architecture

- **Image** : `git.arthurbarre.fr/ordinarthur/portfolio:0.1.0` — buildée
  manuellement depuis le code source `/home/arthur/portfolio` de l'ancienne VM
  Docker (Vite + nginx alpine), puis pushée sur le registry Gitea
- **NodePort** : `30101`
- **Route Traefik** : `https://arthurbarre.fr` → `10.10.10.5:30101` (publique,
  rate-limit, redirect HTTP→HTTPS)

## Recréer from scratch

### a) Build & push image

Sur n'importe quelle machine avec accès au repo source + Docker :

```bash
cd <portfolio-repo>
echo '<REGISTRY_PASSWORD>' | docker login git.arthurbarre.fr -u ordinarthur --password-stdin
docker build -t git.arthurbarre.fr/ordinarthur/portfolio:0.1.0 .
docker push git.arthurbarre.fr/ordinarthur/portfolio:0.1.0
```

(Remplacer `0.1.0` par la version voulue + bumper dans `deployment.yml`.)

### b) Deploy K3s

```bash
KC=~/dev/perso/proxmox/k3s/kubeconfig.yaml

kubectl --kubeconfig $KC apply -f namespace.yml

# Pull secret (Gitea registry est privé)
kubectl --kubeconfig $KC -n portfolio create secret docker-registry gitea-registry \
  --docker-server=git.arthurbarre.fr \
  --docker-username=ordinarthur \
  --docker-password='<REGISTRY_PASSWORD>'

kubectl --kubeconfig $KC apply -f deployment.yml -f service.yml
```

### c) Route Traefik

Déjà templatée dans `ansible/roles/traefik/templates/portfolio.yml.j2`.
DNS `arthurbarre.fr → 51.38.62.199` est géré dans OVH (apex record).

```bash
cd ../../../ansible && ansible-playbook playbooks/gateway.yml
```

## Mise à jour

1. Build + push nouvelle image avec un nouveau tag
2. Bump `image:` dans `deployment.yml`
3. `kubectl apply -f deployment.yml`
