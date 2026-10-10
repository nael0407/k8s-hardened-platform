# 03. Kernel Node: kesiapan eBPF untuk Cilium dan Tetragon

Tanggal pengerjaan: 2026-10-10
Fase: 1 (langkah 1.1, hanya pemeriksaan, tidak ada perubahan pada sistem)

## Tujuan

Memastikan kernel pada node (bukan kernel host) menyediakan fitur yang disyaratkan Cilium dan Tetragon sebelum keduanya dipasang. Dukungan fitur Tetragon, terutama penegakan (enforcement), bergantung pada opsi konfigurasi kernel node, sehingga ini dicek lebih dulu dan dicocokkan dengan dokumentasi resmi.

Pemeriksaan dilakukan di `k3s-server`. Node agent memakai image dasar yang sama, sehingga kernelnya diasumsikan sama. Asumsi itu diverifikasi dengan `uname -r` saat agent bergabung (langkah 1.4).

## Kernel

```text
uname -r
6.8.0-142-generic

ls -l /sys/kernel/btf/vmlinux
-r--r--r-- 1 root root 6101415 Oct 10 13:00 /sys/kernel/btf/vmlinux
```

| Syarat | Menurut dokumentasi | Node |
|---|---|---|
| Versi kernel, Cilium | 5.10 atau lebih baru | 6.8.0-142 (terpenuhi) |
| Versi kernel, Tetragon | 4.19 atau lebih baru | 6.8.0-142 (terpenuhi) |
| BTF | Tetragon memakainya untuk memuat program eBPF (CO-RE); lokasi standar `/sys/kernel/btf/vmlinux` | Ada (terpenuhi) |

## Opsi konfigurasi kernel: syarat Cilium

Sumber: halaman System Requirements Cilium (versi dokumentasi 1.20.2). Dokumentasi menyatakan bahwa opsi yang bisa dibangun sebagai modul maupun statis keduanya valid.

```bash
grep -E "^CONFIG_(BPF|BPF_SYSCALL|BPF_JIT|BPF_EVENTS|DEBUG_INFO_BTF|CGROUPS)=" /boot/config-$(uname -r)
grep -E "^CONFIG_(NET_CLS_BPF|NET_CLS_ACT|NET_SCH_INGRESS|CRYPTO_SHA1|CGROUP_BPF|PERF_EVENTS|SCHEDSTATS|NETFILTER_XT_SET|IP_SET|IP_SET_HASH_IP|NETFILTER_XT_MATCH_COMMENT|VXLAN|GENEVE|FIB_RULES|NET_SCH_FQ)=" /boot/config-$(uname -r)
```

| Opsi | Node | Keterangan |
|---|---|---|
| `BPF`, `BPF_SYSCALL`, `BPF_JIT`, `BPF_EVENTS`, `DEBUG_INFO_BTF`, `CGROUPS` | `y` | Dasar eBPF |
| `CGROUP_BPF`, `PERF_EVENTS`, `SCHEDSTATS`, `CRYPTO_SHA1`, `NET_CLS_ACT` | `y` | Dasar |
| `NET_CLS_BPF`, `NET_SCH_INGRESS` | `m` | Modul, diterima dokumentasi |
| `NETFILTER_XT_SET`, `IP_SET`, `IP_SET_HASH_IP`, `NETFILTER_XT_MATCH_COMMENT` | `m` | Syarat masquerading berbasis iptables (bawaan Cilium) |
| `VXLAN`, `GENEVE` | `m` | Syarat tunneling (mode overlay bawaan) |
| `FIB_RULES` | `y` | Syarat tunneling dan routing |
| `NET_SCH_FQ` | `m` | Syarat Bandwidth Manager (belum dipakai) |

Tidak diperiksa karena fiturnya belum dipakai: opsi untuk kebijakan L7/FQDN (modul `TPROXY` dan sejenisnya), IPsec, dan `NETKIT`. Akan dicek bila fitur itu dipakai.

## Opsi konfigurasi kernel: syarat Tetragon

Sumber: FAQ Tetragon, bagian daftar konfigurasi kernel yang dibutuhkan.

```bash
grep -E "^CONFIG_(BPF_KPROBE_OVERRIDE|FUNCTION_ERROR_INJECTION|BPF_LSM|NAMESPACES|SECURITY_APPARMOR|KPROBES)=" /boot/config-$(uname -r)
grep -E "^CONFIG_(BPF_JIT_DEFAULT_ON|HAVE_BPF_JIT|HAVE_EBPF_JIT|FTRACE_SYSCALLS|DEBUG_INFO_BTF_MODULES|MEMCG|BLK_CGROUP|CGROUP_SCHED|CGROUP_PIDS|CGROUP_FREEZER|CPUSETS|PROC_PID_CPUSET|CGROUP_DEVICE|CGROUP_CPUACCT|CGROUP_PERF)=" /boot/config-$(uname -r)
```

| Kelompok | Opsi | Node |
|---|---|---|
| Inti BPF | `BPF`, `BPF_JIT`, `BPF_JIT_DEFAULT_ON`, `BPF_EVENTS`, `BPF_SYSCALL`, `HAVE_EBPF_JIT`, `FTRACE_SYSCALLS` | Semua `y` |
| BTF | `DEBUG_INFO_BTF`, `DEBUG_INFO_BTF_MODULES` | `y` |
| Penegakan | `BPF_KPROBE_OVERRIDE` | `y` |
| cgroup dan pelacakan proses | `CGROUPS`, `MEMCG`, `BLK_CGROUP`, `CGROUP_SCHED`, `CGROUP_PIDS`, `CGROUP_FREEZER`, `CPUSETS`, `PROC_PID_CPUSET`, `CGROUP_DEVICE`, `CGROUP_CPUACCT`, `CGROUP_PERF`, `CGROUP_BPF` | Semua `y` |
| Tambahan (bukan syarat di FAQ) | `FUNCTION_ERROR_INJECTION`, `BPF_LSM`, `KPROBES`, `NAMESPACES`, `SECURITY_APPARMOR` | Semua `y` |

