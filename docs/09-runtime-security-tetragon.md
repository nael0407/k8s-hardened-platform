# 09. Runtime Security dan In-Kernel Threat Enforcement dengan Tetragon (eBPF)

Tanggal pengerjaan: 2026-10-14  
Fase: 5 (Langkah 5.1 sampai 5.3)

## Tujuan

1. Menginstalasi engine keamanan runtime berbasis eBPF, **Tetragon v1.7.1**, secara deklaratif menggunakan GitOps Argo CD pola App-of-Apps pada namespace `kube-system`.
2. Memverifikasi penggelaran DaemonSet Tetragon di seluruh node klaster (`k3s-server`, `k3s-agent1`, `k3s-agent2`) dengan memanfaatkan kernel Linux 6.8 yang memiliki dukungan BTF (*BPF Type Format*) dan kprobe.
3. Memasang dan memvalidasi CLI resmi `tetra` v1.7.1 di laptop host (`sebastian`) dengan verifikasi checksum SHA256 resmi Cilium.
4. Memperoleh visibilitas runtime mendalam (*Runtime Observability*) terhadap siklus hidup proses di dalam container (eksekusi biner, argumen, parent process, PID, UID, dan namespace).
5. Mengidentifikasi dan menganalisis jejak container runtime low-level (`/proc/self/fd/6 init` oleh `runc`) secara forensik di tingkat kernel.
6. Menerapkan penegakan keamanan in-kernel (*In-Kernel Enforcement*) menggunakan Custom Resource `TracingPolicyNamespaced` pada namespace `secure-demo`.
7. Mengonfigurasi dan membuktikan secara empiris pemblokiran ancaman runtime menggunakan sinyal kernel **`SIGKILL` (Exit Code 137)**:
   - Pemblokiran pencurian kredensial klaster (*Credential Access / ServiceAccount Token Harvesting* - MITRE ATT&CK T1552.007).
   - Pemblokiran eksekusi shell interaktif tidak sah (*Unauthorized Interactive Shell Execution*) di pod produksi.
8. Memvalidasi bahwa perintah legal non-eksploitatif (`whoami`, `uname -a`) tetap berjalan normal (Exit Code 0), membuktikan akurasi dan nol *false-positive* pada kebijakan keamanan yang diterapkan.

## Versi komponen

| Komponen | Versi | Sumber / Keterangan |
|---|---|---|
| Tetragon | v1.7.1 (Chart 1.7.1) | Helm Repository `https://helm.cilium.io/` |
| Tetragon Agent | v1.7.1 (`quay.io/cilium/tetragon:v1.7.1`) | DaemonSet sensor eBPF beroperasi di `hostNetwork` |
| Tetragon Operator | v1.7.1 (`quay.io/cilium/tetragon-operator:v1.7.1`) | Controller pengelola CRD TracingPolicy |
| Export-Stdout | v1.1.1 (`quay.io/cilium/hubble-export-stdout:v1.1.1`) | Sidecar streaming event JSON real-time |
| Tetra CLI | v1.7.1 | Binary resmi client Tetragon Linux amd64 |
| Target Uji (Pod Attacker) | `docker.io/curlimages/curl:8.10.1` | Pod di namespace `secure-demo` (Node `k3s-agent2`) |

---

## Langkah 5.1: Instalasi Tetragon Deklaratif via GitOps Argo CD

Tetragon dipasang secara GitOps penuh memanfaatkan integrasi Helm dan pola App-of-Apps yang telah ada.

### 1. Deklarasi Helm Values (`gitops/platform/tetragon/values.yaml`)
Untuk efisiensi lab non-HA, operator dijalankan dengan 1 replika, dan instalasi CRD diserahkan kepada operator:

```yaml
# Nilai konfigurasi Helm untuk Tetragon 1.7.1 pada klaster k3s lab.
# DaemonSet berjalan di semua node, operator berjalan 1 replika (non-HA).

tetragonOperator:
  enabled: true
  replicas: 1
  tracingPolicy:
    enabled: true

crds:
  installMethod: "operator"
```

