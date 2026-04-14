# ─── VMs créées à partir du template Debian 12 cloud-init ─────────────────────

resource "proxmox_virtual_environment_vm" "vm" {
  for_each = var.vms

  name      = each.key
  node_name = var.proxmox_node
  vm_id     = each.value.vmid

  clone {
    vm_id = var.template_id
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  agent {
    enabled = true
  }

  initialization {
    datastore_id = "local"

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = var.gateway_ip
      }
    }

    dns {
      servers = [var.nameserver]
    }

    user_account {
      username = var.ssh_user
      keys     = [trimspace(file(var.ssh_public_key))]
    }
  }

  network_device {
    bridge = var.private_bridge
    model  = "virtio"
  }

  disk {
    interface    = "scsi0"
    datastore_id = "local"
    size         = each.value.disk_gb
  }

  tags = each.value.tags

  lifecycle {
    ignore_changes = [
      initialization, # Éviter les resets cloud-init après le premier apply
    ]
  }
}
