# 05. Akses kubectl, Helm, dan Cilium

Tanggal pengerjaan: 2026-10-11
Fase: 1 (langkah 1.5a sampai 1.5c)

## Tujuan

Mengakses klaster dari laptop (bukan hanya lewat SSH ke server), lalu memasang Cilium sebagai CNI dan penegak NetworkPolicy sehingga ketiga node berpindah dari `NotReady` ke `Ready`.

Urutan bootstrap: CNI dipasang lebih dulu secara manual dengan berkas nilai yang disimpan di repo, karena ArgoCD sendiri butuh jaringan pod untuk berjalan. Di Fase 2 ArgoCD mengadopsi Cilium dengan chart dan nilai yang sama. Detail adopsi dipastikan ke dokumentasi saat Fase 2.

## Versi komponen

| Komponen | Versi |
|---|---|
| kubectl (laptop) | v1.36.5 (repositori apt `pkgs.k8s.io` v1.36), Kustomize v5.8.1 |
| k3s / Kubernetes (server) | v1.36.5+k3s1 |
| Helm | v4.3.0, commit `bec5b06ed841fe5269972d864d5177944fd5970f` |
| Cilium (chart dan aplikasi) | 1.20.2 |
| Cilium CLI | v0.20.1 (go1.27.1) |
| Image `cilium` | `quay.io/cilium/cilium:v1.20.2@sha256:2939231d0d3e3ebddcd80fffa168b7ddcc78fdf0dc864d1c8c126ff523c54f01` |
| Image `cilium-envoy` | `quay.io/cilium/cilium-envoy:v1.37.6-1789133542-cbec91f666af0bf742da986d43832932dbb26b82@sha256:af7382699576b9e65e9184efa52eeca0b58aea70ad6e511bf260c91d9f740463` |
| Image `cilium-operator` | `quay.io/cilium/operator-generic:v1.20.2@sha256:64d8798350e8569b8e7622563fed6e44dce2625f311e4651b774816516c744fc` |

## Langkah 1.5a: akses kubectl dari laptop

Dua hal diverifikasi ke dokumentasi:
- Kubeconfig k3s (`/etc/rancher/k3s/k3s.yaml`) memberi akses `system:admin` dan grup `system:masters`, yaitu akses tak terbatas ke seluruh klaster. Untuk akses dari luar, berkas disalin dan nilai `server` diganti dengan IP server. Dokumentasi menyatakan salinan tidak diperbarui otomatis ketika sertifikat berubah.
- kubectl harus berada dalam satu versi minor dari klaster. Klaster 1.36, sehingga repositori `v1.36` dipakai (bukan 1.37 yang terbaru, meski keduanya dalam rentang toleransi).

```bash
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update && sudo apt-get install -y kubectl
```

Kubeconfig disalin ke berkas terpisah, dengan izin `600` sejak awal:

```bash
(umask 077; ssh -i ~/.ssh/k8s-lab k8sadmin@192.168.122.10 'sudo cat /etc/rancher/k3s/k3s.yaml' \
  | sed 's#https://127.0.0.1:6443#https://192.168.122.10:6443#' > ~/.kube/k3s-lab.yaml)
export KUBECONFIG=$HOME/.kube/k3s-lab.yaml
```

Hasil (isi kubeconfig sengaja tidak dicantumkan karena itu kredensial admin):

```text
-rw------- 1 lavvvet lavvvet 2946 ... /home/lavvvet/.kube/k3s-lab.yaml
5:    server: https://192.168.122.10:6443

Client Version: v1.36.5
Kustomize Version: v5.8.1
Server Version: v1.36.5+k3s1
```

Keputusan: kubeconfig disimpan sebagai berkas terpisah (`k3s-lab.yaml`), bukan `~/.kube/config`, supaya tidak menimpa konfigurasi lain, dan diaktifkan per terminal lewat `KUBECONFIG`. Letaknya di luar repo.

