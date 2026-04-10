#!/bin/bash
# Installation et configuration de Tailscale sur le host Proxmox
# À exécuter en root sur le host
set -euo pipefail

echo "=== Installation de Tailscale ==="

# Installer Tailscale
if ! command -v tailscale &>/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
fi

# Activer le subnet routing pour le réseau privé des VMs
echo "Connexion à Tailscale avec subnet routing..."
tailscale up \
    --ssh \
    --advertise-routes=10.10.10.0/24 \
    --accept-dns=false

echo ""
echo "=== Tailscale installé ==="
echo ""
echo "IMPORTANT : Active le 'subnet router' dans la console Tailscale admin !"
echo "  → https://login.tailscale.com/admin/machines"
echo "  → Clique sur cette machine → Edit route settings → Approve 10.10.10.0/24"
echo ""
echo "IP Tailscale : $(tailscale ip -4)"
