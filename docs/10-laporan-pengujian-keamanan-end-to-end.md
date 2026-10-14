# 10. Laporan Pengujian Keamanan End-to-End dan Evaluasi Platform

Tanggal pengujian: 2026-10-14  
Fase: 6 (Langkah 6.1 sampai 6.2)  
Status Klaster: **Production-Hardened & Audited (9/9 Checks Passed)**

---

## 1. Ringkasan Eksekutif

Laporan ini menyajikan hasil evaluasi keamanan menyeluruh (*Comprehensive End-to-End Security Audit*) terhadap platform Kubernetes yang telah diperkeras (*Hardened Kubernetes Platform*). Pengujian dilakukan secara empiris dengan mensimulasikan taktik, teknik, dan prosedur penyerangan nyata (*Adversary Tactics, Techniques, and Procedures - TTPs*) yang dipetakan langsung ke kerangka kerja **MITRE ATT&CK for Containers**.

Seluruh pengujian dijalankan dan divalidasi menggunakan skrip otomatis [`attack-tests/run-all-verifications.sh`](file:///home/lavvvet/k8s-hardened-platform/attack-tests/run-all-verifications.sh).

### Ringkasan Metrik Pengujian
| Metrik | Nilai | Evaluasi |
|---|---|---|
| Total Kasus Uji Keamanan | 9 | Komprehensif (L3-L7 Network, Supply Chain, Admission, In-Kernel Runtime, GitOps) |
| Uji Berhasil (*Passed*) | 9 (100%) | Seluruh kontrol keamanan berhasil memblokir serangan |
| Uji Gagal (*Failed*) | 0 (0%) | Tidak ada celah yang lolos (*zero bypass*) |
| *False Positive* pada Operasi Legal | 0 (0%) | Perintah aplikasi standar (`whoami`, `uname -a`) berjalan mulus (Exit 0) |
| Waktu Eksekusi Audit Otomatis | < 20 detik | Deterministik dan dapat direproduksi penuh |

---

## 2. Pemetaan Matriks MITRE ATT&CK for Containers

Setiap vektor serangan diuji dalam kondisi **Sebelum Penegakan (*Baseline*)** dan **Sesudah Penegakan (*Hardened*)**:

| ID MITRE | Taktik & Teknik | Vektor Serangan | Kontrol Keamanan | Hasil Pengujian | Bukti / Artefak |
|---|---|---|---|---|---|
| **T1570** | Lateral Movement | Pod `attacker` memindai dan mengakses API `backend-svc` tanpa izin | Cilium eBPF Zero-Trust (`01-default-deny-all.yaml`) | **DITOLAK (Packet Drop)** | Curl exit code 28; Garis merah visual di Hubble UI [`fase3_hubble-drop.png`](images/fase3_hubble-drop.png) |
| **T1611** | Privilege Escalation / Breakout | Permintaan Pod meminta `securityContext.privileged: true` | Kyverno PSS Admission Webhook (`01-disallow-privileged.yaml`) | **DITOLAK saat Admission** | HTTP 400/403 Webhook rejection; Pod tidak pernah dibuat di etcd |
| **T1610** | Deploy Container / Host Namespace | Pod meminta akses `hostPID: true` untuk memata-matai proses node | Kyverno PSS Admission Webhook (`02-disallow-host-namespaces.yaml`) | **DITOLAK saat Admission** | HTTP 400/403 Webhook rejection; Pod tidak pernah dibuat |
| **T1525** | Supply Chain Compromise | Men-deploy citra kontainer yang tidak ditandatangani (*unsigned image*) | Cosign v2.4.3 + Kyverno `verifyImages` (`03-verify-image-signature.yaml`) | **DITOLAK saat Admission** | Webhook menolak (`no signatures found`); Tangkapan layar [`kyverno-cosign-enforcement.png`](images/kyverno-cosign-enforcement.png) |
| **T1525** | Tag Tampering / Image Poaching | Penyerang menimpa tag OCI yang dapat diubah (`:2h`) di registry | Kyverno `mutateDigest: true` | **DIMUTASI OTOMATIS** | Tag `:2h` diubah otomatis ke SHA256 digest permanen (`@sha256:7cefa5...`) |
| **T1552.007** | Credential Access / SA Token | Proses di container membaca `/var/run/secrets/.../token` | Tetragon eBPF `security_file_open` (`01-block-sensitive-files.yaml`) | **DIBUNUH KERNEL (`SIGKILL`)** | Proses dihentikan instan di level kernel VFS (**Exit Code 137**) |
| **T1059.004** | Execution / Unix Shell | Eksekusi interactive shell (`/bin/sh`) di pod produksi | Tetragon eBPF `sys_execve` (`02-block-shell-execution.yaml`) | **DIBUNUH KERNEL (`SIGKILL`)** | Shell ditembak mati di level syscall (**Exit Code 137**); [`tetragon-signkill.png`](images/tetragon-signkill.png) |
| **-** | Operasional Legal (Akurasi) | Eksekusi perintah aplikasi sah (`whoami`, `uname -a`) | Whitelist logic & kprobe target precision | **DIIZINKAN (Exit 0)** | Bebas *false-positive*; Aplikasi berjalan tanpa degradasi performa |
| **T1565.001** | Defense Evasion / Configuration Drift | Manipulasi manual resource klaster langsung via `kubectl edit` | Argo CD GitOps Engine (`selfHeal: true`, `prune: true`) | **DIPULIHKAN OTOMATIS** | State klaster kembali otomatis sesuai deklarasi Git; [`argocd-platform-overview.png`](images/argocd-platform-overview.png) |

---

## 3. Rincian dan Bukti Pembuktian Empiris

### A. Lapisan Jaringan (Cilium eBPF & Hubble)
1. **Frontend Legitimate Ingress:**
   ```bash
   kubectl -n secure-demo exec frontend -- curl -s -I -m 3 http://backend-svc
   # Hasil: HTTP/1.1 200 OK (Allowed via NetworkPolicy allow-frontend-to-backend)
   ```
2. **Attacker Lateral Movement Drop:**
   ```bash
   kubectl -n secure-demo exec attacker -- curl -s -I -m 3 http://backend-svc
   # Hasil: command terminated with exit code 28 (Packet dropped by Cilium eBPF data path)
   ```
   Visualisasi Hubble UI membuktikan paket berstatus `DROPPED (Policy denied)` pada aliran komunikasi L3/L4.

### B. Lapisan Pintu Masuk / Supply Chain (Kyverno & Cosign)
1. **Penolakan Pod Berbahaya:**
   ```text
   admission webhook "validate.kyverno.svc-fail" denied the request:
   resource Pod/secure-demo/privileged-pod was blocked due to:
   disallow-privileged-containers: Privileged mode is strictly forbidden!
   ```
2. **Penolakan Citra Tanpa Tanda Tangan:**
   ```text
   admission webhook "mutate.kyverno.svc-fail" denied the request:
   resource Pod/secure-demo/unsigned-image-pod was blocked due to:
   verify-image-signature: failed to verify image: no signatures found
   ```
3. **Penerimaan Citra Sah dan Penguncian Digest:**
   Citra sah diterima dan referensi image dimutasi secara permanen menjadi:
   `ttl.sh/hardened-demo-signed:2h@sha256:7cefa58bd70cbf86bb0ef44b9c27a9c6a633763977ea40868d1bfe9278967b25`

### C. Lapisan Runtime (Tetragon eBPF In-Kernel Enforcement)
1. **Pembunuhan Proses Pencurian Token:**
   ```bash
   kubectl -n secure-demo exec attacker -- cat /var/run/secrets/kubernetes.io/serviceaccount/token
   # Hasil: command terminated with exit code 137 (SIGKILL)
   ```
2. **Pembunuhan Proses Interactive Shell:**
   ```bash
   kubectl -n secure-demo exec attacker -- /bin/sh -c "echo breached"
   # Hasil: command terminated with exit code 137 (SIGKILL)
   ```
3. **Verifikasi Operasional Normal:**
   ```bash
   kubectl -n secure-demo exec attacker -- whoami
   # Hasil: curl_user (Exit 0)
   kubectl -n secure-demo exec attacker -- uname -a
   # Hasil: Linux attacker 6.8.0-146-generic ... (Exit 0)
   ```

---

## 4. Evaluasi Ketahanan dan Keunggulan Arsitektur

1. **Shift-Left Security:**  
   Ancaman konfigurasi dan supply chain dipotong di pintu gerbang (*Admission Phase*). Pod penyerang tidak pernah membebani worker node atau mengisi etcd.
2. **Zero-Trust Network Isolation:**  
   Komunikasi antar-pod dikontrol ketat pada tingkat kernel eBPF tanpa overhead iptables tradisional.
3. **Deterministik Tanpa Latensi (In-Kernel SIGKILL):**  
   Penggunaan eBPF kprobe (`security_file_open` dan `sys_execve`) menghilangkan *time-to-detect latency window* yang biasanya menjadi kelemahan fatal pada sistem berbasis userspace daemon (seperti Falco lama).
4. **Git-Centric Single Source of Truth:**  
   Seluruh platform dideklarasikan murni sebagai kode (*Infrastructure as Code*) di Git dan direkonsiliasi otomatis oleh Argo CD, mencegah *configuration drift* dan sabotase manual.

---

## 5. Kesimpulan Audit

Platform Kubernetes yang dibangun telah berhasil memenuhi seluruh kriteria keamanan tingkat lanjut untuk lingkungan produksi:
- ✅ **Integritas Node & Kernel:** Lolos audit konfigurasi kernel eBPF dan BTF (Fase 0-1).
- ✅ **Otomasi GitOps:** Rantai rekonsiliasi App-of-Apps berstatus 100% Synced & Healthy (Fase 2).
- ✅ **Observabilitas & Jaringan:** 82/82 tes konektivitas lulus dan Zero-Trust aktif (Fase 3).
- ✅ **Integritas Rantai Pasok:** Citra diverifikasi kriptografis dengan Cosign (Fase 4).
- ✅ **Pertahanan Runtime Kernel:** Penegakan `SIGKILL` 137 aktif membunuh ancaman real-time (Fase 5).

Platform ini siap dipresentasikan sebagai karya portofolio tingkat tinggi yang membuktikan penguasaan mendalam atas teknologi Linux Kernel, eBPF, Kubernetes Internals, dan DevSecOps modern.
