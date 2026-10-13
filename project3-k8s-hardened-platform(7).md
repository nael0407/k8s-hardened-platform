# Proyek 3: Hardened Kubernetes Platform dengan GitOps dan Runtime Threat Enforcement

> File konteks untuk Claude. Baca seluruh file ini di awal percakapan baru agar kerja bisa dilanjutkan tanpa mengulang diskusi. Perbarui bagian "Status dan log progres" setiap kali satu langkah selesai.

## 1. Tentang pengguna dan tujuan

- Pengguna: Natanael, mahasiswa di Indonesia (jaringan komputer, dll.).
- **Tujuan: portofolio untuk melamar magang.** Yang dinilai adalah kedalaman satu proyek yang rapi dan terdokumentasi, bukan banyaknya proyek.
- Bahasa: **Indonesia** (boleh formal maupun santai).
- Cara kerja yang diinginkan:
  - Kerjakan **satu komponen/langkah sekali**, jangan melompat ke depan.
  - Penjelasan **lengkap dan menyeluruh**, jangan ada langkah yang dilewati atau disederhanakan.
  - Pengguna kritis dan akan menanyakan hal yang janggal. Akui kesalahan secara jujur dan koreksi, jangan berkelit.
  - Jika sebuah klaim bergantung pada versi/dokumentasi resmi, **verifikasi ke dokumentasi** (jangan dari ingatan).
  - Di setiap langkah, **ingatkan pengguna untuk mendokumentasikannya**: bagian mana yang didokumentasikan, apa isinya, dan apakah screenshot saja cukup. Prinsipnya: output terminal disimpan sebagai teks, screenshot hanya untuk hal visual (dashboard, Hubble), dan setiap langkah punya bagian tujuan, perintah, output penting, versi, serta masalah dan keputusan.

## 2. Konteks proyek

Dari empat ide portofolio awal (Zero Trust hybrid backbone, SOAR/DFIR, Kubernetes hardened, micro-segmentation), pengguna memutuskan mengerjakan:

1. **Proyek 3 dulu** (dokumen ini): Hardened Production Kubernetes Platform dengan GitOps dan runtime threat enforcement.
2. **Proyek 4 sesudahnya**, versi ringan: Data Center Network Micro-segmentation dan Lateral Movement Hunting (Spine-Leaf dengan FRRouting/VyOS, segmentasi OPNsense, OpenCanary, analisis pcap dengan Zeek/Wireshark; simulasi Active Directory ditunda dan opsional).
3. Proyek 1 (Zero Trust hybrid backbone) dan proyek 2 (SOAR/DFIR) **ditunda**: terlalu besar atau berbiaya.

### Brief asli proyek 3

- **Domain:** Cloud, Data Center, Cybersecurity, Digital Transformation.
- **Tantangan teknis:** mengamankan ekosistem orkestrasi kontainer dari level kernel sampai supply chain aplikasi secara deklaratif.
- **Implementasi yang diminta:**
  - Klaster multi-node Kubernetes dengan Control Plane terpisah (simulasi bare-metal atau VM).
  - GitOps dengan ArgoCD, semua konfigurasi klaster dideklarasikan di Git.
  - Keamanan berbasis eBPF (Tetragon atau Cilium) untuk mendeteksi privilege escalation, manipulasi namespace, dan anomali syscall secara real-time.
  - Network Policy zero-trust (default-deny antar pod) dan admission controller (Kyverno/OPA Gatekeeper) yang menolak image tidak bertanda tangan (Cosign).
- **Bukti portofolio:** repo GitOps, aturan eBPF tracing policy, skenario pengujian container breakout yang dicegah otomatis di level kernel.

## 3. Keputusan yang sudah diambil

| Keputusan | Pilihan | Catatan |
|---|---|---|
| OS node | **Ubuntu** (bukan Talos) | Talos opsional di akhir kalau ada waktu; bukan syarat portofolio |
| Distribusi Kubernetes | **k3s** (bukan kubeadm, bukan kind) | Alasan: lebih cepat sampai ke lapisan keamanan yang jadi nilai utama; tetap di VM asli sehingga cerita kernel/eBPF utuh. kubeadm bisa jadi tambahan opsional di akhir. kind hanya alat bantu opsional untuk uji cepat kebijakan Kyverno |
| Virtualisasi | **KVM/libvirt** di host Linux | Gratis dan ringan |
| Urutan proyek | 3 dulu, lalu 4 | |
| Biaya | **Tanpa biaya** | Semua tool open source; registry pakai ghcr.io (tier gratis); Cosign bisa keyless (Sigstore) atau dengan key sendiri |

