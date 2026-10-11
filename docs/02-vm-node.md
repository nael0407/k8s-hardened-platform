# 02. VM Node: base image, cloud-init, dan pembuatan tiga VM

Tanggal pengerjaan: 2026-10-10
Fase: 0 (langkah 0.4 dan 0.5)

## Tujuan

Membuat tiga VM Ubuntu yang akan menjadi node klaster k3s (1 server + 2 agent), dengan cara yang dapat diulang: seluruh konfigurasi berupa berkas dan skrip di repo, bukan langkah manual di dalam VM.

## Keputusan desain: base image + overlay + seed (bukan template lalu klon)

Rencana awal adalah membuat satu VM template lalu mengklonnya. Rencana itu diganti karena alasan berikut.

| | Template lalu klon (rencana awal) | Base image + overlay + seed (dipakai) |
|---|---|---|
| Identitas unik per VM | Klon membawa `machine-id`, SSH host key, dan pengenal DHCP yang sama, harus dibersihkan manual | Setiap VM mulai dari image bersih, bebas masalah itu |
| Reproduktibilitas | Langkah manual di dalam VM sulit didokumentasikan | Semua konfigurasi berupa berkas (`user-data`, `meta-data`) yang masuk Git |
| Disk | Salinan penuh per VM | Overlay qcow2 tipis yang bertumpu pada satu image dasar |

Konsekuensi: setiap VM memasang paket kecil di boot pertama (butuh internet). Image dasar yang menjadi backing file tidak boleh dipindah atau diubah selama masih ada overlay yang bergantung padanya.

## Storage pool

```bash
virsh pool-define-as default dir --target /var/lib/libvirt/images
virsh pool-build default
virsh pool-start default
virsh pool-autostart default
virsh pool-info default
```

```text
Name:           default
UUID:           d87fb31c-8f9c-45ee-a9f4-cff9389ecf66
State:          running
Persistent:     yes
Autostart:      yes
Capacity:       459.79 GiB
Allocation:     89.44 GiB
Available:      370.35 GiB
```

Direktori `/var/lib/libvirt/images` dipakai (bukan folder home) karena proses QEMU berjalan sebagai user `libvirt-qemu` yang umumnya tidak boleh menjelajah ke dalam home, dan AppArmor juga membatasi akses.

Selisih kapasitas: `df -h /` melaporkan 348 GB tersedia, sedangkan `pool-info` 370,35 GiB. Selisihnya sekitar 22 GiB. Pemeriksaan:

```bash
findmnt -no FSTYPE /
sudo tune2fs -l /dev/nvme0n1p4 | grep -E "Block count|Reserved block count"
```

```text
ext4
Block count:              122538752
Reserved block count:     6126925
```

6.126.925 / 122.538.752 = 5,0%, yaitu blok cadangan root bawaan ext4. libvirt menghitung ruang tersedia sebagai kapasitas dikurangi alokasi (termasuk blok cadangan), sedangkan `df` melaporkan ruang yang bisa dipakai user biasa. Angka yang dipakai untuk perencanaan: 348 GB.

## Sumber image

Image: Ubuntu 24.04 LTS (Noble) cloud image amd64, build rilis `release-20260926`.

```bash
mkdir -p ~/lab-images && cd ~/lab-images
BASE=https://cloud-images.ubuntu.com/releases/noble/release-20260926
curl -fLO $BASE/ubuntu-24.04-server-cloudimg-amd64.img
curl -fLO $BASE/SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
qemu-img info ubuntu-24.04-server-cloudimg-amd64.img
```

```text
ubuntu-24.04-server-cloudimg-amd64.img: OK

image: ubuntu-24.04-server-cloudimg-amd64.img
file format: qcow2
virtual size: 3.5 GiB (3758096384 bytes)
disk size: 597 MiB
```

Alasan memakai build rilis bertanggal dan bukan direktori `noble/current/`: halaman `current` ternyata berisi build harian (daily) yang isinya berubah tiap hari, sedangkan direktori `releases/noble/release-YYYYMMDD` tidak berubah. Ini penting agar proyek dapat direproduksi dengan versi yang sama.

Catatan keamanan: pemeriksaan SHA256 membuktikan berkas utuh dan cocok dengan daftar dari server yang sama. Verifikasi keaslian yang lebih kuat memakai `SHA256SUMS.gpg` dan kunci tanda tangan Ubuntu; ini belum dikerjakan dan dicatat sebagai peningkatan opsional.

Image disalin ke pool dengan nama yang memuat versi dan tanggal rilis:

```bash
sudo cp ~/lab-images/ubuntu-24.04-server-cloudimg-amd64.img \
  /var/lib/libvirt/images/ubuntu-24.04-noble-20260926-base.img
virsh pool-refresh default
virsh vol-list default
```

