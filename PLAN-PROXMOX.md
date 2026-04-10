# Plan de configuration Proxmox 9 — OVH Dédié

**Serveur :** 51.38.62.199 (OVH, 1 IP publique unique)
**OS :** Proxmox VE 9 (fraîchement installé)
**Objectif :** Infra mixte dev/prod, automatisée, sécurisée par Tailscale

---

## Vue d'ensemble de l'architecture

```
Internet
    │
    │ :443 / :80
    ▼
┌─────────────────────────────────────────────────┐
│  PROXMOX HOST (51.38.62.199)                    │
│  ├── vmbr0 (bridge public, IP OVH)              │
│  ├── vmbr1 (bridge privé, 10.10.10.1/24)        │
│  ├── Tailscale (100.x.x.x)                      │
│  └── firewall (iptables/nftables)               │
│                                                  │
│  ┌─────────────┐  ┌─────────────┐               │
│  │ VM gateway  │  │ VM docker   │               │
│  │ Traefik     │  │ Docker host │               │
│  │ 10.10.10.2  │  │ 10.10.10.4  │               │
│  │ + Tailscale │  │ + Tailscale │               │
│  └─────────────┘  └─────────────┘               │
│  ┌─────────────┐  ┌─────────────┐               │
│  │ VM k3s      │  │ VM db       │               │
│  │ K3s master  │  │ PostgreSQL  │               │
│  │ 10.10.10.5  │  │ 10.10.10.3  │               │
│  │ + Tailscale │  │ + Tailscale │               │
│  └─────────────┘  └─────────────┘               │
└─────────────────────────────────────────────────┘
        │
    Tailscale mesh (100.x.x.x)
        │
    Ton PC / laptop
```

---

## Phase 1 — Sécurisation du host Proxmox

### 1.1 Mise à jour et hardening SSH

```bash
# Mise à jour complète
apt update && apt full-upgrade -y

# Sécuriser SSH
# /etc/ssh/sshd_config :
#   PermitRootLogin prohibit-password   (clé uniquement, déjà OK)
#   PasswordAuthentication no
#   Port 22                             (on changera via Tailscale ensuite)
#   MaxAuthTries 3
```

### 1.2 Firewall (nftables)

Stratégie : on bloque tout sauf le strict minimum sur l'IP publique.

```
Ports ouverts sur IP publique (51.38.62.199) :
  - 22/tcp    → SSH (temporaire, sera coupé une fois Tailscale OK)
  - 80/tcp    → HTTP (redirect vers HTTPS via Traefik)
  - 443/tcp   → HTTPS (Traefik)

Ports ouverts sur Tailscale uniquement (100.x.x.x) :
  - 8006/tcp  → Interface web Proxmox
  - 22/tcp    → SSH
  - Tout le reste (admin, monitoring, etc.)
```

### 1.3 Installer Tailscale sur le host

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --ssh --advertise-routes=10.10.10.0/24
```

**Points clés :**
- `--ssh` : active Tailscale SSH (tu pourras couper le SSH classique sur l'IP publique ensuite)
- `--advertise-routes` : permet d'accéder au réseau privé des VMs depuis ton laptop via Tailscale
- Activer le "subnet router" dans la console admin Tailscale

### 1.4 Désactiver l'abonnement entreprise (repo)

```bash
# Supprimer le popup "no subscription"
# Ajouter le repo no-subscription de Proxmox
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list
# Commenter le repo enterprise
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list
apt update
```

---

## Phase 2 — Configuration réseau

### 2.1 Bridges réseau

Avec **1 seule IP publique**, la stratégie est :

- **vmbr0** : bridge lié à l'interface physique, porte l'IP publique OVH → reste sur le host uniquement
- **vmbr1** : bridge privé interne (NAT) → toutes les VMs s'y connectent

```
# /etc/network/interfaces (à adapter selon ton interface physique)

auto lo
iface lo inet loopback

# Bridge public (IP OVH)
auto vmbr0
iface vmbr0 inet static
    address 51.38.62.199/24
    gateway 51.38.62.254        # ← vérifier la gateway OVH réelle
    bridge-ports eno1            # ← adapter au nom de ton interface
    bridge-stp off
    bridge-fd 0

