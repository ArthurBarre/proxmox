#!/bin/bash
# Script de création du template Debian 12 cloud-init sur Proxmox
# À exécuter sur le host Proxmox en root
set -euo pipefail

TEMPLATE_ID=9000
TEMPLATE_NAME="debian12-template"
STORAGE="local-lvm"
IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
IMAGE_FILE="/var/lib/vz/template/iso/debian-12-genericcloud-amd64.qcow2"
SSH_KEYS="/root/.ssh/authorized_keys"

echo "=== Création du template $TEMPLATE_NAME (ID: $TEMPLATE_ID) ==="

# Télécharger l'image si absente
if [ ! -f "$IMAGE_FILE" ]; then
    echo "Téléchargement de l'image cloud Debian 12..."
    wget -O "$IMAGE_FILE" "$IMAGE_URL"
fi

# Supprimer si le template existe déjà
if qm status $TEMPLATE_ID &>/dev/null; then
    echo "Template $TEMPLATE_ID existe déjà, suppression..."
    qm destroy $TEMPLATE_ID --purge
fi

echo "Création de la VM..."
qm create $TEMPLATE_ID \
    --name "$TEMPLATE_NAME" \
    --memory 2048 \
    --cores 2 \
    --net0 virtio,bridge=vmbr1

echo "Import du disque..."
qm importdisk $TEMPLATE_ID "$IMAGE_FILE" $STORAGE

echo "Configuration du disque et du boot..."
qm set $TEMPLATE_ID --scsihw virtio-scsi-pci --scsi0 ${STORAGE}:vm-${TEMPLATE_ID}-disk-0
qm set $TEMPLATE_ID --boot c --bootdisk scsi0
qm set $TEMPLATE_ID --ide2 ${STORAGE}:cloudinit
qm set $TEMPLATE_ID --serial0 socket --vga serial0
qm set $TEMPLATE_ID --agent enabled=1

echo "Configuration cloud-init..."
qm set $TEMPLATE_ID --ciuser arthur
if [ -f "$SSH_KEYS" ]; then
    qm set $TEMPLATE_ID --sshkeys "$SSH_KEYS"
fi
qm set $TEMPLATE_ID --ipconfig0 ip=dhcp
qm set $TEMPLATE_ID --nameserver 1.1.1.1
qm set $TEMPLATE_ID --searchdomain local

echo "Conversion en template..."
qm template $TEMPLATE_ID

echo "=== Template $TEMPLATE_NAME créé avec succès ==="
echo ""
echo "Pour cloner : qm clone $TEMPLATE_ID <VMID> --name <nom> --full"