## SSH key khusus lab

```bash
ssh-keygen -t ed25519 -C "k8s-lab" -f ~/.ssh/k8s-lab
ssh-keygen -lf ~/.ssh/k8s-lab.pub
```

```text
256 SHA256:8+jbIOJkZ9Rk9dkgEPPxNYBJdpAEBGoHx2nJlMEl9do k8s-lab (ED25519)
```

Keputusan: key terpisah dari key pribadi lain, supaya jika lab bermasalah akses ke akun lain tidak terpengaruh. Key privat (`~/.ssh/k8s-lab`) tidak pernah masuk repo; hanya key publik yang dipasang ke VM.

## Cloud-init `user-data`

Berkas `infra/cloud-init/user-data` dipakai bersama oleh ketiga VM:

```yaml
#cloud-config
users:
  - name: k8sadmin
    gecos: Kubernetes lab admin
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... k8s-lab
ssh_pwauth: false
package_update: true
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable --now qemu-guest-agent
```

Keputusan:
- `lock_passwd: true` dan `ssh_pwauth: false`: login hanya lewat SSH key, tidak ada kata sandi sama sekali.
- `sudo: NOPASSWD:ALL` adalah kemudahan lab. Karena akun tidak memiliki kata sandi, `sudo` biasa tidak mungkin dipakai. Keputusan ini akan ditinjau ulang saat hardening node.
- `qemu-guest-agent` memungkinkan host menanyakan status VM tanpa menebak.
- Berkas ini hanya memuat key publik, sehingga aman disimpan di repo.

## DHCP reservation

Rentang DHCP jaringan `default` menutupi seluruh subnet (`.2` sampai `.254`). Agar node k3s memiliki IP yang tetap, dipakai DHCP reservation di libvirt: MAC tetap per VM dipetakan ke IP tertentu. Alamat yang dipesan tidak dibagikan ke VM lain.

```bash
virsh net-update default add ip-dhcp-host \
  "<host mac='52:54:00:00:00:10' name='k3s-server' ip='192.168.122.10'/>" --live --config
virsh net-update default add ip-dhcp-host \
  "<host mac='52:54:00:00:00:11' name='k3s-agent1' ip='192.168.122.11'/>" --live --config
virsh net-update default add ip-dhcp-host \
  "<host mac='52:54:00:00:00:12' name='k3s-agent2' ip='192.168.122.12'/>" --live --config
virsh net-dumpxml default > ~/k8s-hardened-platform/infra/libvirt/network-default.xml
```

| VM | Peran | MAC | IP |
|---|---|---|---|
| k3s-server | control plane | `52:54:00:00:00:10` | `192.168.122.10` |
| k3s-agent1 | worker | `52:54:00:00:00:11` | `192.168.122.11` |
| k3s-agent2 | worker | `52:54:00:00:00:12` | `192.168.122.12` |

Konfigurasi jaringan hasil ekspor disimpan di `infra/libvirt/network-default.xml`.

## Spesifikasi VM

| Parameter | Nilai | Catatan |
|---|---|---|
| vCPU | 4 | `--cpu host-passthrough` agar fitur CPU host diteruskan penuh (berguna untuk eBPF) |
| RAM | 4096 MB | Total tiga VM 12 GB, dari RAM host 31 GiB |
| Disk | 30 GB (thin) | Overlay qcow2; diperluas otomatis oleh cloud-init saat boot |
| Firmware | UEFI (`--boot uefi`) | Image diumumkan sebagai "UEFI/GPT Bootable" |
| Perangkat | virtio (disk dan jaringan) | Diwajibkan oleh halaman resmi image untuk KVM |
| OS variant | `ubuntu24.04` | Diperiksa dengan `osinfo-query os short-id=ubuntu24.04` |

## Skrip `infra/create-vm.sh`

```bash
./create-vm.sh <nama> <mac> [vcpu] [ram_mb] [disk_gb]
```

Langkah yang dikerjakan skrip: pemeriksaan awal (base image, `user-data`, VM belum ada, reservation untuk MAC sudah dibuat), pembuatan overlay qcow2 dengan `qemu-img create -b`, pembuatan `meta-data` (hostname = nama VM) lalu ISO seed dengan `cloud-localds`, dan `virt-install --import` sehingga VM langsung boot tanpa proses instalasi.

```bash
~/k8s-hardened-platform/infra/create-vm.sh k3s-server 52:54:00:00:00:10 4 4096 30
~/k8s-hardened-platform/infra/create-vm.sh k3s-agent1 52:54:00:00:00:11 4 4096 30
~/k8s-hardened-platform/infra/create-vm.sh k3s-agent2 52:54:00:00:00:12 4 4096 30
```