## Instalasi Helm dengan verifikasi

Binary rilis resmi dipakai (bukan skrip atau paket komunitas), dengan verifikasi tiga lapis dari dua jalur terpisah (CDN `get.helm.sh` dan halaman rilis GitHub).

| Pemeriksaan | Hasil |
|---|---|
| SHA-256 hasil hitung lokal | `86584a54def73570558f66f5111cc53dfed56689637ae32c1201205d494f54fb` |
| SHA-256 dari berkas `.sha256sum` (`get.helm.sh`) | `86584a54def73570558f66f5111cc53dfed56689637ae32c1201205d494f54fb` |
| SHA-256 di halaman rilis GitHub | `86584a54def73570558f66f5111cc53dfed56689637ae32c1201205d494f54fb` |
| `sha256sum -c` | `helm-v4.3.0-linux-amd64.tar.gz: OK` |
| Tanda tangan GPG | `Good signature from "Scott Rigby <scott@r6by.com>"` |
| Sidik jari kunci | `208D D36E D5BB 3745 A167 43A4 C7C6 FBB5 B91C 1155`, sama dengan yang tertulis di halaman rilis |

```text
gpg: Good signature from "Scott Rigby <scott@r6by.com>" [unknown]
gpg: WARNING: This key is not certified with a trusted signature!
Primary key fingerprint: 208D D36E D5BB 3745 A167  43A4 C7C6 FBB5 B91C 1155

version.BuildInfo{Version:"v4.3.0", GitCommit:"bec5b06ed841fe5269972d864d5177944fd5970f", GitTreeState:"clean", GoVersion:"go1.27.1", KubeClientVersion:"v1.37"}
```

Peringatan `not certified with a trusted signature` normal: kunci belum ditandai terpercaya secara lokal. Kepercayaan di sini bersumber dari kecocokan sidik jari dengan halaman rilis. Dokumentasi Helm menyarankan menyimpan salinan kunci lokal.

## Langkah 1.5b: pasang Cilium dengan Helm

Berkas `gitops/platform/cilium/values.yaml`:

```yaml
ipam:
  operator:
    clusterPoolIPv4PodCIDRList:
      - "10.42.0.0/16"
```

CIDR pod disamakan dengan bawaan k3s, sesuai panduan Cilium untuk k3s. Hubble belum dinyalakan; dikerjakan di Fase 3.

Repositori Helm tradisional dipakai, dengan alasan: dokumentasi Cilium menyatakan kedua cara (OCI dan repositori tradisional) didukung penuh, dan contoh perintah OCI di halaman itu menulis `1.20.2` tanpa flag `--version`, yang tampaknya salah ketik. Verifikasi cosign untuk chart OCI dibahas ulang di Fase 4.

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update
helm search repo cilium/cilium --versions | head -n 5
helm template cilium cilium/cilium --version 1.20.2 --namespace kube-system \
  -f gitops/platform/cilium/values.yaml | grep -n -i "cluster-pool"
```

```text
NAME         	CHART VERSION	APP VERSION
cilium/cilium	1.20.2       	1.20.2
cilium/cilium	1.20.1       	1.20.1
cilium/cilium	1.20.0       	1.20.0
cilium/cilium	1.19.8       	1.19.8

262:  ipam: "cluster-pool"
264:  cluster-pool-ipv4-cidr: "10.42.0.0/16"
265:  cluster-pool-ipv4-mask-size: "24"
```

Render dicek sebelum pemasangan untuk memastikan berkas nilai terbaca. Blok per node berukuran `/24` (sekitar 254 alamat pod per node).

Pemasangan:

```bash
helm install cilium cilium/cilium --version 1.20.2 --namespace kube-system \
  -f gitops/platform/cilium/values.yaml
