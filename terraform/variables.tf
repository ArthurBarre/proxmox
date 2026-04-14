# ─── Proxmox Connection ───────────────────────────────────────────────────────

variable "proxmox_endpoint" {
  description = "URL de l'API Proxmox (via Tailscale de préférence)"
  type        = string
  default     = "https://100.78.114.17:8006/"
}

variable "proxmox_username" {
  description = "Utilisateur Proxmox API"
  type        = string
  default     = "root@pam"
}

variable "proxmox_password" {
  description = "Mot de passe Proxmox"
  type        = string
  sensitive   = true
}

# ─── Node ─────────────────────────────────────────────────────────────────────

variable "proxmox_node" {
  description = "Nom du node Proxmox"
  type        = string
  default     = "ns3142338"
}

variable "template_id" {
  description = "ID du template Debian 12 cloud-init"
  type        = number
  default     = 9000
}

# ─── SSH ──────────────────────────────────────────────────────────────────────

variable "ssh_user" {
  description = "Utilisateur SSH pour les VMs"
  type        = string
  default     = "arthur"
}

variable "ssh_public_key" {
  description = "Chemin vers la clé publique SSH"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

# ─── Network ──────────────────────────────────────────────────────────────────

variable "private_bridge" {
  description = "Nom du bridge privé Proxmox"
  type        = string
  default     = "vmbr1"
}

variable "gateway_ip" {
  description = "Passerelle du réseau privé"
  type        = string
  default     = "10.10.10.1"
}

variable "nameserver" {
  description = "Serveur DNS"
  type        = string
  default     = "1.1.1.1"
}

# ─── VMs ──────────────────────────────────────────────────────────────────────

variable "vms" {
  description = "Map des VMs à créer"
  type = map(object({
    vmid    = number
    cores   = number
    memory  = number
    disk_gb = number
    ip      = string
    tags    = optional(list(string), [])
  }))
  default = {
    gateway = {
      vmid    = 100
      cores   = 1
      memory  = 1024
      disk_gb = 10
      ip      = "10.10.10.2"
      tags    = ["traefik", "gateway"]
    }
    db = {
      vmid    = 101
      cores   = 2
      memory  = 2048
      disk_gb = 30
      ip      = "10.10.10.3"
      tags    = ["postgresql", "database"]
    }
    docker = {
      vmid    = 102
      cores   = 2
      memory  = 4096
      disk_gb = 40
      ip      = "10.10.10.4"
      tags    = ["docker", "apps"]
    }
    k3s-master = {
      vmid    = 103
      cores   = 2
      memory  = 4096
      disk_gb = 30
      ip      = "10.10.10.5"
      tags    = ["k3s", "kubernetes"]
    }
    pi-gen = {
      vmid    = 110
      cores   = 4
      memory  = 4096
      disk_gb = 40
      ip      = "10.10.10.10"
      tags    = ["build", "pi-gen"]
    }
  }
}
