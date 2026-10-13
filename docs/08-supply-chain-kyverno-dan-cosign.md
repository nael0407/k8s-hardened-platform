# 08. Supply Chain Security dan Admission Control (Kyverno dan Cosign)

Tanggal pengerjaan: 2026-10-13  
Fase: 4 (Langkah 4.1 sampai 4.3)

## Tujuan

1. Menginstalasi engine Admission Control Kyverno v1.19.1 secara deklaratif melalui GitOps Argo CD pola App-of-Apps.
2. Mengatasi karakteristik rekonsiliasi etcd pada CustomResourceDefinition (CRD) subchart Helm yang memiliki kamus label kosong (`labels: {}`) menggunakan konfigurasi deklaratif `ignoreDifferences`.
3. Menegakkan Pod Security Standards (PSS Baseline & Restricted) menggunakan Kyverno `ClusterPolicy` untuk mencegah eskalasi privilege kontainer (`privileged: true`) dan pembagian namespace kernel host (`hostPID`, `hostIPC`, `hostNetwork`).
4. Membuktikan secara empiris efektivitas *Admission Webhook* di gerbang API Kubernetes pada namespace `secure-demo`: pod standar berhasil dibuat, sedangkan pod penyerang ditolak seketika sebelum disimpan ke etcd atau dijadwalkan ke node.
5. Memasang dan memverifikasi integritas kriptografis CLI `cosign` v2.4.3 pada laptop host (`sebastian`) dengan pencocokan checksum SHA256 resmi Sigstore.
6. Mengimplementasikan rantai pasok aman (*Supply Chain Security*) melalui penandatanganan citra (*Image Signing*) dan verifikasi kriptografis deklaratif Kyverno `verifyImages`.
7. Membuktikan penolakan citra tanpa tanda tangan (*unsigned image*), penerimaan citra bertanda tangan valid (*signed image*), serta mutasi otomatis referensi citra dari *mutable tag* menjadi *immutable cryptographic digest* (`@sha256:...`) untuk menggagalkan serangan *tag tampering*.

## Versi komponen

| Komponen | Versi | Sumber / Keterangan |
|---|---|---|
| Kyverno | v1.19.1 (Chart 3.9.1) | Helm Repository `https://kyverno.github.io/kyverno/` |
| Kyverno Admission Controller | v1.19.1 | Webhook controller untuk mutasi, validasi, dan verifikasi |
| Kyverno Background Controller | v1.19.1 | Controller rekonsiliasi berkala untuk resource eksisting |
| Kyverno Cleanup Controller | v1.19.1 | Controller retensi dan pembersihan resource berkala |
| Kyverno Reports Controller | v1.19.1 | Controller agregasi PolicyReport di klaster |
| Cosign CLI | v2.4.3 | Binary rilis resmi Sigstore (`cosign-linux-amd64`) |
| OCI Registry Uji | `ttl.sh` | Public anonymous ephemeral OCI registry (lab standard) |
| Citra Basis Uji | `alpine:latest` | Citra ringan Linux untuk simulasi beban kerja aplikasi |

---

## Langkah 4.1: Instalasi Kyverno via GitOps Argo CD

Pemasangan Kyverno dilakukan secara murni deklaratif mengikuti arsitektur GitOps App-of-Apps yang telah dibangun pada Fase 2.

### 1. Deklarasi Helm Values Non-HA (`gitops/platform/kyverno/values.yaml`)
Untuk efisiensi sumber daya pada lingkungan lab 3 VM (1 server, 2 agent), jumlah replika controller diatur ke 1:

```yaml
admissionController:
  replicas: 1

backgroundController:
  replicas: 1

cleanupController:
  replicas: 1

reportsController:
  replicas: 1
```

