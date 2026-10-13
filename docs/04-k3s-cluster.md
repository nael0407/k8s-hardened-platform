# 04. Klaster k3s: server dan dua agent

Tanggal pengerjaan: 2026-10-10
Fase: 1 (langkah 1.2 sampai 1.4)

## Tujuan

Membangun klaster k3s dengan control plane (`k3s-server`) dan dua worker (`k3s-agent1`, `k3s-agent2`) pada tiga VM Fase 0. Klaster sengaja dipasang tanpa CNI bawaan (flannel) dan tanpa network policy bawaan, karena Cilium akan mengambil alih keduanya (langkah 1.5). Akibatnya semua node berstatus `NotReady` sampai Cilium terpasang, dan itu perilaku yang diharapkan.

## Versi dan sumber

| Komponen | Versi | Sumber |
|---|---|---|
| k3s | `v1.36.5+k3s1` (channel `stable` saat diperiksa) | Rilis GitHub k3s, dikunci dengan `INSTALL_K3S_VERSION` |
| Kubernetes | 1.36.5 | Tabel komponen pada rilis k3s di atas |
| containerd | `2.3.4-k3s1.36` | Tabel komponen rilis k3s; sama dengan kolom `CONTAINER-RUNTIME` pada `kubectl get nodes` |
| Cilium (rencana) | 1.20.2 | Dokumentasi stabil Cilium; e2e tested pada Kubernetes 1.33 sampai 1.36 |

## Pemeriksaan awal pada `k3s-server`

```bash
sudo ufw status
timedatectl show -p NTPSynchronized -p TimeUSec
hostname
```

```text
Status: inactive
NTPSynchronized=yes
TimeUSec=Sat 2026-10-10 13:11:52 UTC
k3s-server
```

| Pemeriksaan | Hasil | Artinya |
|---|---|---|
| `ufw` | `inactive` | Aturan port 6443 dan subnet pod/service dari dokumentasi k3s tidak perlu dibuat |
| Sinkronisasi waktu | `yes`, jam benar | Sertifikat k3s memiliki cap waktu valid. Cap `1970` pada `cloud-init status` kemungkinan hanya akibat pencatatan sebelum jam tersinkron (dugaan, tidak dibuktikan) |
| Hostname | `k3s-server` | Dokumentasi mensyaratkan hostname unik antar node; ketiga VM berbeda |

## Konfigurasi k3s server

Berkas `infra/k3s/server-config.yaml`, dipasang di `/etc/rancher/k3s/config.yaml` (berizin `0600`, milik root):

```yaml
# Konfigurasi k3s server (control plane). Dipasang di /etc/rancher/k3s/config.yaml
flannel-backend: "none"
disable-network-policy: true
disable:
  - traefik
  - servicelb
tls-san:
  - "192.168.122.10"
```

| Keputusan | Pilihan | Alasan |
|---|---|---|
| Flannel dan network policy bawaan | Dimatikan (`flannel-backend: none`, `disable-network-policy: true`) | Cilium mengambil alih keduanya; dokumentasi k3s dan Cilium menyarankan mematikan keduanya |
| Traefik dan ServiceLB | Dimatikan (`disable`) | Tidak dibutuhkan; mengurangi permukaan serangan. ArgoCD diakses lewat `port-forward` |
| kube-proxy | Tetap bawaan | Lebih sedikit bagian bergerak. Mode tanpa kube-proxy (`--disable-kube-proxy`) bisa jadi peningkatan opsional |
| `local-storage`, `metrics-server` | Tetap bawaan | Tidak ada alasan menyimpang dari bawaan saat ini |
| Izin kubeconfig | Bawaan (tidak dilonggarkan) | Tidak melonggarkan izin demi kemudahan; `sudo k3s kubectl` dipakai di server |
| Token node | Tidak ditulis di repo | Rahasia; dibaca dari server saat agent bergabung |
| CIDR pod dan service | Bawaan (`10.42.0.0/16`, `10.43.0.0/16`) | Tidak bentrok dengan `192.168.1.0/24`, `172.17.0.0/16`, `192.168.122.0/24`; Cilium dipasang dengan CIDR pod yang sama |

## Pemasangan k3s server

```bash
curl -sfL https://get.k3s.io -o /tmp/install-k3s.sh
less /tmp/install-k3s.sh
INSTALL_K3S_VERSION='v1.36.5+k3s1' sh /tmp/install-k3s.sh
```

Skrip diunduh dulu dan diperiksa sebelum dijalankan sebagai root, dibanding `curl | sh`.

Verifikasi:

```text
k3s version v1.36.5+k3s1 (3dd98cc5)
go version go1.26.8

active    (systemctl is-active k3s)

NAME         STATUS     ROLES           AGE   VERSION        INTERNAL-IP      KERNEL-VERSION              CONTAINER-RUNTIME
k3s-server   NotReady   control-plane   56s   v1.36.5+k3s1   192.168.122.10   6.8.0-142-generic (amd64)   containerd://2.3.4-k3s1.36

container runtime network not ready: NetworkReady=false reason:NetworkPluginNotReady message:Network plugin returns error: cni plugin not initialized

NAMESPACE     NAME                                      READY   STATUS    RESTARTS   AGE
kube-system   coredns-7cfb7bc9c7-79bb4                  0/1     Pending   0          62s
kube-system   local-path-provisioner-77b9867795-5d5jd   0/1     Pending   0          62s
kube-system   metrics-server-6dc596dfb8-t2d78           0/1     Pending   0          62s
```

