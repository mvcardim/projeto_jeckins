#!/bin/bash

# Script para expandir automaticamente LVM no Ubuntu
# Versão corrigida com melhor tratamento de erros

set -e

# Função para log com timestamp
log() {
    echo "$(date '+%H:%M:%S') $1"
}

# Função para verificar se comando existe
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "❌ Comando '$1' não encontrado. Instale com: apt-get install $2"
        exit 1
    fi
}

# Verificar se está executando como root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Este script precisa ser executado como root (use sudo)"
    exit 1
fi

# Verificar comandos necessários
log "🔍 Verificando dependências..."
check_command "growpart" "cloud-guest-utils"
check_command "pvresize" "lvm2"
check_command "lvextend" "lvm2"
check_command "resize2fs" "e2fsprogs"

log "🔎 Detectando disco principal..."

# Melhor detecção do dispositivo raiz
ROOT_DEVICE=$(df / | tail -1 | awk '{print $1}')
log "➡️ Dispositivo raiz: $ROOT_DEVICE"

# Verificar se é LVM
if [[ ! $ROOT_DEVICE =~ /dev/mapper/ ]] && [[ ! $ROOT_DEVICE =~ /dev/.*/.* ]]; then
    echo "❌ O sistema raiz não parece usar LVM: $ROOT_DEVICE"
    exit 1
fi

# Detectar disco e partição física
if [[ $ROOT_DEVICE =~ /dev/mapper/ ]]; then
    # Para LVM, encontrar o PV subjacente
    PV_DEVICE=$(pvdisplay | grep -B1 "$(lvdisplay $ROOT_DEVICE | grep 'VG Name' | awk '{print $3}')" | grep 'PV Name' | awk '{print $3}' | head -1)
    if [ -z "$PV_DEVICE" ]; then
        echo "❌ Não foi possível detectar o Physical Volume"
        exit 1
    fi
    PART_DEVICE="$PV_DEVICE"
else
    PART_DEVICE="$ROOT_DEVICE"
fi

log "➡️ Partição física: $PART_DEVICE"

# Detectar disco base e número da partição
if [[ $PART_DEVICE =~ /dev/nvme ]]; then
    # Para NVMe (ex: /dev/nvme0n1p1)
    DISK=$(echo "$PART_DEVICE" | sed 's/p[0-9]*$//')
    PART_NUM=$(echo "$PART_DEVICE" | grep -o 'p[0-9]*$' | tr -d 'p')
elif [[ $PART_DEVICE =~ /dev/sd ]] || [[ $PART_DEVICE =~ /dev/vd ]]; then
    # Para SATA/SCSI/VirtIO (ex: /dev/sda1, /dev/vda1)
    DISK=$(echo "$PART_DEVICE" | sed 's/[0-9]*$//')
    PART_NUM=$(echo "$PART_DEVICE" | grep -o '[0-9]*$')
else
    echo "❌ Tipo de disco não reconhecido: $PART_DEVICE"
    exit 1
fi

log "➡️ Disco base: $DISK | Partição número: $PART_NUM"

# Verificar se o disco e partição existem
if [ ! -b "$DISK" ]; then
    echo "❌ Disco não encontrado: $DISK"
    exit 1
fi

if [ ! -b "$PART_DEVICE" ]; then
    echo "❌ Partição não encontrada: $PART_DEVICE"
    exit 1
fi

log "📏 Expandindo partição..."
if ! growpart "$DISK" "$PART_NUM"; then
    log "⚠️  growpart falhou ou a partição já está no tamanho máximo"
fi

log "📦 Redimensionando Physical Volume..."
if ! pvresize "$PART_DEVICE"; then
    echo "❌ Falha ao redimensionar o Physical Volume"
    exit 1
fi

log "🔎 Detectando Logical Volume usado pelo /..."
LV_PATH=$(df / | tail -1 | awk '{print $1}')
log "➡️ LV detectado: $LV_PATH"

# Verificar se o LV existe
if [ ! -e "$LV_PATH" ]; then
    echo "❌ Logical Volume não encontrado: $LV_PATH"
    exit 1
fi

log "➕ Expandindo Logical Volume para usar 100% do espaço livre..."
if ! lvextend -l +100%FREE "$LV_PATH"; then
    log "⚠️  LV já pode estar no tamanho máximo ou sem espaço livre"
fi

log "🔎 Detectando tipo de filesystem..."
FSTYPE=$(df -Th / | tail -1 | awk '{print $2}')
log "➡️ Filesystem detectado: $FSTYPE"

case "$FSTYPE" in
    ext2|ext3|ext4)
        log "📂 Filesystem é EXT → expandindo com resize2fs..."
        if ! resize2fs "$LV_PATH"; then
            echo "❌ Falha ao redimensionar filesystem ext"
            exit 1
        fi
        ;;
    xfs)
        log "📂 Filesystem é XFS → expandindo com xfs_growfs..."
        if ! command -v xfs_growfs &> /dev/null; then
            echo "❌ xfs_growfs não encontrado. Instale: apt-get install xfsprogs"
            exit 1
        fi
        if ! xfs_growfs /; then
            echo "❌ Falha ao redimensionar filesystem XFS"
            exit 1
        fi
        ;;
    *)
        echo "❌ Tipo de filesystem não suportado automaticamente: $FSTYPE"
        echo "ℹ️  Você pode precisar redimensionar manualmente"
        exit 1
        ;;
esac

log "✅ Expansão concluída com sucesso!"
echo ""
echo "📊 Espaço em disco após expansão:"
df -h /

echo ""
echo "📈 Informações do LVM:"
lvdisplay "$LV_PATH" | grep -E "(LV Name|LV Size)"