## 4. Lingkungan pengguna (host)

- Laptop Lenovo Legion Pro 5 16IRX9.
- CPU Intel Core i9-14900HX, 32 thread, **VT-x aktif**, `/dev/kvm` ada (grup `kvm`).
- RAM 31 GiB (kelas 32 GB), swap 8 GiB. Pemakaian dasar sekitar 5,5 GiB.
- Disk root 460 GB, sekitar 348 GB kosong.
- **Host OS: Ubuntu 24.04.5 LTS**, kernel **7.0.0-34-generic** (dual-boot dengan Windows).
- Pengguna terbiasa dengan Linux dan terminal.

## 5. Arsitektur target

```
Laptop (host Ubuntu 24.04, KVM/libvirt)
│
├── VM: k3s-server   (control plane)
├── VM: k3s-agent1   (worker)
└── VM: k3s-agent2   (worker)
        │
        └── di dalam klaster:
            ├── Cilium            -> CNI berbasis eBPF + NetworkPolicy (+ Hubble)
            ├── Tetragon          -> deteksi/enforcement syscall (eBPF)
            ├── ArgoCD            -> sinkronisasi Git ke klaster (app-of-apps)
            ├── Kyverno           -> admission controller (verifikasi Cosign, Pod Security)
            └── Aplikasi demo     -> target pengujian

Eksternal: GitHub repo (sumber kebenaran) + ghcr.io (registry image) + GitHub Actions (build + sign Cosign)
```

Realisasi Fase 0: 3 VM Ubuntu 24.04.5 (kernel node 6.8.0-142-generic), masing-masing 4 vCPU, 4 GB RAM, disk 30 GB thin (overlay qcow2), boot UEFI, `--cpu host-passthrough`, driver virtio. Total RAM 12 GB; pengguna masih punya ruang besar untuk lab proyek 4. Login ke VM: `ssh -i ~/.ssh/k8s-lab k8sadmin@<IP>` (login hanya lewat SSH key).

| VM | Peran | MAC | IP |
|---|---|---|---|
| k3s-server | control plane | 52:54:00:00:00:10 | 192.168.122.10 |
| k3s-agent1 | worker | 52:54:00:00:00:11 | 192.168.122.11 |
| k3s-agent2 | worker | 52:54:00:00:00:12 | 192.168.122.12 |

Jaringan libvirt `default`: NAT, `192.168.122.0/24`, gateway `.1`, DHCP reservation untuk ketiga VM. Basis image: Ubuntu cloud image `release-20260926` (`/var/lib/libvirt/images/ubuntu-24.04-noble-20260926-base.img`, jangan dipindah atau diubah).

## 6. Lapisan komponen

1. **Node OS (Ubuntu di VM):** hardening dasar (CIS-style: matikan layanan tak perlu, akses SSH dengan key). Berbeda dari Talos, SSH ada.
2. **GitOps (ArgoCD):** Git sebagai satu-satunya sumber kebenaran. Aktifkan `selfHeal` dan `prune`. Pola **app-of-apps**: satu aplikasi induk memuat Cilium, Tetragon, Kyverno, dan aplikasi demo.
3. **Jaringan zero-trust (Cilium + NetworkPolicy):** mulai dari default-deny ingress dan egress per namespace, lalu buka seperlunya. Jebakan umum: lupa mengizinkan egress DNS (port 53 ke kube-dns). Hubble untuk visualisasi traffic dan paket yang di-drop (bagus untuk tangkapan layar).
4. **Runtime security (Tetragon):** program eBPF memantau syscall, eksekusi proses, akses file, perubahan namespace. Aturan berupa `TracingPolicy` (CRD) yang disimpan di Git. Bisa menegakkan (misalnya `Sigkill`), tetapi **dukungan enforcement bergantung pada opsi konfigurasi kernel, jadi harus diverifikasi di VM node.**
5. **Admission control (Kyverno + Cosign):** tolak image tanpa tanda tangan valid. Terapkan Pod Security Standards `restricted` di namespace aplikasi. Jalankan kebijakan dalam mode **Audit** dahulu, baru **Enforce**.