### 2. Deklarasi Child Application (`gitops/bootstrap/apps/kyverno.yaml`)
Menggunakan pola *Multiple Sources* Argo CD untuk mengombinasikan upstream Helm chart Kyverno dengan berkas `values.yaml` internal di repositori Git:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kyverno
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources:
    - repoURL: 'https://kyverno.github.io/kyverno/'
      chart: kyverno
      targetRevision: 3.9.1
      helm:
        valueFiles:
          - $values/gitops/platform/kyverno/values.yaml
    - repoURL: 'https://github.com/nael0407/k8s-hardened-platform.git'
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: kyverno
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
  ignoreDifferences:
    - group: apiextensions.k8s.io
      kind: CustomResourceDefinition
      jqPathExpressions:
        - .metadata.labels
```

### 3. Analisis Teknis: Rekonsiliasi CRD dan `ignoreDifferences`
Saat instalasi awal, Argo CD mendeteksi status `OutOfSync` pada 11 CustomResourceDefinition (CRD) subchart `kyverno-api` (misal `validatingpolicies.policies.kyverno.io`).
- **Akar Masalah:** Subchart mendefinisikan `labels: {}` (kamus kosong) pada manifest CRD. Kubernetes API Server secara otomatis memangkas (*strip*) kunci kosong tersebut saat persistensi objek ke etcd. Akibatnya, pembanding 3-way diff Argo CD melihat git memiliki `labels: {}` sedangkan live object di klaster tidak memilikinya.
- **Resolusi:** Konfigurasi `ignoreDifferences` dengan `jqPathExpressions: [".metadata.labels"]` diterapkan pada level `CustomResourceDefinition`. Argo CD berhasil mengabaikan perbedaan label kosong tanpa memengaruhi integritas CRD.

Verifikasi kesiapan pod di namespace `kyverno`:
```bash
kubectl -n kyverno get pods
```

Output:
```text
NAME                                            READY   STATUS      RESTARTS   AGE
kyverno-admission-controller-c8db7fccd-9lkql    1/1     Running     0          4m29s
kyverno-background-controller-f687dc8b9-hzcpv   1/1     Running     0          4m29s
kyverno-cleanup-controller-c545758c8-mq47z      1/1     Running     0          4m29s
kyverno-migrate-resources-mrf84                 0/1     Completed   0          3m25s
kyverno-reports-controller-5d4d7cf5c5-6qxbb     1/1     Running     0          4m29s
```
Semua 4 controller utama berstatus `1/1 Running`, job migrasi selesai (`Completed`), dan webhook configurations terdaftar aktif di klaster.

---

## Langkah 4.2: Penegakan Pod Security Standards (PSS) via Admission Webhook

Admission Controller bertindak sebagai garis pertahanan pertama (*Gatekeeper*). Pada model Kubernetes, setiap permintaan mutasi resource (`CREATE`, `UPDATE`) wajib melewati fase:
$$\text{Authentication} \longrightarrow \text{Authorization (RBAC)} \longrightarrow \text{Admission Control (Webhook)} \longrightarrow \text{etcd}$$

Jika sebuah manifest melanggar aturan di level Validating Webhook, permintaan langsung dibatalkan dengan kode status HTTP 400/403, sehingga container berbahaya tidak akan pernah dijadwalkan (*never scheduled*) ke node pekerja.

### 1. Kebijakan Melarang Privileged Container (`policies/kyverno/01-disallow-privileged.yaml`)
Privileged container memiliki akses langsung ke seluruh perangkat keras host dan dapat dengan mudah menembus batas isolasi kontainer (*container breakout*).

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged-containers
  annotations:
    policies.kyverno.io/title: Disallow Privileged Containers
    policies.kyverno.io/category: Pod Security Standards (Baseline)
    policies.kyverno.io/severity: high
    policies.kyverno.io/description: >-
      Privileged containers can easily escape isolation and gain full control over
      the host node. This policy ensures that containers are not run with privileged access,
      while exempting critical platform namespaces (kube-system, kyverno, argocd).
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: validate-privileged
      match:
        any:
          - resources:
              kinds:
                - Pod
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kyverno
                - argocd
      validate:
        message: "Privileged mode is strictly forbidden! Field securityContext.privileged must be false or omitted."
        pattern:
          spec:
            =(ephemeralContainers):
              - =(securityContext):
                  =(privileged): "false"
            =(initContainers):
              - =(securityContext):
                  =(privileged): "false"
            containers:
              - =(securityContext):
                  =(privileged): "false"
```

