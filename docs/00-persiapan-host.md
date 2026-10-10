# 00. Persiapan Host: Virtualisasi KVM/libvirt

Tanggal pengerjaan: 2026-10-10
Fase: 0 (langkah 0.1 dan 0.2)

## Tujuan

Menyiapkan hypervisor di laptop sebagai fondasi lab. Semua VM klaster k3s (1 server + 2 agent) akan berjalan di atas KVM/libvirt, sehingga node memiliki kernel dan OS sendiri. Hal ini penting untuk bagian eBPF (Cilium dan Tetragon) yang bergantung pada kernel node.

## Spesifikasi host

| Komponen | Nilai |
|---|---|
| Perangkat | Lenovo Legion Pro 5 16IRX9 |
| CPU | Intel Core i9-14900HX, 32 thread, VT-x |
| RAM | 31 GiB (kelas 32 GB), swap 8 GiB |
| Disk root | 460 GB, sekitar 348 GB kosong |
| OS | Ubuntu 24.04.5 LTS (dual-boot dengan Windows) |
| Kernel | 7.0.0-34-generic |

## Langkah 0.1: verifikasi dasar virtualisasi

Perintah:

```bash
lscpu | grep -E "Model name|Virtualization|^CPU\(s\)"
free -h
df -h /
cat /etc/os-release | head -n 4
uname -r
ls -l /dev/kvm
grep -c -E 'vmx' /proc/cpuinfo
```

Output penting:

```text
CPU(s):                                  32
Model name:                              Intel(R) Core(TM) i9-14900HX
Virtualization:                          VT-x

              total        used        free      shared  buff/cache   available
Mem:            31Gi       5.5Gi        22Gi       1.1Gi       4.3Gi        25Gi
Swap:          8.0Gi          0B       8.0Gi

Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p4  460G   90G  348G  21% /

PRETTY_NAME="Ubuntu 24.04.5 LTS"
7.0.0-34-generic
crw-rw----+ 1 root kvm 10, 232 Oct 10 12:08 /dev/kvm
64
```

Catatan tentang angka `vmx` = 64: `lscpu` melaporkan 32 CPU, tetapi `grep -c vmx` menghasilkan 64. Penyebabnya, `/proc/cpuinfo` pada CPU Intel memuat dua baris yang mengandung kata "vmx" untuk setiap thread (baris `flags` dan baris `vmx flags`), sehingga 32 x 2 = 64. Artinya VT-x aktif di semua thread.

## Langkah 0.2: instalasi KVM/libvirt

Perintah:

```bash
sudo apt update
sudo apt install -y qemu-system-x86 libvirt-daemon-system libvirt-clients virtinst cloud-image-utils
sudo usermod -aG libvirt,kvm $USER
```

Fungsi paket:

| Paket | Fungsi |
|---|---|
| `qemu-system-x86` | Emulator/hypervisor yang memakai akselerasi KVM |
| `libvirt-daemon-system` | Layanan libvirt yang mengelola VM dan jaringan virtual |
| `libvirt-clients` | Perintah `virsh` untuk mengelola libvirt dari terminal |
| `virtinst` | `virt-install` untuk membuat VM dari terminal |
| `cloud-image-utils` | `cloud-localds` untuk membuat disk cloud-init (user dan SSH key otomatis) |

Pesan di log instalasi yang tampak seperti error tetapi tidak berbahaya: peringatan UID `libvirt-qemu` yang lebih besar dari `SYS_UID_MAX` (UID tetap bawaan Ubuntu), dan `dm-event.service is a disabled or a static unit` (layanan LVM opsional).

## Verifikasi

```bash
kvm-ok
virsh list --all
virsh net-list --all
virsh version
```

Output:

```text
INFO: /dev/kvm exists
KVM acceleration can be used

 Id   Name   State
--------------------

 Name      State    Autostart   Persistent
--------------------------------------------
 default   active   yes         yes

Compiled against library: libvirt 10.0.0
Using library: libvirt 10.0.0
Using API: QEMU 10.0.0
Running hypervisor: QEMU 8.2.2
```

Catatan: baris `Using API: QEMU 10.0.0` adalah versi API driver QEMU di libvirt (selalu sama dengan versi libvirt), bukan versi QEMU yang berjalan. Versi QEMU sebenarnya ada di baris `Running hypervisor`, yaitu 8.2.2.

## Versi komponen

| Komponen | Versi |
|---|---|
| Ubuntu | 24.04.5 LTS |
| Kernel host | 7.0.0-34-generic |
| libvirt | 10.0.0 |
| QEMU | 8.2.2 |

## Masalah dan keputusan

**1. `Permission denied` pada socket libvirt**

- Gejala: `virsh -c qemu:///system list --all` menghasilkan `Failed to connect socket to '/var/run/libvirt/libvirt-sock': Permission denied`, dan `id` tidak menampilkan grup `libvirt`.
- Penyebab: Linux membaca keanggotaan grup hanya saat login. `usermod -aG` mengubah `/etc/group` seketika, tetapi sesi yang sedang berjalan masih membawa daftar grup lama.
- Diagnosis: `groups $USER` (membaca `/etc/group`) sudah menampilkan `libvirt` dan `kvm`, sedangkan `id` (membaca sesi aktif) belum.
- Solusi: `newgrp libvirt` untuk pengujian cepat di satu terminal, lalu logout dan login ulang agar berlaku di semua terminal.

**2. `kvm-ok` berhasil walau grup `kvm` belum aktif**

`/dev/kvm` memiliki ACL (tanda `+` pada izin `crw-rw----+`) yang memberi akses ke pengguna yang login di desktop. Socket libvirt tidak memiliki ACL seperti itu, sehingga hanya grup `libvirt` yang bisa mengaksesnya.

**3. Koneksi bawaan `virsh`: `qemu:///system` vs `qemu:///session`**

Tanpa opsi `-c`, `virsh` untuk user biasa terhubung ke `qemu:///session`, hypervisor milik user yang terpisah dari sistem. VM yang dibuat di `system` tidak akan terlihat di sana. Keputusan: set `LIBVIRT_DEFAULT_URI="qemu:///system"` di `~/.bashrc` agar semua perintah konsisten.

**4. Hal yang perlu diwaspadai: Docker dan libvirt di host yang sama**

Pengguna tergabung di grup `docker`. Keduanya mengelola aturan firewall di host, dan pada sebagian konfigurasi dapat saling mengganggu (VM di jaringan NAT libvirt kehilangan akses internet). Belum terjadi. Akan diuji saat VM pertama mengunduh paket.

## Status

- [x] 0.1 Verifikasi dasar virtualisasi
- [x] 0.2 Instalasi KVM/libvirt, jaringan `default` aktif dan autostart
- [ ] Verifikasi setelah login ulang (grup `libvirt` aktif di semua terminal, `virsh list --all` tanpa `-c`)
- [ ] 0.3 Pemeriksaan jaringan virtual libvirt