### Catatan khusus k3s

- k3s membawa komponen bawaan (flannel sebagai CNI, network policy controller, Traefik, ServiceLB; paket tambahan: coredns, local-storage, metrics-server). Karena Cilium akan menggantikan CNI dan network policy, komponen bawaan itu dimatikan lewat konfigurasi k3s.
- **Terverifikasi ke dokumentasi (2026-10-10):** panduan Cilium untuk k3s dan halaman Custom CNI k3s menyebut `--flannel-backend=none` dan `--disable-network-policy`. Mematikan Traefik: `--disable=traefik`; ServiceLB juga dimatikan lewat `--disable` (flag `--disable` dapat diulang atau dipisah koma). Opsi dapat ditulis di `/etc/rancher/k3s/config.yaml` (kunci YAML = nama flag tanpa tanda hubung depan). Instalasi memakai `INSTALL_K3S_VERSION` untuk mengunci versi. Panduan Cilium menyebut bahwa mode tanpa kube-proxy menambah `--disable-kube-proxy` (tidak dipakai; kube-proxy tetap bawaan).
- **Versi terverifikasi (2026-10-10):** channel `stable` k3s = `v1.36.5+k3s1` (Kubernetes 1.36.5, containerd v2.3.4-k3s1.36). Dokumentasi Cilium stabil = 1.20.2, e2e tested pada Kubernetes 1.33 sampai 1.36. CIDR bawaan k3s: pod `10.42.0.0/16`, service `10.43.0.0/16`; instalasi Cilium memakai `ipam.operator.clusterPoolIPv4PodCIDRList="10.42.0.0/16"` agar cocok. Versi Tetragon, ArgoCD, dan Kyverno belum dikunci (diverifikasi saat fasenya).
- k3s mendukung node `server` (control plane) dan `agent` (worker) terpisah, sehingga syarat "control plane terpisah" tetap terpenuhi.
- Rancher menyediakan panduan hardening CIS untuk k3s sebagai rujukan.

## 7. Alur end-to-end (untuk cerita wawancara)

1. Kode aplikasi di-build oleh GitHub Actions, image **ditandatangani Cosign**, lalu didorong ke ghcr.io.
2. Manifest di repo Git diubah (misalnya versi image).
3. ArgoCD mendeteksi perubahan dan menerapkannya ke klaster.
4. **Kyverno** memverifikasi tanda tangan; image tanpa tanda tangan ditolak.
5. Pod berjalan di bawah **NetworkPolicy default-deny** Cilium.
6. Selama berjalan, **Tetragon** mengawasi perilaku di level kernel.

## 8. Skenario pengujian (bagian demo)

Dijalankan **hanya di klaster lab milik pengguna sendiri**, fokus pada pembuktian bahwa pertahanan bekerja. Dokumentasikan **sebelum** (tanpa kontrol, serangan berhasil) dan **sesudah** (dengan kontrol, serangan gagal).

| Skenario | Kontrol | Hasil yang diharapkan |
|---|---|---|
| Deploy image tanpa tanda tangan | Kyverno + Cosign | Ditolak saat admission |
| Deploy pod privileged / `hostPID` / `hostPath` ke root | Pod Security + Kyverno | Ditolak |
| Pod A menghubungi pod B tanpa izin | Cilium NetworkPolicy | Paket di-drop, terlihat di Hubble |
| Membuka shell di container yang berjalan | Tetragon | Terdeteksi (dan bisa dihentikan) |
| Proses membaca file sensitif host / berpindah namespace | Tetragon | Terdeteksi/diblokir di level kernel |
| `kubectl edit` langsung pada resource | ArgoCD selfHeal | Dikembalikan otomatis sesuai Git |

## 9. Struktur repo yang direncanakan

```
k8s-hardened-platform/
├── README.md
├── docs/            (arsitektur, keputusan desain, laporan pengujian)
├── infra/           (create-vm.sh, cloud-init/user-data, libvirt/network-default.xml; nanti konfigurasi k3s)
├── gitops/
│   ├── bootstrap/   (ArgoCD + app-of-apps)
│   ├── platform/    (cilium, tetragon, kyverno)
│   └── apps/        (aplikasi demo)
├── policies/        (networkpolicy, kyverno, tracingpolicy)
└── attack-tests/    (skenario pengujian + hasil)
```

