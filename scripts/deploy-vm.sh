#!/bin/bash
# Script helper pour créer et provisionner une VM rapidement
# Usage: ./scripts/deploy-vm.sh --name dev-api --ip 10.10.10.20 --ram 2048
set -euo pipefail

# Defaults
TEMPLATE_ID=9000
CORES=2
RAM=2048
DISK=20
BRIDGE="vmbr1"
GATEWAY="10.10.10.1"

usage() {
    echo "Usage: $0 --name <name> --ip <ip> [--vmid <id>] [--ram <mb>] [--cores <n>] [--disk <gb>]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --name) NAME="$2"; shift 2 ;;
        --ip) IP="$2"; shift 2 ;;
        --vmid) VMID="$2"; shift 2 ;;
        --ram) RAM="$2"; shift 2 ;;
        --cores) CORES="$2"; shift 2 ;;
        --disk) DISK="$2"; shift 2 ;;
        --template) TEMPLATE_ID="$2"; shift 2 ;;
        *) usage ;;
    esac
done

[[ -z "${NAME:-}" || -z "${IP:-}" ]] && usage

# Auto-generate VMID if not provided
if [[ -z "${VMID:-}" ]]; then
    VMID=$(ssh proxmox "qm list | tail -n+2 | awk '{print \$1}' | sort -n | tail -1")
    VMID=$((VMID + 1))
fi

echo "=== Création de la VM $NAME (ID: $VMID, IP: $IP) ==="

echo "1/3 — Clone du template $TEMPLATE_ID..."
ssh proxmox "qm clone $TEMPLATE_ID $VMID --name $NAME --full"

echo "2/3 — Configuration..."
ssh proxmox "qm set $VMID --cores $CORES --memory $RAM"
ssh proxmox "qm resize $VMID scsi0 ${DISK}G"
ssh proxmox "qm set $VMID --ipconfig0 ip=${IP}/24,gw=${GATEWAY}"

echo "3/3 — Démarrage..."
ssh proxmox "qm start $VMID"

echo ""
echo "=== VM $NAME créée ==="
echo "  IP privée : $IP"
echo "  Accès SSH : ssh arthur@$IP (via Tailscale subnet routing)"
echo ""
echo "Pour provisionner avec Ansible :"
echo "  cd ansible && ansible-playbook playbooks/base.yml --limit $NAME"
