# 01. Jaringan Virtual libvirt

Tanggal pengerjaan: 2026-10-10
Fase: 0 (langkah 0.3)

## Tujuan

Memahami jaringan virtual yang akan dipakai ketiga VM klaster k3s sebelum VM dibuat. Node k3s membutuhkan alamat IP yang stabil (sertifikat, konfigurasi agent, dan Cilium merujuk ke alamat itu), sehingga rentang alamat, gateway, dan cara kerja DHCP harus diketahui lebih dulu. Selain itu perlu dipastikan subnet jaringan virtual tidak bentrok dengan jaringan lain di host.

## Konfigurasi jaringan `default`

| Properti | Nilai |
|---|---|
| Nama / bridge | `default` / `virbr0` (STP aktif) |
| Mode | NAT (rentang port sumber 1024-65535) |
| Subnet | `192.168.122.0/24` |
| Gateway (sisi host) | `192.168.122.1` |
| Rentang DHCP | `192.168.122.2` sampai `192.168.122.254` (seluruh subnet) |
| Status | Active, Persistent, Autostart |

Perintah dan output:

```bash
virsh net-info default
virsh net-dumpxml default
ip -br addr show virbr0
ip route | grep virbr0
```

```text
Name:           default
UUID:           5f07fafa-db82-43a3-8d81-12b0d6eed441
Active:         yes
Persistent:     yes
Autostart:      yes
Bridge:         virbr0

<network>
  <name>default</name>
  <uuid>5f07fafa-db82-43a3-8d81-12b0d6eed441</uuid>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='virbr0' stp='on' delay='0'/>
  <mac address='52:54:00:03:b2:9e'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.2' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>

virbr0           DOWN           192.168.122.1/24
192.168.122.0/24 dev virbr0 proto kernel scope link src 192.168.122.1 linkdown
```

## Pemeriksaan bentrok subnet

```bash
ip -br addr
ip route
```

```text
lo               UNKNOWN        127.0.0.1/8 ::1/128
enp12s0          DOWN
wlp0s20f3        UP             192.168.1.92/24 fe80::6fcd:dbff:e8a7:61e3/64
virbr0           DOWN           192.168.122.1/24
docker0          DOWN           172.17.0.1/16

default via 192.168.1.1 dev wlp0s20f3 proto dhcp src 192.168.1.92 metric 600
172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1 linkdown
192.168.1.0/24 dev wlp0s20f3 proto kernel scope link src 192.168.1.92 metric 600
192.168.122.0/24 dev virbr0 proto kernel scope link src 192.168.122.1 linkdown
```

| Jaringan | Subnet | Bentrok dengan `192.168.122.0/24`? |
|---|---|---|
| WiFi (`wlp0s20f3`, rute default) | `192.168.1.0/24` | Tidak |
| Docker (`docker0`) | `172.17.0.0/16` | Tidak |
| Ethernet (`enp12s0`) | tidak terhubung | Tidak relevan |
| VPN/tunnel | tidak ada antarmuka aktif saat pengecekan | Tidak relevan saat ini |

Tidak ada subnet yang tumpang tindih. Risiko yang tersisa: jika suatu saat host tersambung ke jaringan yang kebetulan memakai `192.168.122.0/24`, rute akan bentrok. Kemungkinannya kecil dan akan diperiksa ulang bila VM kehilangan konektivitas.

## Baseline firewall (sebelum ada VM)

```bash
sudo iptables -S FORWARD | head -n 15
```

```text
-P FORWARD ACCEPT
-A FORWARD -j DOCKER-USER
-A FORWARD -j DOCKER-FORWARD
-A FORWARD -j LIBVIRT_FWX
-A FORWARD -j LIBVIRT_FWI
-A FORWARD -j LIBVIRT_FWO
```

Pengamatan: Docker dan libvirt sama-sama memasang rantai sendiri di `FORWARD`, dan kebijakan bawaan rantai `FORWARD` adalah `ACCEPT`. Dengan kebijakan `ACCEPT`, lalu lintas yang tidak cocok dengan aturan mana pun tidak dibuang, sehingga risiko Docker memblokir lalu lintas NAT libvirt tampak kecil. Ini baru gambaran statis. Ujian sebenarnya adalah apakah VM pertama bisa mengakses internet (diuji di langkah 0.5).

## Masalah dan keputusan

**1. `virbr0` berstatus DOWN padahal jaringan `active`**

Jaringan `active` berarti libvirt sudah membuat bridge dan menjalankan dnsmasq. Bridge Linux baru dianggap hidup (carrier) setelah ada minimal satu antarmuka yang tersambung ke dalamnya. Belum ada VM, sehingga tidak ada antarmuka `vnet` yang terpasang, dan rutenya bertanda `linkdown`. Status akan berubah menjadi UP saat VM pertama menyala.

**2. Mode jaringan: NAT, bukan bridge**

Keputusan: memakai NAT `default`. Alasannya: VM terisolasi dari jaringan rumah/kampus tetapi tetap punya akses internet lewat host; alamat subnet tetap sama walau host berpindah jaringan WiFi; dan akses ke klaster cukup dari host. Selain itu, host terhubung lewat WiFi, dan bridge ke antarmuka WiFi umumnya tidak didukung karena titik akses hanya menerima satu alamat MAC per klien.

**3. Rentang DHCP mencakup seluruh subnet**

Rentang DHCP `.2` sampai `.254` menutupi seluruh subnet. IP statis yang diatur di dalam VM bisa saja dibagikan dnsmasq ke VM lain. Dua pilihan penanganan, keputusan final di langkah 0.5:

- DHCP reservation di libvirt: setiap VM diberi MAC tetap, lalu jaringan memetakan MAC itu ke IP tertentu. Konfigurasi terpusat dan dapat disimpan di `infra/`.
- IP statis lewat cloud-init dengan rentang DHCP dipersempit agar tidak bentrok.

Rencana alamat sementara:

| VM | Peran | IP |
|---|---|---|
| k3s-server | control plane | `192.168.122.10` |
| k3s-agent1 | worker | `192.168.122.11` |
| k3s-agent2 | worker | `192.168.122.12` |

## Status

- [x] 0.3 Pemeriksaan jaringan virtual libvirt
- [x] Verifikasi `virbr0` berstatus UP dan VM punya akses internet (langkah 0.5)
- [x] Diagram topologi jaringan (setelah VM ada)