## 10. Bukti portofolio dan cara mengemasnya

- Repo GitOps rapi dengan commit bertahap.
- TracingPolicy eBPF beserta penjelasan tiap aturan.
- Kebijakan Kyverno dan NetworkPolicy.
- Laporan pengujian (sebelum/sesudah, ada log/tangkapan layar).
- Diagram arsitektur dan rekaman demo 1-2 menit.
- README yang berdiri sendiri: masalah, diagram, hasil terukur (angka, screenshot, GIF), cara mereproduksi, keputusan desain (termasuk yang gagal dan diperbaiki).
- Satu tulisan blog atau write-up.
- Ukur sesuatu (misalnya waktu serangan diblokir) karena angka membedakan proyek serius dari sekadar mengikuti tutorial.

## 11. Fase pengerjaan

| Fase | Isi | Selesai jika |
|---|---|---|
| 0 | Siapkan KVM/libvirt, buat 3 VM | VM menyala dan bisa saling ping |
| 1 | Bootstrap klaster k3s (server + 2 agent) tanpa CNI bawaan, pasang Cilium | `kubectl get nodes` semua Ready |
| 2 | Pasang ArgoCD, buat repo Git, terapkan app-of-apps | Perubahan di Git otomatis masuk klaster |
| 3 | NetworkPolicy default-deny + Hubble | Traffic tak diizinkan terbukti di-drop |
| 4 | Kyverno + Cosign + pipeline signing | Image tak bertanda tangan ditolak |
| 5 | Tetragon + TracingPolicy | Aktivitas mencurigakan terdeteksi |
| 6 | Skenario pengujian + dokumentasi + demo | README, laporan, video selesai |
| Opsional | Talos atau kubeadm sebagai perbandingan; SBOM (Syft), Trivy, Sealed Secrets | Hanya jika fase 1-6 selesai dan waktu ada |

### Rincian Fase 0

| Langkah | Isi |
|---|---|
| 0.1 | Cek dasar virtualisasi (selesai) |
| 0.2 | Pasang KVM/libvirt (`qemu-system-x86`, `libvirt-daemon-system`, `libvirt-clients`, `virtinst`, `cloud-image-utils`), tambahkan user ke grup `libvirt` dan `kvm`, login ulang, verifikasi dengan `virsh` |
| 0.3 | Periksa dan atur jaringan virtual libvirt (jaringan `default`, mungkin perlu diaktifkan) |
| 0.4 | Storage pool libvirt, unduh dan verifikasi cloud image Ubuntu (build rilis bertanggal), SSH key khusus lab, `user-data` cloud-init bersama (selesai) |
| 0.5 | DHCP reservation di libvirt, skrip `infra/create-vm.sh` (base image + overlay qcow2 + seed cloud-init, **bukan** template-klon), buat 3 VM (selesai) |

### Rincian Fase 1

| Langkah | Isi |
|---|---|
| 1.1 | Periksa kernel node (BTF, opsi eBPF, lockdown, LSM, cgroup) dan cocokkan dengan dokumentasi (selesai) |
| 1.2 | Pemeriksaan awal node dan konfigurasi k3s server di repo (`infra/k3s/server-config.yaml`) (selesai) |
| 1.3 | Pasang k3s server terkunci `v1.36.5+k3s1`; node diharapkan NotReady sampai CNI terpasang (selesai) |
| 1.4 | Gabungkan 2 agent (token node tidak masuk repo); verifikasi `uname -r` agent (selesai) |
| 1.5a | Akses `kubectl` dari laptop: pasang kubectl v1.36 dari repositori apt resmi, salin kubeconfig ke berkas terpisah `~/.kube/k3s-lab.yaml` (berizin 600, jangan masuk repo) (selesai) |
| 1.5b | Pasang Helm 4.3.0 (checksum + GPG dari dua jalur) dan Cilium 1.20.2 lewat Helm dengan `gitops/platform/cilium/values.yaml` (selesai) |
| 1.5c | Cilium CLI v0.20.1, `cilium status --wait` OK, semua node Ready (selesai) |
| 1.5d | Tes konektivitas Cilium (`cilium connectivity test`), hasil dicatat apa adanya; commit values.yaml; screenshot |