> **Keputusan Arsitektur Whitelist:** Namespace platform `kube-system`, `kyverno`, dan `argocd` dikecualikan secara eksplisit. Hal ini mutlak diperlukan karena agen jaringan low-level seperti Cilium DaemonSet membutuhkan akses kernel langsung untuk memuat program eBPF (*extended Berkeley Packet Filter*).

### 2. Kebijakan Melarang Host Namespaces (`policies/kyverno/02-disallow-host-namespaces.yaml`)
Mencegah kontainer berbagi namespace proses (`hostPID`), network (`hostNetwork`), atau IPC (`hostIPC`) milik node host:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-host-namespaces
  annotations:
    policies.kyverno.io/title: Disallow Host Namespaces
    policies.kyverno.io/category: Pod Security Standards (Baseline)
    policies.kyverno.io/severity: high
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: validate-host-namespaces
      match:
        any:
          - resources:
              kinds:
                - Pod
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kyverno
                - argocd
      validate:
        message: "Sharing host namespaces (hostPID, hostIPC, hostNetwork) is strictly forbidden!"
        pattern:
          spec:
            =(hostPID): "false"
            =(hostIPC): "false"
            =(hostNetwork): "false"
```

### 3. Pembuktian Empiris Uji Penyerangan Pod Security

| Skenario Uji | Manifest Uji | Parameter Pelanggaran | Hasil Aktual | Keterangan |
|---|---|---|---|---|
| **Uji Pod Jinak (Legal)** | `attack-tests/kyverno/02-unprivileged-pod.yaml` | Tidak ada (`privileged: false`) | **Diterima (`created`)** | Pod berstatus `1/1 Running` |
| **Uji Penyerang Privileged** | `attack-tests/kyverno/01-privileged-pod.yaml` | `securityContext.privileged: true` | **Ditolak Webhook** | HTTP Admission Denied |
| **Uji Penyerang HostPID** | `attack-tests/kyverno/03-hostpid-pod.yaml` | `spec.hostPID: true` | **Ditolak Webhook** | HTTP Admission Denied |

**Bukti Output Penolakan Privileged Pod:**
```text
lavvvet@sebastian:~/k8s-hardened-platform$ kubectl apply -f attack-tests/kyverno/01-privileged-pod.yaml 
Error from server: error when creating "attack-tests/kyverno/01-privileged-pod.yaml": admission webhook "validate.kyverno.svc-fail" denied the request: 

resource Pod/secure-demo/privileged-pod was blocked due to the following policies 

disallow-privileged-containers:
  validate-privileged: 'validation error: Privileged mode is strictly forbidden! Field securityContext.privileged must be false or omitted. rule validate-privileged failed at path /spec/containers/0/securityContext/privileged/'
```

**Bukti Output Penolakan HostPID Pod:**
```text
lavvvet@sebastian:~/k8s-hardened-platform$ kubectl apply -f attack-tests/kyverno/03-hostpid-pod.yaml
Error from server: error when creating "attack-tests/kyverno/03-hostpid-pod.yaml": admission webhook "validate.kyverno.svc-fail" denied the request: 

resource Pod/secure-demo/hostpid-pod was blocked due to the following policies 

disallow-host-namespaces:
  validate-host-namespaces: 'validation error: Sharing host namespaces (hostPID, hostIPC, hostNetwork) is strictly forbidden!. rule validate-host-namespaces failed at path /spec/hostPID/'
