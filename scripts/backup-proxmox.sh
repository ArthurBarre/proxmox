#!/bin/bash
# Script pour lancer un backup de toutes les VMs Proxmox
# À exécuter via cron ou manuellement sur le host
set -euo pipefail

BACKUP_STORAGE="local"
BACKUP_MODE="snapshot"
COMPRESS="zstd"

echo "=== Backup Proxmox — $(date) ==="

# Lister toutes les VMs qui tournent
VMS=$(qm list | tail -n+2 | awk '$3 == "running" {print $1}')

for VMID in $VMS; do
    VM_NAME=$(qm config $VMID | grep "^name:" | awk '{print $2}')
    echo "Backup VM $VMID ($VM_NAME)..."
    vzdump $VMID \
        --storage $BACKUP_STORAGE \
        --mode $BACKUP_MODE \
        --compress $COMPRESS \
        --notes-template "Auto backup $(date +%Y-%m-%d)"
done

# Nettoyage des backups > 7 jours
echo "Nettoyage des anciens backups..."
find /var/lib/vz/dump/ -name "vzdump-*" -mtime +7 -delete 2>/dev/null || true

echo "=== Backup terminé ==="