## 12. Risiko yang diwaspadai

- Kebijakan terlalu ketat di awal bisa memblokir komponen sistem sendiri: gunakan mode Audit dahulu.
- Kompatibilitas versi: catat versi k3s, Cilium, Tetragon, Kyverno, ArgoCD; jangan upgrade di tengah jalan.
- Kernel host sangat baru, tetapi yang relevan untuk Tetragon adalah kernel **di VM node**; periksa opsi konfigurasi kernel sebelum mengandalkan fitur enforcement.
- Menambah fitur terlalu banyak sebelum fase 1-6 selesai.
- Pengguna tidak akan menyentuh mekanisme internal kubeadm (sertifikat, static pod, join) karena memakai k3s; ini sengaja dan bisa ditutup dengan klaster kubeadm opsional di akhir.

## 13. Status dan log progres

- [selesai] Memilih proyek 3 dulu, Ubuntu, dan k3s.
- [selesai] 0.1: host Ubuntu 24.04.5, kernel 7.0.0-34, `/dev/kvm` ada, VT-x aktif (jumlah `vmx` 64 = 2 baris per thread x 32 thread, konsisten).
- [selesai] 0.2: KVM/libvirt terpasang (libvirt 10.0.0, QEMU 8.2.2). Grup `libvirt` dan `kvm` aktif setelah login ulang. `LIBVIRT_DEFAULT_URI="qemu:///system"` diset di `~/.bashrc`. `virsh list --all` bekerja tanpa `-c`. Jaringan `default` sudah `active`, autostart `yes`, persistent `yes`.
  - Masalah yang ditemui: `Permission denied` pada socket libvirt sebelum login ulang (grup baru baru aktif setelah login). Dicatat di dokumentasi.
  - Hal yang diwaspadai: pengguna ada di grup `docker`; Docker dan libvirt sama-sama mengatur firewall host, bisa mengganggu akses internet VM di jaringan NAT libvirt. Diuji saat VM pertama mengunduh paket.
  - Dokumentasi: draf `docs/00-persiapan-host.md` sudah dibuat Claude; sudah disimpan dan di-commit pengguna di repo `~/k8s-hardened-platform` (struktur `docs/` dan `infra/`).
- [selesai] 0.3: jaringan `default` (mode NAT, bridge `virbr0`, `192.168.122.0/24`, gateway `.1`, DHCP `.2`-`.254`). Host memakai WiFi `wlp0s20f3` (`192.168.1.0/24`), Docker `172.17.0.0/16`; tidak ada bentrok subnet. `virbr0` DOWN itu normal (belum ada VM). Baseline `iptables FORWARD`: policy ACCEPT dengan rantai Docker dan LIBVIRT; uji sebenarnya saat VM pertama mengakses internet.
  - Keputusan: tetap NAT (bridge ke WiFi umumnya tidak didukung). Rencana IP sementara: server `192.168.122.10`, agent1 `.11`, agent2 `.12`; cara tetapnya (DHCP reservation libvirt atau cloud-init statis) diputuskan di 0.5 karena rentang DHCP mencakup seluruh subnet.
  - Dokumentasi: `docs/00-persiapan-host.md` sudah di-commit pengguna; `docs/01-jaringan-virtual.md` dibuat Claude, menunggu disimpan dan di-commit.
- [selesai] 0.4: pool libvirt `default` (dir `/var/lib/libvirt/images`), image `release-20260926` terverifikasi SHA256, SSH key ed25519 `~/.ssh/k8s-lab`, `infra/cloud-init/user-data` (user `k8sadmin`, login hanya SSH key, sudo NOPASSWD sebagai keputusan lab).
- [selesai] 0.5: tiga DHCP reservation, `infra/create-vm.sh`, tiga VM running; verifikasi lolos (cloud-init done, disk diperluas, internet VM lewat NAT OK, `virbr0` UP, ketiga node saling ping). Pendekatan diubah dari template-klon ke base image + overlay + seed.
  - Catatan: SSH pertama sempat `agent refused operation` (tidak berulang); `last_update` cloud-init 1970 (kosmetik, dugaan); `libosinfo-bin` perlu dipasang manual. Semuanya dicatat di dokumentasi.
  - Keputusan: tidak menjalankan `apt upgrade` di node sebelum k3s terpasang (menjaga versi kernel/paket tetap terkunci).
  - Dokumentasi: `docs/00-persiapan-host.md` dan `docs/01-jaringan-virtual.md` di-commit pengguna; `docs/02-vm-node.md` dibuat Claude, menunggu disimpan dan di-commit.
