# 07. Observabilitas eBPF (Hubble) dan Penegakan Zero-Trust Network Policy

Tanggal pengerjaan: 2026-10-12 s.d. 2026-10-13  
Fase: 3 (langkah 3.1 sampai 3.3)

## Tujuan

1. Mengaktifkan mesin observabilitas jaringan eBPF (Hubble Relay dan Hubble UI) secara deklaratif melalui GitOps Argo CD tanpa konfigurasi imperatif manual.
2. Memperoleh visibilitas grafis real-time terhadap peta layanan (*Service Map*) dan alur komunikasi antar-pod pada klaster.
3. Memvalidasi stabilitas konektivitas jaringan klaster secara komprehensif menggunakan `cilium connectivity test` (82/82 tes berhasil).
4. Menerapkan arsitektur keamanan jaringan **Zero-Trust** (*Default-Deny Ingress/Egress*) dan mengevaluasi penanganan dependensi CoreDNS port 53.
5. Membuktikan secara empiris pembatasan hak akses terkecil (*least-privilege*) dengan memblokir pod penyusup (`attacker`) di level kernel eBPF dan merekam visualisasi paket yang dibuang (**`DROPPED: Policy denied`**) di dashboard Hubble UI.

## Versi komponen

| Komponen | Versi | Sumber / Keterangan |
|---|---|---|
| Cilium CNI | 1.20.2 | Dikelola secara deklaratif via Argo CD |
| Hubble Relay | v1.20.2 (`quay.io/cilium/hubble-relay:v1.20.2`) | gRPC Relay service untuk agregasi flow eBPF |
| Hubble UI Backend | v0.13.6 (`quay.io/cilium/hubble-ui-backend:v0.13.6`) | Backend server penyedia stream flow ke UI |
| Hubble UI Frontend | v0.13.6 (`quay.io/cilium/hubble-ui:v0.13.6`) | Nginx Web server dashboard grafis |
| Nginx (Demo Backend) | 1.27.5 (`nginx:1.27-alpine`) | Target server pada namespace `secure-demo` |
| cURL (Demo Client) | 8.10.1 (`curlimages/curl:8.10.1`) | Klien uji `frontend` dan `attacker` |

---

## Langkah 3.1: Pengaktifan Hubble Relay & Hubble UI via GitOps

Mengikuti prinsip GitOps, pengaktifan observabilitas tidak dilakukan dengan perintah imperatif `cilium hubble enable`, melainkan dengan memperbarui deklarasi nilai di repositori Git.

### 1. Deklarasi Helm Values (`gitops/platform/cilium/values.yaml`)
Blok `hubble` ditambahkan ke dalam berkas konfigurasi:

```yaml
# Nilai Helm untuk Cilium 1.20.2 pada klaster k3s lab.
# CIDR pod disamakan dengan bawaan k3s (10.42.0.0/16).
ipam:
  operator:
    clusterPoolIPv4PodCIDRList:
      - "10.42.0.0/16"

hubble:
  relay:
    enabled: true
  ui:
    enabled: true
```

### 2. Rekonsiliasi Otomatis Argo CD
Setelah berkas di-commit dan di-push ke branch `main` GitHub (commit `432cacd`), Argo CD mendeteksi perubahan deklarasi dan memperbarui rilis Helm Cilium secara otomatis.

Verifikasi kesiapan pod di namespace `kube-system`:
```bash
kubectl -n kube-system get pods -l 'k8s-app in (hubble-relay,hubble-ui)'
```

Output:
```text
NAME                            READY   STATUS    RESTARTS   AGE
hubble-relay-59cc868d4d-w7p5c   1/1     Running   0          78s
hubble-ui-5d55f5dcbf-b4h4r      2/2     Running   0          78s
```

Verifikasi status Cilium dan Hubble:
```bash
cilium status
```

Output:
```text
    /¯¯\
 /¯¯\__/¯¯\    Cilium:             OK
 \__/¯¯\__/    Operator:           OK
 /¯¯\__/¯¯\    Envoy DaemonSet:    OK
 \__/¯¯\__/    Hubble Relay:       OK
    \__/       ClusterMesh:        disabled

Deployment             hubble-relay             Desired: 1, Ready: 1/1, Available: 1/1
Deployment             hubble-ui                Desired: 1, Ready: 1/1, Available: 1/1
Cluster Pods:          12/12 managed by Cilium
```
*Hasil:* Hubble Relay berstatus `OK`, dan pod frontend serta backend UI berjalan tanpa gangguan.

---

## Langkah 3.2: Eksplorasi Visual Hubble UI & Validasi Konektivitas Klaster

### A. Akses Dashboard Grafis Hubble UI
Dashboard grafis dibuka di laptop host menggunakan port-forward ke port `12000`:

```bash
cilium hubble ui
```
Browser terbuka ke `http://localhost:12000`. Dashboard menampilkan visualisasi topologi Service Map secara interaktif.
- Visualisasi namespace `kube-system`: Didokumentasikan pada [`docs/images/kube-system_hubbleui.png`](file:///home/lavvvet/k8s-hardened-platform/docs/images/kube-system_hubbleui.png).
- Visualisasi namespace `argocd`: Didokumentasikan pada [`docs/images/argo-cd_hubbleui.png`](file:///home/lavvvet/k8s-hardened-platform/docs/images/argo-cd_hubbleui.png).

### B. Pengujian Stabilitas Jaringan (`cilium connectivity test`)
Pengujian end-to-end dijalankan untuk memverifikasi fungsionalitas data plane klaster:

```bash
cilium connectivity test --flow-validation=disabled --log-check-only-test-time
```

Output hasil akhir:
```text
[cilium-test-1] All 82 tests (709 actions) successful, 53 tests skipped, 1 scenarios skipped.
```
*Hasil terukur:* Seluruh 82 tes fungsional jaringan (709 aksi) lulus 100% tanpa ada kegagalan.

---

## Langkah 3.3: Implementasi Zero-Trust Network Policy & Pembuktian Packet Drop

### A. Penyusunan Workload Uji di Namespace `secure-demo`
Berkas manifest `gitops/apps/secure-demo/workloads.yaml` diterapkan untuk membuat skenario uji:
1. `backend`: Server Nginx dengan service `backend-svc` pada port 80 (label: `role: backend`).
2. `frontend`: Klien sah berlabel `role: frontend`.
3. `attacker`: Klien penyusup berlabel `role: attacker`.

```bash
kubectl apply -f gitops/apps/secure-demo/workloads.yaml
kubectl -n secure-demo get pods
```

Output:
```text
NAME                       READY   STATUS    RESTARTS   AGE
attacker                   1/1     Running   0          19s
backend-58fdf878b5-k4qjz   1/1     Running   0          19s
frontend                   1/1     Running   0          19s
```

### B. Pengujian Baseline (Sebelum Kebijakan / Kondisi Tidak Aman)
Pengujian konektivitas sebelum NetworkPolicy diterapkan membuktikan perilaku bawaan (*default allow-all*) Kubernetes:

1. Klien sah (`frontend`):
   ```bash
   kubectl -n secure-demo exec frontend -- curl -s -I http://backend-svc
   ```
   Output: `HTTP/1.1 200 OK`

2. Klien tidak sah (`attacker`):
   ```bash
   kubectl -n secure-demo exec attacker -- curl -s -I http://backend-svc
   ```
   Output: `HTTP/1.1 200 OK`

*Temuan empiris:* Pod `attacker` dapat mengakses data backend tanpa rintangan. Tanpa NetworkPolicy, isolasi jaringan antar-pod tidak ada.

### C. Penerapan Kebijakan Zero-Trust (Default-Deny + Selective Allow)

Dua kebijakan deklaratif dibuat di direktori `policies/networkpolicy/`:

#### 1. `policies/networkpolicy/01-default-deny.yaml`
Mengunci seluruh lalu lintas Ingress dan Egress pada namespace `secure-demo`. Egress ke `kube-dns` (port 53 UDP/TCP di `kube-system`) secara eksplisit diizinkan agar resolusi nama domain tetap berfungsi (*menghindari jebakan isolasi DNS*):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: secure-demo
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  egress:
  - to:
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
```

#### 2. `policies/networkpolicy/02-allow-frontend-to-backend.yaml`
Menerapkan prinsip *least-privilege*: hanya pod berlabel `role: frontend` yang diizinkan mengirim lalu lintas keluar ke `backend`, dan pod `backend` hanya menerima lalu lintas masuk pada port 80 dari pod `role: frontend`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: secure-demo
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          role: frontend
    ports:
    - protocol: TCP
      port: 80
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-egress-to-backend
  namespace: secure-demo
spec:
  podSelector:
    matchLabels:
      role: frontend
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: backend
    ports:
    - protocol: TCP
      port: 80
```

Penerapan kebijakan:
```bash
kubectl apply -f policies/networkpolicy/
kubectl -n secure-demo get networkpolicies
```

Output:
```text
NAME                               POD-SELECTOR    AGE
allow-frontend-egress-to-backend   role=frontend   21s
allow-frontend-to-backend          app=backend     21s
default-deny-all                   <none>          21s
```

### D. Pengujian Pembuktian Keamanan (Sesudah Kebijakan)

1. **Uji Klien Sah (`frontend`):**
   ```bash
   kubectl -n secure-demo exec frontend -- curl -s -I -m 3 http://backend-svc
   ```
   Output:
   ```text
   HTTP/1.1 200 OK
   Server: nginx/1.27.5
   Connection: keep-alive
   ```
   *Hasil:* Klien sah tetap dapat berkomunikasi dengan lancar tanpa terganggu kebijakan default-deny.

2. **Uji Klien Tidak Sah (`attacker`):**
   ```bash
   kubectl -n secure-demo exec attacker -- curl -s -I -m 3 http://backend-svc
   ```
   Output:
   ```text
   command terminated with exit code 28
   ```
   *Hasil:* Paket SYN dari pod penyusup langsung dibuang di level kernel eBPF (*dropped*), menyebabkan perintah cURL mengalami batas waktu koneksi (*Connection timed out*, exit code 28).

3. **Bukti Visual pada Observabilitas Hubble UI:**
   Pada dashboard Hubble UI (`http://localhost:12000`), alur lalu lintas dari pod `attacker` menuju `backend` terekam sebagai garis merah terang dengan status penegakan:
   > **`DROPPED (Policy denied)`**

   Tangkapan layar bukti penegakan keamanan ini tersimpan di:
   [`docs/images/fase3_hubble-drop.png`](file:///home/lavvvet/k8s-hardened-platform/docs/images/fase3_hubble-drop.png).

---

## Masalah dan keputusan

1. **Distingsi Arsitektur Port: Port 4245 (gRPC) vs Port 12000 (Web UI)**
   - Masalah: Upaya membuka `http://127.0.0.1:4245` di browser web menghasilkan kesalahan `read: connection reset by peer`.
   - Penyebab: Port 4245 adalah endpoint biner gRPC milik Hubble Relay (untuk komunikasi mesin-ke-mesin seperti CLI dan backend UI). Permintaan HTTP biasa dari browser ditolak dengan TCP Reset (RST).
   - Solusi: Akses antarmuka pengguna manusia (Web UI) menggunakan service `hubble-ui` di port 12000 (`http://localhost:12000`), sedangkan port 4245 disediakan khusus untuk perkakas CLI penguji.
2. **False-Alarm Restart Counter pada `check-log-errors` Pasca-Reboot Host**
   - Masalah: Skenario uji `check-log-errors` menandai kegagalan karena mendeteksi `RESTARTS: 1` pada pod sistem lama.
   - Analisis: Restart counter tersebut bertambah bukan karena crash pod, melainkan karena host laptop dimatikan dan VM dinyalakan kembali (siklus booting mesin normal di KVM).
   - Solusi: Untuk memvalidasi status nol kesalahan, pod sistem di-rollout restart (`kubectl rollout restart ds/cilium ...`), dan flag `--log-check-only-test-time` digunakan agar evaluasi log dibatasi hanya selama jendela pengujian berlangsung.
3. **Penyelamatan Egress DNS pada Kebijakan Default-Deny**
   - Masalah: Menerapkan `default-deny-egress` secara naif menyebabkan kegagalan resolusi nama domain pod (`kube-dns` tidak dapat dihubungi), sehingga komunikasi antar-layanan terputus bahkan sebelum aturan L4 dievaluasi.
   - Keputusan: Aturan egress port 53 (UDP dan TCP) ke pod `k8s-app: kube-dns` di namespace `kube-system` secara eksplisit disertakan pada manifest `01-default-deny-all.yaml`.
4. **False-Negative Pattern Matching Flow Validator pada Jaringan Tunneling**
   - Masalah: Skrip penguji CLI mengalami ketidakcocokan pola (*matched: 0*) saat memvalidasi alur pod-ke-service lintas node pada jaringan tunnel VXLAN, meskipun data paket berhasil diteruskan penuh (`FORWARDED`).
   - Keputusan: Validasi stabilitas data plane dievaluasi secara independen menggunakan flag `--flow-validation=disabled`, menghasilkan rapor 82/82 lulus penuh, sementara observabilitas aliran paket diverifikasi langsung melalui inspeksi visual Hubble UI.

---

## Status

- [x] 3.1 Pengaktifan Hubble Relay & Hubble UI secara deklaratif via GitOps Argo CD (`cilium status` OK)
- [x] 3.2 Akses dashboard visual Hubble UI di browser dan pengujian konektivitas klaster (82/82 tes sukses)
- [x] 3.3 Implementasi Zero-Trust Network Policy (Default-Deny + L4 Allow) dan pembuktian empiris penegakan eBPF (`attacker` diblokir, tercatat `DROPPED` di Hubble UI)
- [x] Screenshot Service Map dan Paket Dropped di `docs/images/` (`argo-cd_hubbleui.png`, `kube-system_hubbleui.png`, `fase3_hubble-drop.png`)

---

## Sumber (diakses 2026-10-12 s.d. 2026-10-13)

- Cilium Hubble Observability: https://docs.cilium.io/en/stable/observability/hubble/
- Cilium Network Policy Concepts: https://docs.cilium.io/en/stable/security/policy/
- Kubernetes Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Hubble UI Documentation: https://docs.cilium.io/en/stable/observability/hubble-ui/