# Bridge privé (réseau interne VMs)
auto vmbr1
iface vmbr1 inet static
    address 10.10.10.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0

    # NAT : les VMs accèdent à internet via le host
    post-up   iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s 10.10.10.0/24 -o vmbr0 -j MASQUERADE

    # Forwarding HTTP/HTTPS vers la VM gateway (Traefik)
    post-up   iptables -t nat -A PREROUTING -i vmbr0 -p tcp --dport 80  -j DNAT --to 10.10.10.2:80
    post-up   iptables -t nat -A PREROUTING -i vmbr0 -p tcp --dport 443 -j DNAT --to 10.10.10.2:443
    post-down iptables -t nat -D PREROUTING -i vmbr0 -p tcp --dport 80  -j DNAT --to 10.10.10.2:80
    post-down iptables -t nat -D PREROUTING -i vmbr0 -p tcp --dport 443 -j DNAT --to 10.10.10.2:443
```

### 2.2 Activer le forwarding IP

```bash
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p
```

### 2.3 Plan d'adressage

| IP privée     | Nom VM         | Rôle                          |
|---------------|----------------|-------------------------------|
| 10.10.10.1    | proxmox (host) | Hyperviseur                   |
| 10.10.10.2    | gateway        | Traefik (reverse proxy)       |
| 10.10.10.3    | db             | PostgreSQL / MariaDB          |
| 10.10.10.4    | docker         | Docker host (services divers) |
| 10.10.10.5    | k3s-master     | K3s control plane             |
| 10.10.10.6-9  | k3s-worker-N   | K3s workers (optionnel)       |
| 10.10.10.10+  | VMs à la volée | Créées par Terraform          |

---

## Phase 3 — Template Debian LTS (Cloud-Init)

### 3.1 Créer le template de base

On utilise une image cloud Debian 12 (Bookworm) avec cloud-init pour pouvoir déployer des VMs en 30 secondes.

```bash
# Télécharger l'image cloud Debian 12
cd /var/lib/vz/template/iso/
wget https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2

# Créer la VM template (ID 9000)
qm create 9000 --name "debian12-template" --memory 2048 --cores 2 --net0 virtio,bridge=vmbr1

# Importer le disque
qm importdisk 9000 debian-12-genericcloud-amd64.qcow2 local-lvm

# Attacher le disque
qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9000-disk-0

# Configurer le boot et cloud-init
qm set 9000 --boot c --bootdisk scsi0
qm set 9000 --ide2 local-lvm:cloudinit
qm set 9000 --serial0 socket --vga serial0
qm set 9000 --agent enabled=1

# Cloud-init : config par défaut
qm set 9000 --ciuser arthur
qm set 9000 --sshkeys ~/.ssh/authorized_keys
qm set 9000 --ipconfig0 ip=dhcp
# Ou pour IP statique : --ipconfig0 ip=10.10.10.X/24,gw=10.10.10.1
qm set 9000 --nameserver 1.1.1.1
qm set 9000 --searchdomain local