```

```text
NAME: cilium
LAST DEPLOYED: Sun Oct 11 10:35:31 2026
NAMESPACE: kube-system
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
```

Pemantauan pod (cuplikan):

```text
cilium-wn7zl                      0/1   Pending             0   0s
cilium-wn7zl                      0/1   Init:0/6            0   1s
cilium-envoy-6598b                0/1   ContainerCreating   0   26s
cilium-operator-65857c7db4-6srk8  1/1   Running             0   107s
cilium-envoy-xwj8h                0/1   Running             0   2m6s
```

Hasil akhir:

```text
NAME         STATUS   ROLES           AGE   VERSION        INTERNAL-IP
k3s-agent1   Ready    <none>          14h   v1.36.5+k3s1   192.168.122.11
k3s-agent2   Ready    <none>          14h   v1.36.5+k3s1   192.168.122.12
k3s-server   Ready    control-plane   14h   v1.36.5+k3s1   192.168.122.10

NAME                              READY   STATUS    RESTARTS   AGE     IP
cilium-envoy-*  (3 pod)           1/1     Running   0          4m42s   (IP node, host networking)
cilium-*        (3 pod)           1/1     Running   0          4m42s   (IP node, host networking)
cilium-operator-* (2 pod)         1/1     Running   0          4m42s
coredns-7cfb7bc9c7-79bb4          0/1     Running   0          14h     10.42.1.167
local-path-provisioner-...        1/1     Running   0          14h     10.42.1.104
metrics-server-...                0/1     Running   0          14h     10.42.1.67

NAME  	NAMESPACE  	REVISION	STATUS  	CHART        	APP VERSION
cilium	kube-system	1       	deployed	cilium-1.20.2	1.20.2
```

Angka terukur: seluruh pod Cilium sudah `Running` dan ketiga node `Ready` pada saat pod Cilium berusia 4 menit 42 detik setelah `helm install`. Itu batas atas (tangkapan diambil setelah semuanya siap), bukan benchmark. Komponen pertama yang `Running` adalah `cilium-operator` pada detik ke-107, dan sebagian besar waktunya habis untuk mengunduh image dari `quay.io` bersamaan di tiga node lewat WiFi.

Alamat pod `10.42.1.x` berasal dari blok `/24` milik `k3s-server` di dalam `10.42.0.0/16`, membuktikan konfigurasi CIDR bekerja. Pod `cilium-*` dan `cilium-envoy-*` memakai IP node karena berjalan di jaringan host.

Tangkapan lanjutan setelah beberapa jam:

```text
cilium-* , cilium-envoy-* , cilium-operator-*   1/1 Running   0 restart   4h50m
coredns-7cfb7bc9c7-79bb4                        1/1 Running   0           19h
local-path-provisioner-77b9867795-5d5jd         1/1 Running   0           19h
metrics-server-6dc596dfb8-t2d78                 1/1 Running   0           19h
```

`coredns` dan `metrics-server` yang sebelumnya `0/1` ternyata hanya belum lulus probe saat tangkapan pertama (diduga baru dijadwalkan setelah node `Ready`); kini `1/1`.

## Langkah 1.5c: Cilium CLI dan validasi

```bash
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --fail --retry 5 --retry-delay 3 --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-amd64.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
```

```text
Cilium CLI: v0.20.1
cilium-linux-amd64.tar.gz: OK

cilium-cli: v0.20.1 compiled with go1.27.1 on linux/amd64
cilium image (default): v1.20.1
cilium image (stable): v1.20.2
cilium image (running): 1.20.2
```

`cilium status --wait`:

```text
Cilium:             OK
Operator:           OK
Envoy DaemonSet:    OK
Hubble Relay:       disabled
ClusterMesh:        disabled