```

Verifikasi namespace `secure-demo` membuktikan kedua pod berbahaya tersebut tidak pernah masuk ke dalam daftar resource klaster.

---

## Langkah 4.3: Penegakan Rantai Pasok Kriptografis (Cosign & verifyImages)

Ancaman rantai pasok (*Supply Chain Attack*) dapat terjadi apabila penyerang menimpa (*tag overwriting/poisoning*) citra kontainer di registri publik dengan citra jahat. Pertahanan diterapkan dengan mewajibkan tanda tangan digital berbasis pasangan kunci ECDSA (P-256) menggunakan alat standar Sigstore, **Cosign**.

### 1. Pemasangan dan Verifikasi Integritas CLI Cosign v2.4.3
Binary diunduh ke `/tmp`, diverifikasi dengan hash SHA256 resmi Sigstore, lalu dipasang ke direktori sistem:

```bash
# Hash resmi Sigstore untuk release v2.4.3 linux-amd64
echo "caaad125acef1cb81d58dcdc454a1e429d09a750d1e9e2b3ed1aed8964454708  cosign-linux-amd64" | sha256sum -c
# Output: cosign-linux-amd64: OK

sudo install -m 0755 cosign-linux-amd64 /usr/local/bin/cosign
cosign version
```

### 2. Pembuatan Kunci dan Manajemen Kunci Aman
Pasangan kunci dibuat di direktori `certs/cosign/`:
```bash
cosign generate-key-pair
```
- `cosign.key`: Kunci privat ECDSA. Dilindungi oleh `.gitignore` (`*.key`) sehingga **tidak pernah terdorong ke repositori Git publik**.
- `cosign.pub`: Kunci publik ECDSA. Disimpan di repositori untuk referensi verifikasi:
  ```text
  -----BEGIN PUBLIC KEY-----
  MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE+c/cUzT7ajSjFehkGs7BdV8x+Etj
  pQhTdvnmwT7H1xdqcNN2HljTlP1o53V5wB/WT5ZjFddDTVbtdMypxbcYYA==
  -----END PUBLIC KEY-----
  ```

### 3. Kebijakan Verifikasi Citra Kyverno (`policies/kyverno/03-verify-image-signature.yaml`)
Kebijakan didefinisikan secara deklaratif untuk mencegat setiap pod di namespace `secure-demo` yang merujuk pada pola citra `ttl.sh/hardened-demo-*`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature
  annotations:
    policies.kyverno.io/title: Verify Image Signatures
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: high
    policies.kyverno.io/description: >-
      Verifies that container images deployed in secure-demo namespace are cryptographically
      signed by our Cosign public key. Unsigned images are strictly rejected.
spec:
  validationFailureAction: Enforce
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-signature
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - secure-demo
      verifyImages:
        - imageReferences:
            - "ttl.sh/hardened-demo-*"
          mutateDigest: true
          attestors:
            - entries:
                - keys:
                    publicKeys: |
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE+c/cUzT7ajSjFehkGs7BdV8x+Etj
                      pQhTdvnmwT7H1xdqcNN2HljTlP1o53V5wB/WT5ZjFddDTVbtdMypxbcYYA==
                      -----END PUBLIC KEY-----
                    rekor:
                      ignoreTlog: true
```

#### Catatan Desain Penting:
1. **`rekor.ignoreTlog: true`**: Saat menandatangani citra dengan kunci privat lokal (`--tlog-upload=false`), tanda tangan tidak didorong ke log transparansi publik global Rekor. Opsi ini memerintahkan Kyverno memverifikasi tanda tangan langsung terhadap `publicKeys` lokal tanpa mencari entri di server Rekor eksternal.
2. **`mutateDigest: true`**: Fitur esensial Kyverno. Saat verifikasi kriptografis lolos, Kyverno secara otomatis **memutasi referensi tag citra (`:2h`) menjadi digest kriptografis SHA256 (`@sha256:...`)**. Dengan demikian, kontainer runtime hanya akan menarik bit citra persis yang telah ditandatangani, menghilangkan celah serangan manipulasi tag di kemudian hari.

---

### 4. Persiapan Citra OCI & Penandatanganan Digital
Dua varian citra didorong ke OCI registry publik `ttl.sh`:

```bash
# 1. Siapkan citra
docker pull alpine:latest
docker tag alpine:latest ttl.sh/hardened-demo-unsigned:2h
docker tag alpine:latest ttl.sh/hardened-demo-signed:2h

# 2. Push ke OCI registry
docker push ttl.sh/hardened-demo-unsigned:2h
docker push ttl.sh/hardened-demo-signed:2h

# 3. Tandatangani HANYA citra kedua
cosign sign --key certs/cosign/cosign.key --tlog-upload=false ttl.sh/hardened-demo-signed:2h
```
Cosign mengunggah artefak tanda tangan digital (`.sig`) secara langsung berdampingan dengan manifes OCI di `ttl.sh`.

---

### 5. Hasil Pembuktian Empiris Verifikasi Citra

#### Uji A: Deploy Citra Tanpa Tanda Tangan (`attack-tests/kyverno/04-unsigned-image-pod.yaml`)
```bash
kubectl apply -f attack-tests/kyverno/04-unsigned-image-pod.yaml
```

**Output Aktual:**
```text
Error from server: error when creating "attack-tests/kyverno/04-unsigned-image-pod.yaml": admission webhook "mutate.kyverno.svc-fail" denied the request: 

resource Pod/secure-demo/unsigned-image-pod was blocked due to the following policies 

verify-image-signature:
  verify-signature: 'failed to verify image ttl.sh/hardened-demo-unsigned:2h: .attestors[0].entries[0].keys: no signatures found'
```
*Hasil:* Permintaan pembuatan pod **DITOLAK**. Webhook memverifikasi ke OCI registry dan mendeteksi ketiadaan artefak tanda tangan Cosign.

#### Uji B: Deploy Citra Bertanda Tangan Valid (`attack-tests/kyverno/05-signed-image-pod.yaml`)
```bash
kubectl apply -f attack-tests/kyverno/05-signed-image-pod.yaml
```

**Output Aktual:**
```text
pod/signed-image-pod created
```
*Hasil:* Permintaan pembuatan pod **DITERIMA**. Webhook memvalidasi keabsahan tanda tangan kriptografis terhadap `cosign.pub`.

#### Uji C: Bukti Mutasi Digest Otomatis
Pemeriksaan spesifikasi kontainer pod yang berjalan:
```bash
kubectl -n secure-demo get pod signed-image-pod -o jsonpath='{.spec.containers[0].image}{"\n"}'
```

**Output Aktual:**
```text
ttl.sh/hardened-demo-signed:2h@sha256:7cefa58bd70cbf86bb0ef44b9c27a9c6a633763977ea40868d1bfe9278967b25
```
*Hasil:* Kyverno secara otomatis mengunci image spec ke digest `sha256:7cefa58bd70cbf86bb0ef44b9c27a9c6a633763977ea40868d1bfe9278967b25`, membuktikan pertahanan *Supply Chain Security* aktif sempurna.

---

## Kesimpulan Fase 4

1. **Kyverno Admission Controller v1.19.1** berhasil dipasang secara deklaratif via Argo CD dengan pola App-of-Apps, dengan resolusi perbedaan CRD `labels: {}` melalui `ignoreDifferences`.
2. **Pod Security Standards** terbukti aktif di gerbang API Kubernetes: container dengan hak istimewa tinggi (`privileged: true`) dan pembagian namespace host (`hostPID: true`) ditolak seketika sebelum menyentuh etcd atau worker node.
3. **Supply Chain Security dengan Cosign v2.4.3** terbukti efektif:
   - Citra tanpa tanda tangan ditolak seketika (`no signatures found`).
   - Citra bertanda tangan valid diterima dan dieksekusi secara normal.
   - Mutasi otomatis ke immutable digest terverifikasi aktif, mencegah potensi serangan pembajakan tag di registri OCI.
4. Klaster kini memiliki proteksi multi-layer:
   - **Layer Jaringan:** Cilium eBPF Zero-Trust NetworkPolicy (Fase 3).
   - **Layer Admission & Supply Chain:** Kyverno + Cosign (Fase 4).
   - **Layer Runtime:** Siap dilanjutkan ke **Fase 5 (Runtime Threat Enforcement dengan Tetragon eBPF)**.