- [selesai] **Fase 0 selesai.**
- [selesai] 1.1: kernel node `6.8.0-142-generic`, BTF ada, semua opsi yang disebut dokumentasi Cilium dan Tetragon terpenuhi (beberapa `m`, diterima; `HAVE_BPF_JIT` tidak muncul, contoh di FAQ Tetragon juga `n`, tidak dianggap penghalang). `BPF_KPROBE_OVERRIDE=y`. Lockdown mode `integrity`, LSM aktif `lockdown,capability,landlock,yama,apparmor` (tanpa `bpf`), cgroup v2, boot UEFI.
  - Keputusan: penegakan memakai `Override` (bukan hanya `Sigkill`, sebab `Sigkill` tidak selalu membatalkan operasinya menurut dokumentasi Tetragon); kebijakan berbasis kprobe, BPF LSM tidak diaktifkan; kernel dikunci (tanpa `apt upgrade`).
  - Dokumentasi: `docs/03-kernel-node.md` dibuat Claude, menunggu disimpan dan di-commit; juga `docs/02-vm-node.md` dan `docs/topologi.md` jika belum.
- [selesai] 1.2: `ufw` inactive, NTP sinkron, hostname unik; `infra/k3s/server-config.yaml` (flannel-backend none, disable-network-policy, disable traefik dan servicelb, tls-san 192.168.122.10) terpasang di `/etc/rancher/k3s/config.yaml` (0600).
- [selesai] 1.3: k3s server `v1.36.5+k3s1` terpasang (skrip diunduh dan diperiksa dulu). Node NotReady dengan pesan `cni plugin not initialized` (diharapkan); pod coredns, local-path-provisioner, metrics-server Pending; tidak ada traefik/svclb; tidak ada `flannel.1`/`cni0`; `/etc/cni/net.d` kosong. Catatan: `runtimes.yaml` di direktori manifests tidak tercantum di dokumentasi yang dibaca (fungsi belum diverifikasi). Kesalahan Claude: lupa `sudo` pada dua perintah `ls`.
- [selesai] 1.4: kedua agent bergabung (token lewat berkas config 0600, tidak masuk repo/percakapan). Hash skrip instalasi identik di ketiga node (`e5cc3b3d...7fee`). Semua node NotReady (diharapkan), kernel sama `6.8.0-142-generic`, containerd `2.3.4-k3s1.36`.
  - Dokumentasi: `docs/04-k3s-cluster.md` dibuat Claude, menunggu disimpan dan di-commit; `03-kernel-node.md` diperbarui (kernel agent terverifikasi).
- [selesai] 1.5a: kubectl v1.36.5 (repositori apt `pkgs.k8s.io` v1.36) terpasang di laptop; kubeconfig di `~/.kube/k3s-lab.yaml` (izin 0600, server `https://192.168.122.10:6443`), diaktifkan per terminal dengan `export KUBECONFIG=$HOME/.kube/k3s-lab.yaml`. Klien v1.36.5, server v1.36.5+k3s1; tiga node NotReady (diharapkan). Catatan: `kubectl cluster-info` menyebut CoreDNS "running" walau pod masih Pending (diduga hanya mendaftar Service).
- [selesai] 1.5b: Helm (binary rilis resmi, checksum + GPG) dan Cilium 1.20.2 via repositori Helm tradisional dengan `gitops/platform/cilium/values.yaml` (CIDR pod 10.42.0.0/16; Hubble belum dinyalakan, dikerjakan di Fase 3 setelah dokumentasinya diverifikasi). Catatan: contoh OCI di dokumentasi Cilium menulis versi tanpa flag `--version` (diduga salah ketik), jadi dipakai repositori tradisional yang sintaksnya jelas. Kubeconfig disalin tidak diperbarui otomatis oleh k3s menurut dokumentasi.
  - Hasil: `helm install` 2026-10-11 10:35:31; semua pod Cilium Running pada usia 4m42s (batas atas), tiga node Ready; IP pod `10.42.1.x` (blok /24 per node dari 10.42.0.0/16). Helm 4.3.0 (commit bec5b06e, checksum dan sidik jari kunci dicocokkan dengan halaman rilis). Kendala: unduhan Helm terputus (resume `-C -`), `.asc` ternyata di aset rilis GitHub bukan `get.helm.sh` (kesalahan Claude, dikoreksi).
