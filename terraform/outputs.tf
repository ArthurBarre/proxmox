output "vm_ips" {
  description = "IPs privées de chaque VM"
  value = {
    for name, vm in proxmox_virtual_environment_vm.vm :
    name => vm.initialization[0].ip_config[0].ipv4[0].address
  }
}

output "vm_ids" {
  description = "IDs Proxmox de chaque VM"
  value = {
    for name, vm in proxmox_virtual_environment_vm.vm :
    name => vm.vm_id
  }
}