# Convertir en template
qm template 9000
```

### 3.2 Variantes de templates

| Template ID | Nom                  | Base          | Spécificités                              |
|-------------|----------------------|---------------|-------------------------------------------|
| 9000        | debian12-base        | Debian 12     | Cloud-init, minimal                       |
| 9001        | debian12-docker      | Clone de 9000 | + Docker CE, docker-compose préinstallés  |
| 9002        | debian12-k3s         | Clone de 9000 | + K3s préinstallé                         |
| 9003        | debian12-tailscale   | Clone de 9000 | + Tailscale préinstallé avec auth key     |

Pour créer les variantes, on clone le template de base, on le démarre temporairement, on installe les paquets, puis on re-template. Ansible automatisera ça (voir Phase 5).

---

## Phase 4 — VMs principales

### 4.1 VM Gateway (Traefik)

```
ID: 100 | RAM: 1 Go | CPU: 1 | Disque: 10 Go | IP: 10.10.10.2
```

- **Traefik v3** en reverse proxy
- Certificats Let's Encrypt automatiques
- Dashboard accessible uniquement via Tailscale
- Route le trafic :80/:443 vers les VMs/containers internes
- Tailscale installé

### 4.2 VM Database

```
ID: 101 | RAM: 2 Go | CPU: 2 | Disque: 30 Go | IP: 10.10.10.3
```

- PostgreSQL 16
- Accessible uniquement via réseau privé (10.10.10.0/24) et Tailscale
- Backups automatisés (pg_dump + cron vers stockage)
- Tailscale installé

### 4.3 VM Docker

```
ID: 102 | RAM: 4 Go | CPU: 2 | Disque: 40 Go | IP: 10.10.10.4
```

- Docker CE + Docker Compose
- Pour les services "standalone" : Portainer, Gitea, Nextcloud, etc.
- Les services web sont exposés via Traefik (réseau interne)
- Tailscale installé

### 4.4 VM K3s Master

```
ID: 103 | RAM: 4 Go | CPU: 2 | Disque: 30 Go | IP: 10.10.10.5
```

- K3s (Kubernetes léger) — control plane
- kubectl accessible via Tailscale depuis ton PC
- Ingress via Traefik (celui de la VM gateway, pas celui intégré à K3s)
- Tailscale installé

---

## Phase 5 — Infrastructure as Code (Terraform + Ansible)

### 5.1 Structure du projet

```
infra/
├── terraform/
│   ├── main.tf              # Provider Proxmox + backend
│   ├── variables.tf         # Variables (IP, RAM, CPU, etc.)
│   ├── vms.tf               # Définition des VMs
│   ├── outputs.tf           # IPs des VMs créées
│   └── terraform.tfvars     # Valeurs spécifiques à ton env
│
├── ansible/
│   ├── inventory/
│   │   └── hosts.yml        # Inventaire (peut être généré par Terraform)
│   ├── playbooks/
│   │   ├── base.yml         # Config commune (users, SSH, paquets, Tailscale)
│   │   ├── gateway.yml      # Install Traefik
│   │   ├── docker.yml       # Install Docker
│   │   ├── k3s.yml          # Install K3s
│   │   └── db.yml           # Install PostgreSQL
│   ├── roles/
│   │   ├── common/          # Hardening, Tailscale, fail2ban
│   │   ├── traefik/
│   │   ├── docker/
│   │   ├── k3s/
│   │   └── postgresql/
│   └── ansible.cfg
│
├── scripts/
│   └── create-vm.sh         # Script rapide pour créer une VM à la volée
│
└── README.md
```

### 5.2 Terraform — Provider Proxmox

```hcl
# main.tf
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"    # Provider maintenu activement
      version = ">= 0.66.0"
    }
  }
}

provider "proxmox" {
  endpoint = "https://100.x.x.x:8006/"   # Accès via Tailscale !
  username = "root@pam"
  password = var.proxmox_password
  insecure = true                          # Self-signed cert Proxmox
}
```

```hcl
# vms.tf — Exemple de création d'une VM à partir du template
resource "proxmox_virtual_environment_vm" "docker" {
  name      = "docker"
  node_name = "proxmox"

  clone {
    vm_id = 9001    # template debian12-docker
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 4096
  }

  initialization {
    ip_config {
      ipv4 {
        address = "10.10.10.4/24"
        gateway = "10.10.10.1"
      }
    }
    user_account {
      username = "arthur"
      keys     = [file("~/.ssh/id_ed25519.pub")]
    }
  }

  network_device {
    bridge = "vmbr1"
  }
}
```

### 5.3 Ansible — Playbook de base

```yaml
# playbooks/base.yml
---
- name: Configuration de base pour toutes les VMs
  hosts: all
  become: true
  tasks:
    - name: Mise à jour des paquets
      apt:
        update_cache: yes
        upgrade: dist

    - name: Installer les paquets essentiels
      apt:
        name:
          - curl
          - wget
          - vim
          - htop
          - ufw
          - unattended-upgrades
          - qemu-guest-agent
        state: present

    - name: Activer qemu-guest-agent
      systemd:
        name: qemu-guest-agent
        enabled: true
        state: started

    - name: Installer Tailscale
      shell: curl -fsSL https://tailscale.com/install.sh | sh
      args:
        creates: /usr/bin/tailscale

    - name: Connecter à Tailscale
      command: tailscale up --authkey={{ tailscale_auth_key }}
      environment:
        TS_AUTHKEY: "{{ tailscale_auth_key }}"
```

### 5.4 Workflow pour créer une VM "à la volée"

```bash
# 1. Ajouter la VM dans terraform/vms.tf (ou un .tf dédié)
# 2. Appliquer
cd infra/terraform
terraform plan
terraform apply

# 3. Provisionner avec Ansible
cd ../ansible
ansible-playbook -i inventory/hosts.yml playbooks/base.yml --limit nouvelle-vm

