#!/bin/bash
# Supprimer le popup "no subscription" et configurer les repos Proxmox
set -euo pipefail

echo "=== Configuration des repos Proxmox ==="

# Ajouter le repo no-subscription
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list

# Commenter le repo enterprise
if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
    sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list
fi

apt update

echo "=== Repos configurés ==="
