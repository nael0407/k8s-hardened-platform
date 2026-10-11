# 06. GitOps Engine: Argo CD dan Adopsi Deklaratif Cilium

Tanggal pengerjaan: 2026-10-11  
Fase: 2 (langkah 2.1 sampai 2.4)

## Tujuan

Memasang Argo CD v3.5.4 sebagai mesin GitOps di klaster k3s, menghubungkannya ke repositori Git (`https://github.com/nael0407/k8s-hardened-platform.git`) sebagai sumber kebenaran deklaratif tunggal (*single source of truth*), menerapkan pola **App-of-Apps**, serta mengadopsi rilis Helm Cilium 1.20.2 yang sebelumnya dipasang manual di Fase 1 agar sepenuhnya dikelola oleh GitOps tanpa *downtime* atau *restart* pod jaringan.

## Versi komponen

| Komponen | Versi | Sumber / Keterangan |
|---|---|---|
| Argo CD Server | v3.5.4 | Rilis stabil GitHub, diuji resmi (*tested*) untuk Kubernetes v1.36 |
| Argo CD CLI | v3.5.4 (`v3.5.4+d6d5b24`) | Binary resmi Linux amd64, Go 1.26.4 |
| Kubernetes | v1.36.5 (`v1.36.5+k3s1`) | Klaster k3s pada VM node Fase 0 |
| Cilium (chart & app) | 1.20.2 | Repositori Helm resmi `https://helm.cilium.io/` |

---

## Langkah 2.1: Pembuatan namespace dan instalasi manifest Argo CD v3.5.4

Sesuai audit dokumentasi resmi Argo CD, versi **3.5** secara eksplisit diuji kompatibilitasnya dengan **Kubernetes v1.36**. Manifest non-HA multi-tenant dikunci pada tag rilis `v3.5.4` (bukan branch `stable` yang dinamis).

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.4/manifests/install.yaml
```

Keputusan desain teknis:
1. **Server-Side Apply (`--server-side`):** Diwajibkan oleh dokumentasi Argo CD. CRD `applicationsets.argoproj.io` berukuran sangat besar dan melampaui batas anotasi `kubectl.kubernetes.io/last-applied-configuration` (maksimal 262 KB pada client-side apply). Server-Side Apply menghindari batasan ini dengan melacak kepemilikan field langsung di kontroler Kubernetes (`managedFields`).
2. **`--force-conflicts`:** Memastikan kontroler mengambil alih kepemilikan field tanpa konflik field manager.
3. **NetworkPolicy bawaan:** Manifest `install.yaml` membawa 7 NetworkPolicy bawaan (Redis, Dex, Repo Server, Controller, dll.) dengan tipe `Ingress` yang mengisolasi lalu lintas internal antar-komponen Argo CD, sementara lalu lintas `Egress` (ke GitHub, DNS, dan API Server) tetap terbuka penuh.

Output (ringkasan):
```text
customresourcedefinition.apiextensions.k8s.io/applications.argoproj.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/applicationsets.argoproj.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/appprojects.argoproj.io serverside-applied
serviceaccount/argocd-application-controller serverside-applied
...
deployment.apps/argocd-server serverside-applied
statefulset.apps/argocd-application-controller serverside-applied
networkpolicy.networking.k8s.io/argocd-application-controller-network-policy serverside-applied
networkpolicy.networking.k8s.io/argocd-applicationset-controller-network-policy serverside-applied
networkpolicy.networking.k8s.io/argocd-dex-server-network-policy serverside-applied
networkpolicy.networking.k8s.io/argocd-notifications-controller-network-policy serverside-applied
networkpolicy.networking.k8s.io/argocd-redis-network-policy serverside-applied
networkpolicy.networking.k8s.io/argocd-repo-server-network-policy serverside-applied
networkpolicy.networking.k8s.io/argocd-server-network-policy serverside-applied
```

---

## Langkah 2.2: Verifikasi kesiapan workload dan distribusi pod

Pemeriksaan status pod dan penempatan node:

```bash
kubectl -n argocd get pods -o wide
kubectl -n argocd get svc
```

Output terukur:

```text
NAME                                               READY   STATUS    RESTARTS   AGE     IP            NODE         NOMINATED NODE   READINESS GATES
argocd-application-controller-0                    1/1     Running   0          4m14s   10.42.0.40    k3s-agent1   <none>           <none>
argocd-applicationset-controller-5d7d5896f-8926g   1/1     Running   0          4m14s   10.42.2.248   k3s-agent2   <none>           <none>
argocd-dex-server-674d8c59ff-tm98v                 1/1     Running   0          4m14s   10.42.0.5     k3s-agent1   <none>           <none>
argocd-notifications-controller-564d78577b-f452b   1/1     Running   0          4m14s   10.42.0.14    k3s-agent1   <none>           <none>
argocd-redis-55d565584d-h9tnb                      1/1     Running   0          4m14s   10.42.2.158   k3s-agent2   <none>           <none>
argocd-repo-server-6995847c8-88vjv                 1/1     Running   0          4m14s   10.42.0.111   k3s-agent1   <none>           <none>
argocd-server-79c5c9ccc8-jr2tw                     1/1     Running   0          4m14s   10.42.2.224   k3s-agent2   <none>           <none>
```

Analisis terukur:
1. **Kesehatan pod:** Seluruh 7 pod mencapai status `1/1 Running` dalam waktu 4 menit 14 detik dengan 0 restart.
2. **Isolasi control plane:** Tidak ada satu pun pod Argo CD yang dijadwalkan di `k3s-server`. Seluruh pod terdistribusi secara seimbang antara `k3s-agent1` (4 pod) dan `k3s-agent2` (3 pod).
3. **Pembuktian IPAM Cilium:**
   - Pod pada `k3s-agent1` mendapatkan blok IP `10.42.0.x`.
   - Pod pada `k3s-agent2` mendapatkan blok IP `10.42.2.x`.
   - Hal ini membuktikan alokasi blok CIDR pod `/24` per node oleh Cilium berjalan sesuai spesifikasi di `gitops/platform/cilium/values.yaml`.

---

## Langkah 2.3: Instalasi CLI Argo CD dan verifikasi akses

### A. Verifikasi integritas binary CLI
Binary diunduh ke `~/lab-tools` bersama berkas checksum resmi dari aset rilis GitHub v3.5.4:

```bash
cd ~/lab-tools
curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/download/v3.5.4/argocd-linux-amd64
curl -sSL -o argocd-v3.5.4-checksums.txt https://github.com/argoproj/argo-cd/releases/download/v3.5.4/cli_checksums.txt