### 2. Deklarasi Child Application (`gitops/bootstrap/apps/tetragon.yaml`)
Menggunakan fitur *Multiple Sources* Argo CD untuk menarik chart upstream `https://helm.cilium.io/` dan menggabungkannya dengan deklarasi `values.yaml` dari Git internal kita:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tetragon
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources:
    - repoURL: 'https://helm.cilium.io/'
      chart: tetragon
      targetRevision: 1.7.1
      helm:
        valueFiles:
          - $values/gitops/platform/tetragon/values.yaml
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

> **Catatan Arsitektur:** Namespace target adalah `kube-system`. Namespace ini telah dikecualikan (*whitelisted*) dari kebijakan ketat Kyverno Pod Security Standards pada Fase 4. Pengecualian ini krusial karena Tetragon DaemonSet membutuhkan hak akses kernel (`privileged: true`, `hostNetwork: true`, mount direktori `/sys/kernel/btf` dan `/sys/fs/bpf`).

### 3. Rekonsiliasi Otomatis & Verifikasi Pod
Setelah di-commit dan di-push (commit `88cd2fd`), Argo CD `root-application` mendaftarkan aplikasi Tetragon, dan seluruh pod berhasil berjalan tanpa hambatan:

```bash
kubectl -n kube-system get pods -l 'app.kubernetes.io/name in (tetragon,tetragon-operator)' -o wide
```

Output:
```text
NAME                                 READY   STATUS    RESTARTS   AGE   IP               NODE         NOMINATED NODE   READINESS GATES
tetragon-4zzwh                       2/2     Running   0          42s   192.168.122.11   k3s-agent1   <none>           <none>
tetragon-w8g52                       2/2     Running   0          42s   192.168.122.12   k3s-agent2   <none>           <none>
tetragon-jgmlv                       2/2     Running   0          43s   192.168.122.10   k3s-server   <none>           <none>
tetragon-operator-787f7bdbcc-rbxtz   1/1     Running   0          22s   10.42.1.49       k3s-server   <none>           <none>
```
Status di Argo CD terverifikasi **Synced to 1.7.1** dan **Healthy**. CRD `tracingpolicies.cilium.io` dan `tracingpoliciesnamespaced.cilium.io` terdaftar aktif di klaster.

---

## Langkah 5.2: Observabilitas Runtime dan Eksplorasi CLI `tetra`

### 1. Pemasangan CLI `tetra` di Laptop Host
Binary client `tetra` v1.7.1 diunduh dan diverifikasi integritasnya menggunakan checksum SHA256 resmi rilis Cilium:

```bash
# Checksum resmi: cc78dca1cfb121e59c33be482d59c73db8cb34bf7abb73750480044fcc1c9206
curl -L -o /tmp/tetra-linux-amd64.tar.gz "https://github.com/cilium/tetragon/releases/download/v1.7.1/tetra-linux-amd64.tar.gz"
echo "cc78dca1cfb121e59c33be482d59c73db8cb34bf7abb73750480044fcc1c9206  /tmp/tetra-linux-amd64.tar.gz" | sha256sum -c
# Output: OK

tar -zxvf /tmp/tetra-linux-amd64.tar.gz -C /tmp tetra
sudo install -m 0755 /tmp/tetra /usr/local/bin/tetra
tetra version # CLI version: v1.7.1
```

### 2. Streaming Event Real-Time eBPF
Streaming event diuji menggunakan pipe log container `export-stdout` ke CLI `tetra` dengan filter namespace `secure-demo`:

```bash
kubectl -n kube-system logs -f -l app.kubernetes.io/name=tetragon -c export-stdout | tetra getevents -o compact --namespace secure-demo
```

Saat perintah dieksekusi di dalam pod `attacker`:
```bash
kubectl -n secure-demo exec attacker -- whoami
kubectl -n secure-demo exec attacker -- ls -la /
kubectl -n secure-demo exec attacker -- uname -a
```

