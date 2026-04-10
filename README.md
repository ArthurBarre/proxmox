# Proxmox Infrastructure — Arthur

Infrastructure as Code pour le serveur dédié OVH sous Proxmox VE 9.

## Vue d'ensemble

```
Internet (:443/:80)
    │
    ▼
┌──────────────────────────────────────────────────┐
│  PROXMOX HOST — 51.38.62.199 (ns3142338)        │
│  ├── vmbr0  (bridge public, IP OVH)             │
│  ├── vmbr1  (bridge privé, 10.10.10.0/24, NAT)  │
│  └── tailscale0 (100.78.114.17, subnet router)  │
│                                                   │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
│  │ gateway  │ │ db       │ │ docker   │ │ k3s      │
│  │ Traefik  │ │ PG 15    │ │ Docker   │ │ K3s      │
│  │ .10.2    │ │ .10.3    │ │ .10.4    │ │ .10.5    │
│  │ VM 100   │ │ VM 101   │ │ VM 102   │ │ VM 103   │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘
└──────────────────────────────────────────────────┘
    │
    Tailscale mesh → laptop / phone
```

## Structure du repo

```
.
├── terraform/          # Provisionnement des VMs Proxmox
│   ├── main.tf         # Provider bpg/proxmox
│   ├── variables.tf    # Variables (IPs, RAM, CPU, etc.)
│   ├── vms.tf          # Définition des 4 VMs
│   └── outputs.tf      # IPs et IDs en sortie
│
├── ansible/            # Configuration des VMs
│   ├── ansible.cfg
│   ├── inventory/      # Inventaire des machines
│   ├── playbooks/      # site.yml + playbooks par service
│   └── roles/          # common, traefik, docker, k3s, postgresql
│
├── host/               # Configs de référence du host Proxmox
│   ├── network/        # /etc/network/interfaces, sysctl
│   ├── firewall/       # nftables.conf
│   └── templates/      # Scripts : template cloud-init, Tailscale, repos
│
├── k3s/                # Kubernetes
│   ├── manifests/      # Namespaces, deployments
│   └── helm/           # Charts Helm (à venir)
│
├── scripts/            # Helpers
│   ├── deploy-vm.sh    # Créer une VM en une commande
│   └── backup-proxmox.sh
│
├── docs/               # Documentation complémentaire
│   ├── ip-plan.md      # Plan d'adressage complet
│   └── tailscale-acl.json
│
├── PLAN-PROXMOX.md     # Plan initial détaillé (référence)
└── architecture.html   # Schéma visuel de l'archi
```

## Prérequis

- Terraform >= 1.5
- Ansible >= 2.15
- kubectl
- Accès Tailscale au réseau (subnet route 10.10.10.0/24 approuvé)
- Clé SSH configurée sur les machines

## Quickstart

### 1. Provisionner les VMs avec Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Éditer terraform.tfvars avec tes valeurs

terraform init
terraform plan
terraform apply
```

### 2. Configurer les VMs avec Ansible

```bash
cd ansible
cp inventory/hosts.yml.example inventory/hosts.yml
# Éditer hosts.yml avec les IPs Tailscale

# Tout provisionner d'un coup
ansible-playbook playbooks/site.yml

# Ou service par service
ansible-playbook playbooks/base.yml      # Config de base (toutes VMs)
ansible-playbook playbooks/gateway.yml   # Traefik
ansible-playbook playbooks/db.yml        # PostgreSQL
ansible-playbook playbooks/docker.yml    # Docker
ansible-playbook playbooks/k3s.yml       # K3s
```

### 3. Accéder à K3s depuis ton laptop

```bash
# Le kubeconfig est récupéré automatiquement par Ansible
export KUBECONFIG=./k3s/kubeconfig.yaml
kubectl get nodes
```

### 4. Créer une VM à la volée

```bash
./scripts/deploy-vm.sh --name dev-api --ip 10.10.10.20 --ram 2048
```

## Flux du trafic web

```
Internet :443 → iptables DNAT → Traefik (10.10.10.2) → Nginx (10.10.10.4:8080)
                                                      → Fastify (10.10.10.4:3000)
```

## Accès admin (Tailscale uniquement)

| Service | URL |
|---|---|
| Proxmox | https://100.78.114.17:8006 |
| Traefik dashboard | http://100.106.59.13:8080 |
| Uptime Kuma | http://100.79.77.93:3001 |
| PostgreSQL | 100.114.242.60:5432 |
| K3s API | https://100.78.207.119:6443 |

## Sécurité

- SSH par clé uniquement (password désactivé)
- SSH public fermé → accès via Tailscale SSH
- Interface Proxmox (8006) → Tailscale only
- Seuls ports 80/443 ouverts sur IP publique
- fail2ban sur toutes les VMs
- Mises à jour automatiques (unattended-upgrades)
- Backups Proxmox quotidiennes (snapshot, rétention 7j)

## Services en production

| Service | Domaine | Hébergement |
|---|---|---|
| rebours.studio | rebours.studio | VM docker (nginx + fastify) |
| Uptime Kuma | — (Tailscale) | VM docker |

## Disaster recovery

Pour remonter l'infra from scratch :

1. Installer Proxmox VE 9 sur le dédié OVH
2. Appliquer les configs host (`host/network/`, `host/firewall/`)
3. Exécuter les scripts (`host/templates/disable-enterprise-repo.sh`, `tailscale-setup.sh`, `create-template.sh`)
4. `terraform apply` pour recréer les VMs
5. `ansible-playbook playbooks/site.yml` pour tout configurer
6. Restaurer les données PostgreSQL depuis les backups
7. Redéployer les services Docker (docker-compose up -d)