- [selesai] 1.5c: Cilium CLI v0.20.1 (checksum dari rilis yang sama, bukan sumber terpisah). `cilium status`: Cilium, Operator, Envoy OK; Hubble Relay dan ClusterMesh disabled; 3/3 pod dikelola Cilium; chart 1.20.2. CLI default image v1.20.1 vs running 1.20.2 (jangan `cilium install/upgrade` tanpa versi eksplisit). Image dikunci dengan digest (lihat docs/05). coredns dan metrics-server sempat 0/1 lalu 1/1. Semua komponen sistem berada di control plane (k3s tanpa taint).
  - Dokumentasi: `docs/05-cilium-dan-akses-kubectl.md` dibuat Claude, menunggu disimpan dan di-commit.
- [selesai] 1.5d: `cilium connectivity test` (CLI v0.20.1, Cilium 1.20.2): 82 tes (706 aksi) sukses, 53 dilewati, 0 gagal. Dilewati karena tes unsafe, fitur tidak dinyalakan, syarat versi, butuh node tanpa Cilium/multi-klaster. Hubble Relay nonaktif sehingga validasi aliran dilewati. Namespace uji (`cilium-test-1`, `cilium-test-ccnp1`, `cilium-test-ccnp2`) dihapus manual; `cilium-secrets` milik Cilium dibiarkan. `lsmod` di server: `cls_bpf`, `sch_ingress`, `vxlan`, `geneve`, `ip_set` termuat; `xt_set`, `xt_comment`, `sch_fq` tidak muncul (penyebab belum diselidiki, tidak terbukti bermasalah).
- [selesai] **Fase 1 selesai** (tiga node Ready, Cilium OK, tes konektivitas lulus). Screenshot `docs/images/fase1-nodes-ready.png` dan `docs/images/fase0-virsh-list.png` sudah di-commit pengguna.
- [selesai] 2.1: Verifikasi resmi dokumentasi Argo CD v3.5.4 (diuji kompatibel untuk Kubernetes v1.36). Namespace `argocd` dibuat, manifest non-HA v3.5.4 dipasang dengan Server-Side Apply (`--server-side --force-conflicts`). 7 NetworkPolicy bawaan aktif mengamankan ingress komponen internal.
- [selesai] 2.2: Seluruh 7 pod Argo CD berstatus `1/1 Running` (usia 4m14s, 0 restart). Beban kerja terdistribusi di worker node `k3s-agent1` (4 pod, IP `10.42.0.x`) dan `k3s-agent2` (3 pod, IP `10.42.2.x`), membuktikan isolasi control plane dan IPAM pod CIDR Cilium bekerja presisi.
- [selesai] 2.3: Binary CLI `argocd` v3.5.4 diunduh ke `~/lab-tools`, diverifikasi SHA-256 (`OK`), dan dipasang ke `/usr/local/bin/argocd`. Password awal admin dibaca dari secret `argocd-initial-admin-secret` (disamarkan). Akses via port-forward internal CLI terverifikasi.
- [selesai] 2.4: Struktur GitOps pola App-of-Apps dibuat (`gitops/bootstrap/root-application.yaml` dan `gitops/bootstrap/apps/cilium.yaml`). Fitur Multiple Sources menggabungkan chart upstream `helm.cilium.io` dengan `gitops/platform/cilium/values.yaml` dari Git. Adopsi Cilium oleh Argo CD berhasil in-place tanpa gangguan (`ServerSideApply=true`, pod tetap running tanpa restart, umur 11h, status `Synced` & `Healthy`).
  - Dokumentasi: `docs/06-argocd-dan-gitops.md` selesai dibuat.