## Verifikasi

Dari host:

```text
 Id   Name         State
----------------------------
 1    k3s-server   running
 2    k3s-agent1   running
 3    k3s-agent2   running

 Name       MAC address          Protocol     Address
-------------------------------------------------------------------------------
 vnet0      52:54:00:00:00:10    ipv4         192.168.122.10/24

virbr0           UP             192.168.122.1/24
```

Dari dalam `k3s-server`:

```text
status: done
extended_status: done
boot_status_code: enabled-by-generator
last_update: Thu, 01 Jan 1970 00:00:42 +0000
detail: DataSourceNoCloud [seed=/dev/sr0]
errors: []
recoverable_errors: {}

k3s-server
6.8.0-142-generic
Filesystem      Size  Used Avail Use% Mounted on
/dev/vda1        29G  1.9G   27G   7% /

qemu-guest-agent: active
HTTP/1.1 200 OK        (curl -sI https://archive.ubuntu.com)
```

Uji konektivitas antar node (setiap VM mem-ping ketiga alamat):

```text
== 192.168.122.10 ==  k3s-server  ping .10 ok, .11 ok, .12 ok
== 192.168.122.11 ==  k3s-agent1  ping .10 ok, .11 ok, .12 ok
== 192.168.122.12 ==  k3s-agent2  ping .10 ok, .11 ok, .12 ok
```

Hal yang terbukti: reservation bekerja, `virbr0` berubah UP setelah ada VM, `user-data` terbaca tanpa galat, disk 30 GB diperluas otomatis, paket terpasang lewat NAT (internet VM berfungsi), dan ketiga node saling terhubung.

## Versi komponen

| Komponen | Versi |
|---|---|
| Ubuntu pada VM | 24.04.5 LTS |
| Kernel node | 6.8.0-142-generic |
| Base image | Ubuntu cloud image `release-20260926` |
| libvirt / QEMU (host) | 10.0.0 / 8.2.2 |

Kernel node dicatat karena dukungan fitur Tetragon bergantung pada kernel dan opsi konfigurasinya, yang akan diperiksa sebelum fase Tetragon.

## Masalah dan keputusan

**1. Selisih kapasitas `df` vs `pool-info`.** Dijelaskan di bagian Storage pool: 5% blok cadangan ext4.

**2. `osinfo-query` tidak terpasang.** Paket `libosinfo-bin` tidak ikut pada instalasi langkah 0.2. Alat ini hanya untuk pemeriksaan, bukan syarat `virt-install`. Dipasang dengan `sudo apt install libosinfo-bin`, dan ditambahkan ke daftar paket prasyarat.

**3. SSH pertama gagal: `agent refused operation`.** Pesan: `sign_and_send_pubkey: signing failed for ED25519 ... from agent: agent refused operation`. Penolakan terjadi di sisi ssh-agent laptop, bukan di VM. Percobaan kedua berhasil tanpa perubahan. Dugaan: key berpassphrase pertama kali dimuat ke agent desktop dan permintaan passphrase tidak sempat terjawab. Penyebab pasti belum diverifikasi. Pada uji ping berikutnya (tiga koneksi SSH) masalah tidak muncul lagi.

**4. `last_update: Thu, 01 Jan 1970` pada `cloud-init status`.** Status tetap `done` dan `errors: []`. Dugaan: cap waktu dicatat sebelum jam sistem VM tersinkron, sehingga hanya kosmetik. Belum diverifikasi.

**5. Tidak menjalankan `apt upgrade` sebelum k3s terpasang.** Pesan login menunjukkan 31 pembaruan tersedia. Keputusan: pembaruan ditunda agar versi kernel dan paket tetap terkunci selama pemasangan komponen, sebab pembaruan dapat mengganti kernel di tengah jalan. Akan ditinjau ulang pada fase hardening node.

**6. Image dasar tidak boleh dipindah atau diubah.** Overlay qcow2 mencatat jalur absolut backing file. Memindahkan atau mengubah `ubuntu-24.04-noble-20260926-base.img` merusak ketiga VM.

**7. Host key SSH berubah jika VM dibuat ulang.** IP yang sama dengan VM baru membuat SSH menolak karena fingerprint berbeda. Solusi: `ssh-keygen -R 192.168.122.1X`.

## Status

- [x] 0.4 Storage pool, image dasar terverifikasi, SSH key, `user-data`
- [x] 0.5 Reservation DHCP, skrip `create-vm.sh`, tiga VM berjalan dan saling ping
- [x] Screenshot `virsh list --all` dengan tiga VM `running` (opsional) di `docs/images/`
- [ ] Diagram topologi jaringan (host, `virbr0`, tiga VM)