grep "argocd-linux-amd64$" argocd-v3.5.4-checksums.txt | sha256sum -c
sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
argocd version --client
```

Output:
```text
argocd-linux-amd64: OK

argocd: v3.5.4+d6d5b24
  BuildDate: 2026-10-06T20:35:03Z
  GitCommit: d6d5b248ce00e1a2c512068002a93d3319767087
  GitTreeState: clean
  GoVersion: go1.26.4
  Compiler: gc
  Platform: linux/amd64
```

### B. Akses dan pembacaan credential
Password admin bawaan dibuat otomatis oleh Argo CD dan disimpan dalam bentuk rahasia di secret Kubernetes:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```
*(Nilai password disamarkan demi keamanan dan tidak pernah disimpan di repositori Git).*

Uji koneksi awal menggunakan fitur port-forwarding internal bawaan CLI:

```bash
argocd app list --port-forward --port-forward-namespace argocd
```

Output:
```text
NAME  CLUSTER  NAMESPACE  PROJECT  STATUS  HEALTH  SYNCPOLICY  CONDITIONS  REPO  PATH  TARGET
```

---

## Langkah 2.4: Pola App-of-Apps dan adopsi Cilium oleh Argo CD

### A. Desain struktur direktori GitOps
Struktur direktori repositori diatur mengikuti pola App-of-Apps standar:

```text
gitops/
├── bootstrap/
│   ├── root-application.yaml     # Aplikasi induk (App-of-Apps)
│   └── apps/
│       └── cilium.yaml           # Aplikasi anak (Child App untuk CNI Cilium)
└── platform/
    └── cilium/
        └── values.yaml           # Nilai Helm deklaratif Cilium
```