- [selesai] **Fase 2 selesai** (Argo CD terpasang, pola App-of-Apps aktif, Cilium diadopsi ke GitOps deklaratif).
- [selesai] 3.1: Hubble Relay v1.20.2 dan Hubble UI v0.13.6 diaktifkan secara deklaratif via GitOps pada `gitops/platform/cilium/values.yaml` (commit `432cacd`). Argo CD berhasil melakukan rekonsiliasi otomatis, pod `hubble-relay` (1/1) dan `hubble-ui` (2/2) berjalan normal, `cilium status` mengonfirmasi `Hubble Relay: OK`.
- [selesai] 3.2: Dashboard visual Hubble UI diakses pada `http://localhost:12000`, Service Map berhasil menampilkan alur komunikasi pod. Tangkapan layar `argo-cd_hubbleui.png` dan `kube-system_hubbleui.png` disimpan. Pengujian konektivitas klaster `cilium connectivity test` lulus penuh: 82/82 tes (709 aksi) sukses, 0 gagal.
- [selesai] 3.3: Implementasi arsitektur keamanan Zero-Trust pada namespace `secure-demo`. Uji baseline membuktikan pod `attacker` dan `frontend` awalnya bebas mengakses backend (`HTTP 200 OK`). Penerapan kebijakan `01-default-deny-all.yaml` (dengan proteksi egress DNS CoreDNS port 53) dan `02-allow-frontend-to-backend.yaml` berhasil menegakkan isolasi: `frontend` tetap 200 OK, sedangkan `attacker` diblokir seketika di level kernel eBPF (curl exit code 28 timeout). Hubble UI membuktikan penegakan dengan garis merah `DROPPED (Policy denied)` (tangkapan layar `fase3_hubble-drop.png`).
  - Dokumentasi: `docs/07-observabilitas-hubble-dan-networkpolicy.md` selesai dibuat.
- [selesai] **Fase 3 selesai** (Observabilitas eBPF Hubble aktif, Zero-Trust NetworkPolicy terbukti menegakkan keamanan level kernel).
- [selesai] 4.1: Instalasi Kyverno v1.19.1 (Helm Chart 3.9.1) via GitOps Argo CD pola App-of-Apps. 4 controller (`admission`, `background`, `cleanup`, `reports`) berstatus 1/1 Running. Isu rekonsiliasi etcd pada 11 CRD dengan kamus kosong `labels: {}` diatasi dengan deklaratif `ignoreDifferences` (`jqPathExpressions: [".metadata.labels"]`).
- [selesai] 4.2: Penegakan Pod Security Standards (PSS Baseline & Restricted) via Kyverno ClusterPolicy (`disallow-privileged-containers` dan `disallow-host-namespaces`). Whitelist namespace platform (`kube-system`, `kyverno`, `argocd`) diamankan untuk operasional CNI eBPF Cilium. Pengujian empiris membuktikan pod unprivileged diizinkan, sedangkan pod dengan `privileged: true` dan `hostPID: true` ditolak seketika oleh Admission Webhook di gerbang API (tidak pernah masuk etcd).
- [selesai] 4.3: Penegakan Supply Chain Security dengan Cosign v2.4.3 (terverifikasi SHA256) dan Kyverno `verifyImages`. Pasangan kunci ECDSA dibuat (`cosign.key` diamankan oleh `.gitignore`, `cosign.pub` diintegrasikan ke ClusterPolicy). Citra uji di-push ke registry OCI `ttl.sh`. Pengujian empiris membuktikan citra tanpa tanda tangan ditolak seketika (`no signatures found`), sedangkan citra bertanda tangan valid diterima dan dimutasi secara otomatis ke digest SHA256 immutable (`@sha256:...`) untuk mencegah serangan tag tampering.
  - Dokumentasi: `docs/08-supply-chain-kyverno-dan-cosign.md` selesai dibuat.
- [selesai] **Fase 4 selesai** (Supply Chain Security dan Admission Control aktif dan terverifikasi penuh).
- [berikutnya] Fase 5: Runtime Security dengan Tetragon (eBPF tracing syscall, eksekusi proses, akses file sensitif, dan pembuktian penegakan runtime).
- Catatan: VM libvirt belum diset autostart; setelah laptop reboot VM harus dinyalakan dengan `virsh start`.