Satu opsi dari daftar dokumentasi tidak muncul: `HAVE_BPF_JIT`. Contoh keluaran `tetra probe config` pada FAQ yang sama juga menampilkan `CONFIG_HAVE_BPF_JIT:n` berdampingan dengan `CONFIG_HAVE_EBPF_JIT:y`, sehingga ketiadaannya tidak dianggap penghalang. Penentu akhirnya adalah `tetra probe` saat Tetragon sudah berjalan.

Opsi opsional `CGROUP_FAVOR_DYNMODS` (kernel 6.0 ke atas, mengurangi latensi perubahan cgroup dinamis) tidak diperiksa.

## Kondisi saat berjalan

```text
cat /sys/kernel/security/lockdown
none [integrity] confidentiality

cat /sys/kernel/security/lsm
lockdown,capability,landlock,yama,apparmor

stat -fc %T /sys/fs/cgroup
cgroup2fs

ls /sys/firmware/efi  ->  boot UEFI
```

| Pemeriksaan | Hasil | Artinya |
|---|---|---|
| Lockdown | Mode `integrity` | FAQ Tetragon menyatakan hanya mode `confidentiality` yang membuat Tetragon gagal memuat program BPF (`operation not permitted`). Mode `integrity` tidak disebut sebagai penghalang |
| LSM aktif | `bpf` tidak ada | Kernel mendukung BPF LSM (`CONFIG_BPF_LSM=y`) tetapi tidak aktif. Kebijakan `lsmhooks` Tetragon butuh LSM BPF aktif |
| cgroup | v2 (`cgroup2fs`) | Syarat tambahan FAQ untuk cgroup v1 tidak berlaku |
| Firmware | UEFI | Sesuai konfigurasi VM |

## Hasil

Tidak ada penghalang yang ditemukan terhadap daftar syarat resmi Cilium maupun Tetragon pada kernel node. Ini adalah pemeriksaan konfigurasi, bukan bukti bahwa semua fitur berjalan. Bukti akhirnya adalah `cilium status` setelah pemasangan (Fase 1) dan `tetra probe` serta pengujian kebijakan nyata (Fase 5).

## Keputusan desain

**1. Penegakan memakai `Override`, bukan hanya `Sigkill`.** Dokumentasi Tetragon menjelaskan bahwa `Sigkill` menghentikan proses yang melakukan panggilan secara sinkron, tetapi tidak selalu membatalkan operasi yang sedang berjalan (contohnya, `Sigkill` pada `write()` tidak menjamin data belum tertulis). `Override` mengganti nilai kembalian sehingga fungsinya tidak pernah dijalankan, dan dokumentasi menyarankan menggabungkannya dengan `Signal`/`Sigkill` bila operasinya harus dicegah. Klaim "dicegah di level kernel" pada proyek ini hanya kuat jika kebijakan memakai `Override`. Syarat konfigurasinya (`BPF_KPROBE_OVERRIDE`) sudah terpenuhi. Menurut dokumentasi, `Override` bekerja pada panggilan sistem dan fungsi `security_*` (kernel 5.7 ke atas), dan fungsi yang dapat dioverride terdaftar di `/sys/kernel/debug/error_injection/list`.

**2. Kebijakan Tetragon berbasis kprobe, BPF LSM tidak diaktifkan.** Penegakan berbasis kprobe tidak membutuhkan LSM BPF. Mengaktifkannya berarti mengubah parameter boot kernel di setiap VM, menambah kompleksitas tanpa kebutuhan saat ini. Ditinjau ulang jika ada kebijakan yang hanya bisa lewat `lsmhooks`.

**3. Lockdown `integrity` diterima apa adanya.** Penyebab (kemungkinan Secure Boot pada firmware UEFI) belum diverifikasi. Dampaknya terhadap fitur tertentu Tetragon akan terlihat dari `tetra probe` dan pengujian di Fase 5.

**4. cgroup v2.** Tidak memerlukan konfigurasi tambahan.

**5. Kernel dikunci.** Tidak menjalankan `apt upgrade` sebelum k3s, Cilium, dan Tetragon terpasang, agar versi kernel tidak berubah di tengah jalan. Versi kernel acuan: `6.8.0-142-generic`.

## Belum diverifikasi

- Keberadaan berkas modul (`m`) di image: opsi bertanda modul perlu bisa dimuat. Diuji saat Cilium dipasang.
- Fitur runtime Tetragon (`override_return` dan sejenisnya): diuji dengan `tetra probe` saat Tetragon berjalan.
- Daftar fungsi yang bisa dioverride (`/sys/kernel/debug/error_injection/list`): butuh debugfs dan hak root, dicek di Fase 5.
- Kernel pada node agent: diasumsikan sama, diverifikasi di langkah 1.4.

## Sumber (diakses 2026-10-10)

- Tetragon FAQ (kernel version dan configuration): https://tetragon.io/docs/installation/faq/
- Tetragon Enforcement: https://tetragon.io/docs/concepts/enforcement/
- Tetragon Selectors (aksi Sigkill, Signal, Override): https://tetragon.io/docs/concepts/tracing-policy/selectors/
- Cilium System Requirements: https://docs.cilium.io/en/stable/operations/system_requirements/