Bukti bahwa komponen bawaan benar-benar tidak aktif:

```text
sudo ls /var/lib/rancher/k3s/server/manifests
ccm.yaml      local-storage.yaml  rolebindings.yaml
coredns.yaml  metrics-server      runtimes.yaml

ip -br link
lo               UNKNOWN        00:00:00:00:00:00
enp1s0           UP             52:54:00:00:00:10

sudo ls /etc/cni/net.d
(kosong)
```

- Tidak ada `traefik.yaml` di direktori manifests, tidak ada pod `traefik` atau `svclb`.
- Tidak ada antarmuka `flannel.1` atau `cni0`, dan `/etc/cni/net.d` kosong.
- Status `NotReady` dengan pesan `cni plugin not initialized` adalah akibat langsung dari tidak adanya CNI, bukan kegagalan.

## Penggabungan agent

Token node adalah rahasia: siapa pun yang memilikinya dapat menggabungkan node ke klaster. Karena itu token tidak masuk repo, tidak diketik di argumen perintah (argumen terlihat pada daftar proses), dan tidak ditempel ke dokumentasi. Token dibaca dari server (`/var/lib/rancher/k3s/server/node-token`) ke variabel shell, ditulis ke `/etc/rancher/k3s/config.yaml` pada tiap agent dengan `umask 077`, lalu variabelnya dihapus.

Bentuk berkas konfigurasi agent (token disamarkan):

```yaml
server: "https://192.168.122.10:6443"
token: "<disamarkan>"
```

Pemasangan agent dengan versi yang sama, disertai hash skrip instalasi:

```bash
INSTALL_K3S_VERSION="v1.36.5+k3s1" INSTALL_K3S_EXEC="agent" sh /tmp/install-k3s.sh
```

Hash SHA-256 skrip instalasi, identik pada ketiga node (server dan kedua agent):

```text
e5cc3b3d9dfc1662c2d9be6da5abc9a4cd317d6abc3a5ffc02e3dd3248207fee  /tmp/install-k3s.sh
```

Hasil:

```text
NAME         STATUS     ROLES           AGE     VERSION        INTERNAL-IP      KERNEL-VERSION              CONTAINER-RUNTIME
k3s-agent1   NotReady   <none>          55s     v1.36.5+k3s1   192.168.122.11   6.8.0-142-generic (amd64)   containerd://2.3.4-k3s1.36
k3s-agent2   NotReady   <none>          30s     v1.36.5+k3s1   192.168.122.12   6.8.0-142-generic (amd64)   containerd://2.3.4-k3s1.36
k3s-server   NotReady   control-plane   5m34s   v1.36.5+k3s1   192.168.122.10   6.8.0-142-generic (amd64)   containerd://2.3.4-k3s1.36
```

Ketiga node terdaftar dengan versi k3s, kernel, dan containerd yang sama. Kernel kedua agent terverifikasi sama dengan server, sehingga asumsi di `03-kernel-node.md` terbukti.

## Masalah dan keputusan

**1. `Permission denied` pada direktori k3s.** Perintah `ls /var/lib/rancher/k3s/server/manifests` dan `ls /etc/cni/net.d` gagal karena kedua direktori milik root dan perintah awal tidak memakai `sudo`. Itu kekeliruan pada instruksi, dikoreksi dengan `sudo ls`.

**2. `NotReady` adalah hasil yang diharapkan.** Tanpa CNI, kubelet melaporkan `cni plugin not initialized`. Jika node justru `Ready`, itu tanda flannel tidak termatikan. Dipakai sebagai bukti konfigurasi bekerja.

**3. `runtimes.yaml` tidak tercantum di dokumentasi yang dibaca.** Halaman Packaged Components hanya menyebut `coredns`, `traefik`, `local-storage`, dan `metrics-server`. Berkas `runtimes.yaml` kemungkinan berkas bawaan k3s yang ditulis ulang saat layanan dimulai, tetapi fungsinya belum diverifikasi. Tidak memengaruhi proyek.

**4. Pengelolaan token.** Disimpan sebagai berkas berizin `0600`, bukan argumen perintah dan bukan di repo. Berkas konfigurasi tidak dikelola skrip instalasi, sehingga pemasangan ulang skrip tidak menimpanya.

**5. Skrip instalasi diperiksa dan hash dibandingkan.** Skrip diunduh sebelum dijalankan. Hash pada ketiga node identik, artinya ketiganya menjalankan berkas yang sama. Ini membuktikan konsistensi unduhan, bukan keaslian skrip.

**6. Kubeconfig tidak dilonggarkan.** Berkas `/etc/rancher/k3s/k3s.yaml` tetap hanya dapat dibaca root. Akses dari laptop disalin secara terpisah (langkah 1.5a) dan diperlakukan sebagai kredensial admin.

## Status

- [x] 1.2 Pemeriksaan awal dan konfigurasi server di repo
- [x] 1.3 k3s server terpasang, versi dikunci
- [x] 1.4 Dua agent bergabung, kernel agent terverifikasi
- [x] 1.5a Akses `kubectl` dari laptop
- [x] 1.5b Cilium terpasang, semua node `Ready`
- [x] Screenshot `kubectl get nodes -o wide` dengan tiga node `Ready` (setelah 1.5b)
