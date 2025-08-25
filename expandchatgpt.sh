#!/bin/bash
set -e

echo "🔎 Detectando disco principal..."
DISK=$(lsblk -ndo PKNAME $(df / | tail -1 | awk '{print $1}'))
PART=$(lsblk -ndo NAME $(df / | tail -1 | awk '{print $1}'))

echo "➡️ Disco: /dev/$DISK | Partição: /dev/$PART"

echo "📏 Expandindo partição..."
sudo growpart /dev/$DISK ${PART##*[a-z]}

echo "📦 Redimensionando PV..."
sudo pvresize /dev/$PART

echo "🔎 Detectando LV usado pelo / ..."
LV_PATH=$(df / | tail -1 | awk '{print $1}')
echo "➡️ LV detectado: $LV_PATH"

echo "➕ Expandindo LV para usar 100% do espaço livre..."
sudo lvextend -l +100%FREE $LV_PATH

echo "🔎 Detectando filesystem..."
FSTYPE=$(df -Th / | tail -1 | awk '{print $2}')

if [ "$FSTYPE" == "ext4" ]; then
    echo "📂 Filesystem é EXT4 → expandindo com resize2fs..."
    sudo resize2fs $LV_PATH
elif [ "$FSTYPE" == "xfs" ]; then
    echo "📂 Filesystem é XFS → expandindo com xfs_growfs..."
    sudo xfs_growfs /
else
    echo "❌ Tipo de filesystem não suportado automaticamente: $FSTYPE"
    exit 1
fi

echo "✅ Expansão concluída!"
df -h /