DaemonSet     cilium           Desired: 3, Ready: 3/3, Available: 3/3
DaemonSet     cilium-envoy     Desired: 3, Ready: 3/3, Available: 3/3
Deployment    cilium-operator  Desired: 2, Ready: 2/2, Available: 2/2
Cluster Pods: 3/3 managed by Cilium
Helm chart version: 1.20.2
```

`Hubble Relay: disabled` menegaskan Relay belum menyala, sesuai rencana.

## Masalah dan keputusan

**1. Unduhan Helm terputus.** `curl: (18) Transferred a partial file` pada unduhan 19,3 MB (berhenti sekitar 20%). Penyebab diduga koneksi terputus. Solusi: lanjutkan unduhan dengan `curl -C - --retry 5`, lalu validasi ulang dengan `sha256sum`. Berkas akhir berukuran 20.321.063 byte dan lolos pemeriksaan. Verifikasi checksum bukan formalitas: ia melindungi dari berkas parsial.

**2. Galat 404 pada berkas tanda tangan `.asc`.** Pada instruksi awal, `.asc` diunduh dari `get.helm.sh` (kekeliruan: nama itu hanya diasumsikan dari contoh dokumentasi). Halaman rilis GitHub menyatakan tanda tangan dilampirkan pada rilis, sehingga berkas diunduh dari `github.com/helm/helm/releases/download/v4.3.0/`. Koreksi ini sekaligus membuka jalur verifikasi kedua: checksum dan sidik jari kunci dari halaman rilis, terpisah dari CDN unduhan.

**3. Teks `NOTES` Cilium menyebut "with Hubble".** Catatan pasca-pemasangan menyebut "successfully installed Cilium with Hubble", padahal Relay belum dinyalakan. `cilium status` memastikan `Hubble Relay: disabled` dan tidak ada pod `hubble-relay`. Teks itu dianggap templat umum chart. Hubble dibahas di Fase 3.

**4. Dua pod `0/1` sesaat setelah node `Ready`.** `coredns` dan `metrics-server` berstatus `Running` tetapi `0/1` pada tangkapan awal, dan `1/1` pada tangkapan berikutnya. Dugaan: probe kesiapan belum lulus saat baru dijadwalkan.

**5. Checksum Cilium CLI berasal dari rilis yang sama.** `sha256sum --check` memberi `OK`, tetapi checksum diunduh dari rilis yang sama dengan binary, sehingga ini membuktikan integritas unduhan, bukan keaslian. Berbeda dengan Helm, verifikasi dari sumber terpisah belum dikerjakan untuk CLI.

**6. Versi bawaan CLI berbeda dari versi terpasang.** `cilium image (default)` v1.20.1 sedangkan `running` 1.20.2, karena Cilium dipasang lewat Helm dengan versi dikunci. Konsekuensi: jangan menjalankan `cilium install` atau `cilium upgrade` tanpa versi eksplisit. Pengelolaan versi dilakukan lewat Helm dan, di Fase 2, ArgoCD.

**7. Seluruh komponen sistem berada di control plane.** `coredns`, `local-path-provisioner`, dan `metrics-server` dijadwalkan di `k3s-server` karena k3s tidak memberi taint pada server secara bawaan. Belum mengganggu; dicatat sebagai pertanyaan untuk fase hardening.

## Status

- [x] 1.5a Akses `kubectl` dari laptop
- [x] 1.5b Helm dan Cilium 1.20.2 terpasang, tiga node `Ready`
- [x] 1.5c Cilium CLI, `cilium status` `OK`
- [ ] Tes konektivitas Cilium (opsional)
- [ ] Commit `gitops/platform/cilium/values.yaml`
- [ ] Screenshot `kubectl get nodes -o wide` (tiga node `Ready`) dan `cilium status`

## Sumber (diakses 2026-10-11)

- K3s Cluster Access: https://docs.k3s.io/cluster-access
- Kubernetes, instalasi kubectl di Linux: https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
- Helm, Installing Helm: https://helm.sh/docs/intro/install/
- Rilis Helm v4.3.0: https://github.com/helm/helm/releases/tag/v4.3.0
- Cilium, Installation using Helm: https://docs.cilium.io/en/stable/installation/k8s-install-helm/
- Cilium, Installation Using K3s: https://docs.cilium.io/en/stable/installation/k3s/