Event yang tertangkap di level kernel eBPF:
```text
🚀 process secure-demo/attacker /usr/bin/whoami                           
💥 exit    secure-demo/attacker /usr/bin/whoami  0               
🚀 process secure-demo/attacker /bin/ls "-la /"                           
💥 exit    secure-demo/attacker /bin/ls "-la /" 0                
🚀 process secure-demo/attacker /bin/uname -a                             
💥 exit    secure-demo/attacker /bin/uname -a 0                  
```

#### Analisis Forensik:
- Setiap pemanggilan biner menghasilkan event `🚀 process` (`sys_enter_execve`) lengkap dengan argumen aslinya.
- Setiap proses yang selesai menghasilkan event `💥 exit` dengan return code `0`.
- Event `/proc/self/fd/6 init` tertangkap saat container runtime (`runc`) menginisialisasi sesi eksekusi melalui anonymous file descriptor, membuktikan kedalaman pantauan eBPF tanpa celah buta (*blind spots*).

---

## Langkah 5.3: Penegakan Ancaman Runtime (*In-Kernel SIGKILL Enforcement*)

Berbeda dari alat keamanan tradisional berbasis userspace yang memiliki latensi deteksi, Tetragon mengeksekusi tindakan langsung di dalam kernel Linux sebelum panggilan sistem selesai diproses.

### 1. Kebijakan Melarang Pembacaan Kredensial Sensitif (`policies/tracingpolicy/01-block-sensitive-files.yaml`)

```yaml
apiVersion: cilium.io/v1alpha1
kind: TracingPolicyNamespaced
metadata:
  name: block-sensitive-files
  namespace: secure-demo
spec:
  kprobes:
    - call: "security_file_open"
      syscall: false
      return: false
      args:
        - index: 0
          type: "file"
      selectors:
        - matchArgs:
            - index: 0
              operator: "Prefix"
              values:
                - "/etc/shadow"
                - "/run/secrets/kubernetes.io/serviceaccount"
                - "/var/run/secrets/kubernetes.io/serviceaccount"
          matchActions:
            - action: Sigkill
```

#### Temuan Desain & Investigasi Forensik:
1. **Analisis Symlink `/var/run` ke `/run`:**  
   Pada kernel Linux modern, direktori `/var/run` adalah symlink yang merujuk ke `/run`. Hook `security_file_open` pada Virtual File System (VFS) mengevaluasi path fisik kanonikal (`/run/secrets/kubernetes.io/serviceaccount/...`). Menambahkan prefix `/run/secrets/` dan `/var/run/secrets/` memastikan penegakan bekerja baik pada path langsung maupun symlink.
2. **Pemisahan `/etc/shadow` vs `/etc/passwd`:**  
   Pada pengujian awal, penyertaan path `/etc/passwd` menyebabkan utilitas standar seperti `whoami` ikut terbunuh dengan kode 137. Investigasi membuktikan bahwa fungsi libc `getpwuid()` dan container runtime `runc` secara normal membuka `/etc/passwd` untuk mencari metadata user `curl_user`. Dengan mengalihkan target ke berkas otentikasi rahasia `/etc/shadow`, operasional normal pod tetap berjalan sementara file rahasia tetap terlindungi mutlak.

---

### 2. Kebijakan Melarang Eksekusi Interactive Shell (`policies/tracingpolicy/02-block-shell-execution.yaml`)

Pada container produksi, tidak ada kebutuhan bisnis untuk menjalankan interactive shell. Keberadaan proses shell merupakan indikator kuat adanya serangan Remote Code Execution (RCE) atau *reverse shell*.

```yaml
apiVersion: cilium.io/v1alpha1
kind: TracingPolicyNamespaced
metadata:
  name: block-shell-execution
  namespace: secure-demo
spec:
  kprobes:
    - call: "sys_execve"
      syscall: true
      args:
        - index: 0
          type: "string"
      selectors:
        - matchArgs:
            - index: 0
              operator: "Postfix"
              values:
                - "/sh"
                - "/bash"
                - "/ash"
          matchActions:
            - action: Sigkill
```

