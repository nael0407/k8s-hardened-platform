#!/usr/bin/env bash
# create-vm.sh: membuat satu VM node dari base image + overlay qcow2 + seed cloud-init.
#
# Pemakaian:
#   ./create-vm.sh <nama> <mac> [vcpu] [ram_mb] [disk_gb]
# Contoh:
#   ./create-vm.sh k3s-server 52:54:00:00:00:10 4 4096 30
#
# Prasyarat:
#   - Base image ada di storage pool "default" (langkah 0.4d).
#   - DHCP reservation untuk MAC tersebut sudah dibuat di jaringan "default" (langkah 0.5a).
#   - infra/cloud-init/user-data ada di sebelah skrip ini.
set -euo pipefail

NAME="${1:?Pemakaian: $0 <nama> <mac> [vcpu] [ram_mb] [disk_gb]}"
MAC="${2:?Pemakaian: $0 <nama> <mac> [vcpu] [ram_mb] [disk_gb]}"
VCPU="${3:-4}"
RAM_MB="${4:-4096}"
DISK_GB="${5:-30}"

POOL_DIR=/var/lib/libvirt/images
BASE_IMG="$POOL_DIR/ubuntu-24.04-noble-20260926-base.img"
DISK="$POOL_DIR/$NAME.qcow2"
SEED="$POOL_DIR/$NAME-seed.iso"
CI_DIR="$(cd "$(dirname "$0")" && pwd)/cloud-init"
VIRSH="virsh --connect qemu:///system"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. Pemeriksaan awal: hentikan lebih dulu jika ada yang kurang atau bentrok.
[ -f "$BASE_IMG" ]           || { echo "Base image tidak ditemukan: $BASE_IMG"; exit 1; }
[ -f "$CI_DIR/user-data" ]   || { echo "user-data tidak ditemukan di $CI_DIR"; exit 1; }
if $VIRSH dominfo "$NAME" >/dev/null 2>&1; then
  echo "VM '$NAME' sudah ada. Hapus dulu jika ingin membuat ulang."; exit 1
fi
if [ -e "$DISK" ] || [ -e "$SEED" ]; then
  echo "Berkas disk/seed untuk '$NAME' sudah ada di $POOL_DIR."; exit 1
fi
if ! $VIRSH net-dumpxml default | grep -qi "mac='$MAC'"; then
  echo "Belum ada DHCP reservation untuk MAC $MAC. Jalankan langkah 0.5a dulu."; exit 1
fi

# 2. Disk VM: overlay qcow2 tipis yang bertumpu pada base image.
#    Base image tidak boleh dipindah atau diubah selama overlay masih dipakai.
sudo qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$DISK" "${DISK_GB}G"

# 3. Seed cloud-init: user-data bersama + meta-data khusus VM ini.
cat > "$WORK/meta-data" <<EOF
instance-id: $NAME
local-hostname: $NAME
EOF
cloud-localds "$WORK/seed.iso" "$CI_DIR/user-data" "$WORK/meta-data"
sudo install -m 0644 "$WORK/seed.iso" "$SEED"

# 4. Buat dan nyalakan VM (tanpa instalasi, langsung boot dari disk).
$VIRSH list --all >/dev/null   # memastikan koneksi ke hypervisor sistem
virt-install --connect qemu:///system \
  --name "$NAME" \
  --memory "$RAM_MB" --vcpus "$VCPU" \
  --cpu host-passthrough \
  --os-variant ubuntu24.04 \
  --boot uefi \
  --disk path="$DISK",format=qcow2,bus=virtio \
  --disk path="$SEED",device=cdrom \
  --network network=default,model=virtio,mac="$MAC" \
  --graphics none \
  --import --noautoconsole

echo
echo "VM '$NAME' dibuat. Boot pertama butuh sekitar 1-2 menit (cloud-init memasang paket)."
echo "Cek IP : virsh domifaddr $NAME --source lease"
echo "Konsol : virsh console $NAME   (keluar dengan Ctrl+])"