### B. Konfigurasi Child Application (`gitops/bootstrap/apps/cilium.yaml`)
Aplikasi ini memanfaatkan fitur **Multiple Sources** resmi Argo CD:
1. Sumber 1: Chart Helm dari repositori publik upstream (`https://helm.cilium.io/`, chart `cilium`, versi `1.20.2`).
2. Sumber 2: Repositori Git proyek (`https://github.com/nael0407/k8s-hardened-platform.git`, targetRevision `main`, `ref: values`), yang memuat berkas nilai lokal di `$values/gitops/platform/cilium/values.yaml`.
3. Adopsi tanpa *downtime*: Menggunakan sync option `ServerSideApply=true` dan `prune: false` pada tahap bootstrap awal.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cilium
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources:
    - repoURL: 'https://helm.cilium.io/'
      chart: cilium
      targetRevision: 1.20.2
      helm:
        valueFiles:
          - $values/gitops/platform/cilium/values.yaml
    - repoURL: 'https://github.com/nael0407/k8s-hardened-platform.git'
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
```

### C. Konfigurasi Root Application (`gitops/bootstrap/root-application.yaml`)
Aplikasi induk memantau direktori `gitops/bootstrap/apps` di Git dan menerapkan semua manifest aplikasi anak ke namespace `argocd`.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-application
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: 'https://github.com/nael0407/k8s-hardened-platform.git'
    targetRevision: main
    path: gitops/bootstrap/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

### D. Eksekusi dan pembuktian adopsi GitOps

Setelah manifest di-commit dan di-push ke GitHub (`commit f2005cd`), root application diterapkan ke klaster:

```bash
kubectl apply -f gitops/bootstrap/root-application.yaml
```

Hasil verifikasi:

```bash
argocd app list --port-forward --port-forward-namespace argocd
```

```text
NAME                     CLUSTER                         NAMESPACE    PROJECT  STATUS  HEALTH   SYNCPOLICY  CONDITIONS  REPO                                                   PATH                   TARGET
argocd/cilium            https://kubernetes.default.svc  kube-system  default  Synced  Healthy  Auto        <none>      https://helm.cilium.io/                                                       1.20.2
argocd/root-application  https://kubernetes.default.svc  argocd       default  Synced  Healthy  Auto-Prune  <none>      https://github.com/nael0407/k8s-hardened-platform.git  gitops/bootstrap/apps  main
```

Verifikasi kesehatan pod Cilium pasca-adopsi:

```bash
kubectl -n kube-system get pods -l app.kubernetes.io/part-of=cilium
```

```text
NAME                               READY   STATUS    RESTARTS   AGE
cilium-envoy-6598b                 1/1     Running   0          11h
cilium-envoy-9ct6v                 1/1     Running   0          11h
cilium-envoy-xwj8h                 1/1     Running   0          11h
cilium-jl8tv                       1/1     Running   0          11h
cilium-mhtr7                       1/1     Running   0          11h
cilium-operator-65857c7db4-6srk8   1/1     Running   0          11h
cilium-operator-65857c7db4-jghnl   1/1     Running   0          11h
cilium-wn7zl                       1/1     Running   0          11h
```

**Fakta keberhasilan terukur:**
- Seluruh pod Cilium mempertahankan usia runtime `11h` dan `0 RESTARTS`.
- Status aplikasi di Argo CD berstatus `Synced` dan `Healthy`.
- Ini membuktikan mekanisme Server-Side Apply berhasil mengalihkan kepemilikan field dari rilis Helm manual ke Argo CD controller tanpa menginterupsi jaringan (*zero-downtime adoption*).

---

## Masalah dan keputusan

1. **Pemotongan baris saat copy-paste URL manifest.**
   - Masalah: Terjadi karakter *newline* di tengah nama domain `raw.githubusercontent.com` saat perintah awal dieksekusi.
   - Solusi: Menyimpan URL ke dalam variabel shell atau menyalin perintah sebagai satu baris utuh.
2. **Pesan log `broken pipe` pada port-forward ephemeral CLI.**
   - Masalah: CLI `argocd` sempat mencetak pesan error `write tcp: broken pipe` sesaat sebelum header tabel ditampilkan.
   - Penyebab: Stream SPDY sementara yang dibuka oleh flag `--port-forward` langsung ditutup segera setelah paket respons gRPC diterima klien. Thread internal `client-go` yang mencoba menulis sisa byte mendapati soket lokal telah tertutup.
   - Diagnosis: Header tabel aplikasi tetap berhasil ditarik dan ditampilkan secara lengkap, sehingga ini adalah perilaku normal penutupan koneksi sementara (bukan kegagalan klaster).
3. **Pemisahan direktori manifest aplikasi dan nilai Helm.**
   - Masalah: Jika `values.yaml` diletakkan di direktori yang sama dengan yang dipantau oleh Root Application (`gitops/bootstrap/apps`), Argo CD akan mencoba mem-parse `values.yaml` sebagai objek Kubernetes dan memunculkan galat `Object 'Kind' is missing`.
   - Solusi: Root Application diarahkan ke `gitops/bootstrap/apps/` (hanya memuat file `Application` CRD), sedangkan file `values.yaml` diletakkan terpisah di `gitops/platform/cilium/values.yaml` dan dirujuk menggunakan parameter Multiple Sources `$values`.
4. **Peringatan domain-qualified finalizer.**
   - Peringatan: `metadata.finalizers: "resources-finalizer.argocd.argoproj.io": prefer a domain-qualified finalizer name`.
   - Catatan: Peringatan ini bersifat konvensional dari API server Kubernetes modern untuk mendorong format domain bertingkat, dan tidak mengganggu fungsi penghapusan kaskade bawaan Argo CD.

---

## Status

- [x] 2.1 Pembuatan namespace `argocd` dan instalasi manifest Argo CD v3.5.4 terkunci (Server-Side Apply)
- [x] 2.2 Verifikasi kesiapan pod dan penempatan node (7 pod Running 1/1, control plane steril)
- [x] 2.3 Unduh dan verifikasi checksum binary CLI `argocd` v3.5.4, pengujian akses login
- [x] 2.4 Penataan arsitektur App-of-Apps, konfigurasi Multiple Sources Cilium, dan adopsi deklaratif tanpa downtime (`Synced` & `Healthy`, 0 restart)
- [ ] Screenshot Web UI dashboard Argo CD (opsional via `kubectl port-forward`) di `docs/images/`

---

## Sumber (diakses 2026-10-11)

- Argo CD Installation Guide: https://argo-cd.readthedocs.io/en/stable/operator-manual/installation/
- Tested Kubernetes Versions: https://argo-cd.readthedocs.io/en/stable/operator-manual/tested-kubernetes-versions/
- Argo CD Multiple Sources: https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/
- Cluster Bootstrapping (App-of-Apps): https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/
- Sync Options (Server-Side Apply & Migration): https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/