---

### 3. Pembuktian Empiris: Sebelum vs Sesudah Penegakan

Matematika Kode Keluar Linux:  
Ketika proses dihentikan oleh sinyal fatal (*unhandled fatal signal*), kode keluar bernilai $128 + \text{Nomor Sinyal}$.  
Sinyal `SIGKILL` adalah sinyal nomor `9`.  
$$\text{Exit Code} = 128 + 9 = \mathbf{137}$$

| Skenario Uji | Perintah yang Dijalankan | Sebelum Penegakan (Baseline) | Sesudah Penegakan (Tetragon In-Kernel) | Keterangan |
|---|---|---|---|---|
| **Akses Token ServiceAccount** | `cat /var/run/secrets/kubernetes.io/serviceaccount/token` | **Berhasil terbaca** (`eyJhbGci...`, Exit 0) | **DIBUNUH KERNEL (`exit code 137`)** | Kredensial klaster aman dari pencurian |
| **Eksekusi Interactive Shell** | `/bin/sh -c "echo breached"` | **Berhasil eksekusi** (`breached`, Exit 0) | **DIBUNUH KERNEL (`exit code 137`)** | Eksekusi shell ilegal digagalkan |
| **Perintah Legal (`whoami`)** | `whoami` | Berhasil (`curl_user`, Exit 0) | **Tetap Berhasil (`curl_user`, Exit 0)** | Bebas *false-positive* |
| **Perintah Legal (`uname`)** | `uname -a` | Berhasil (Info kernel, Exit 0) | **Tetap Berhasil (Info kernel, Exit 0)** | Bebas *false-positive* |

#### Bukti Terminal Aktual (Sesudah Kebijakan Aktif):
```text
lavvvet@sebastian:~$ kubectl -n secure-demo exec attacker -- cat /var/run/secrets/kubernetes.io/serviceaccount/token
command terminated with exit code 137

lavvvet@sebastian:~$ kubectl -n secure-demo exec attacker -- /bin/sh -c "echo breached"
command terminated with exit code 137

lavvvet@sebastian:~$ kubectl -n secure-demo exec attacker -- whoami
curl_user

lavvvet@sebastian:~$ kubectl -n secure-demo exec attacker -- uname -a
Linux attacker 6.8.0-146-generic #146-Ubuntu SMP PREEMPT_DYNAMIC Thu Sep  3 16:12:30 UTC 2026 x86_64 Linux
```

---

## Kesimpulan Fase 5

1. **Tetragon v1.7.1** berhasil dipasang secara deklaratif via Argo CD dengan pola App-of-Apps, berjalan stabil di seluruh 3 node VM (kernel 6.8.0-142 dengan dukungan BTF dan kprobe).
2. **Observabilitas Runtime** membuktikan kemampuan eBPF dalam menangkap setiap panggilan sistem proses secara presisi tanpa membebani performa container runtime.
3. **In-Kernel Threat Enforcement** terbukti bekerja secara deterministik:
   - Upaya pencurian token ServiceAccount klaster digagalkan seketika di level VFS kernel (`security_file_open`) dengan terminasi paksa `SIGKILL` (Exit Code 137).
   - Upaya pembukaan interactive shell digagalkan seketika di level syscall `sys_execve` dengan terminasi paksa `SIGKILL` (Exit Code 137).
   - Seluruh perintah legal aplikasi tetap berjalan mulus dengan exit code 0.
4. Klaster kini memiliki sistem pertahanan komprehensif 3-Lapis (*Complete Triple-Layer Defense-in-Depth*):
   - **Layer Jaringan:** Cilium eBPF Zero-Trust (Fase 3).
   - **Layer Pintu Masuk:** Kyverno + Cosign Supply Chain Admission (Fase 4).
   - **Layer Runtime:** Tetragon eBPF In-Kernel Enforcement (Fase 5).
5. Klaster siap melangkah ke **Fase 6 (Skenario Pengujian Menyeluruh, Dokumentasi Portofolio, dan Pengemasan Akhir)**.