# OU en une commande avec le script helper :
./scripts/create-vm.sh --name "dev-api" --ip "10.10.10.20" --ram 2048 --template 9001
```

---

## Phase 6 — Tailscale (VPN mesh)

### 6.1 Architecture Tailscale

```
Tailscale Network (tailnet)
│
├── proxmox-host    (100.x.x.1)  ← subnet router pour 10.10.10.0/24
├── vm-gateway      (100.x.x.2)
├── vm-docker       (100.x.x.3)
├── vm-k3s          (100.x.x.4)
├── vm-db           (100.x.x.5)
│
├── arthur-laptop   (100.x.x.10) ← ton PC perso
└── arthur-phone    (100.x.x.11) ← ton tel (optionnel)
```

### 6.2 Configuration recommandée

- **ACLs Tailscale** (dans la console admin) : définir qui peut accéder à quoi
- **Tailscale SSH** : activé sur toutes les machines → plus besoin de gérer les clés SSH manuellement
- **MagicDNS** : activé → tu accèdes à tes VMs par nom (`ssh vm-docker` au lieu de `ssh 100.x.x.3`)
- **Exit node** : optionnel, tu peux utiliser ton serveur comme VPN pour naviguer
- **Auth keys** : générer une auth key réutilisable pour Ansible (provisionnement automatique)

### 6.3 ACL recommandée

```json
{
  "acls": [
    // Arthur a accès à tout
    {"action": "accept", "src": ["arthur@github"], "dst": ["*:*"]},
    // Les VMs peuvent communiquer entre elles sur le réseau privé
    {"action": "accept", "src": ["tag:server"], "dst": ["tag:server:*"]},
  ],
  "tagOwners": {
    "tag:server": ["arthur@github"]
  }
}
```

---

## Phase 7 — Monitoring et backups

### 7.1 Monitoring (léger)

Sur la VM Docker, déployer :
- **Uptime Kuma** : monitoring des services (HTTP checks, ping, etc.)
- **Netdata** ou **Grafana + Prometheus** : métriques système
- Accessible via Tailscale uniquement

### 7.2 Backups Proxmox

```bash
# Backup automatique via Proxmox (Datacenter > Backup)
# Schedule : tous les jours à 3h du matin
# Storage : local (ou un NFS/S3 si tu veux de l'offsite)
# Mode : snapshot (pas de downtime)
# Retention : 7 jours
```

- Configurer un stockage Proxmox Backup Server (PBS) si besoin de déduplication
- Ou exporter vers un bucket S3 compatible (Backblaze B2, Wasabi, OVH Object Storage)

---

## Ordre d'exécution recommandé

| Étape | Action                                          | Durée estimée |
|-------|-------------------------------------------------|---------------|
| 1     | Mise à jour Proxmox + hardening SSH             | 15 min        |
| 2     | Config réseau (vmbr1 + NAT + forwarding)        | 30 min        |
| 3     | Installer Tailscale sur le host                  | 10 min        |
| 4     | Créer le template Debian 12 cloud-init           | 20 min        |
| 5     | Créer les variantes de templates                 | 30 min        |
| 6     | Déployer la VM gateway (Traefik)                 | 30 min        |
| 7     | Déployer la VM Docker                            | 20 min        |
| 8     | Déployer la VM DB                                | 20 min        |
| 9     | Déployer la VM K3s                               | 30 min        |
| 10    | Mettre en place Terraform (provider + VMs)       | 45 min        |
| 11    | Mettre en place Ansible (roles + playbooks)      | 1h            |
| 12    | Configurer les ACLs Tailscale                    | 15 min        |
| 13    | Monitoring + backups                             | 30 min        |
| **Total** |                                             | **~5-6h**     |

---

## Checklist de sécurité finale

- [ ] SSH par clé uniquement (pas de password)
- [ ] SSH sur IP publique fermé (accès via Tailscale SSH uniquement)
- [ ] Interface Proxmox (8006) accessible uniquement via Tailscale
- [ ] Firewall : seuls ports 80/443 ouverts sur IP publique
- [ ] Tailscale installé sur toutes les VMs
- [ ] ACLs Tailscale configurées
- [ ] Backups Proxmox activées
- [ ] Mises à jour automatiques (unattended-upgrades) sur toutes les VMs
- [ ] fail2ban installé sur le host et les VMs exposées
