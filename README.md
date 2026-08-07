# Zet-DNS

DNS Server untuk Memfilter/`memblokir situs negatif dari daftar **Komdigi Trust Positif**, dilengkapi dashboard admin berbasis web.

Fitur utama:

- Memfilter/`memblokir` situs dari daftar Trust Positif (otomatis diperbarui tiap jam)
- Dashboard admin untuk mengelola aturan
- SafeSearch otomatis untuk mesin pencari
- Firewall yang mengamankan server

## Syarat (Sebelum Instalasi)

**OS**

- Debian 12 (bookworm) versi 64-bit (x86_64)
- Sudah terpasang `qemu-guest-agent` (aplikasi KVM/Proxmox)
- Server dijalankan sebagai **root**

**Dependensi yang harus sudah terpasang** di server:

| Paket | Fungsi |
|---|---|
| `systemd` | Menjalankan layanan otomatis |
| `openssh-server` | Akses SSH |
| `nftables` | Firewall |
| `unbound-anchor` | Keamanan DNSSEC |
| `qemu-guest-agent` | Agen mesin virtual |
| `dnsutils` | Alat tes DNS (`dig`) |
| `curl` dan `openssl` | Download & sertifikat |

Cara menginstal dependensi di Debian:

```sh
apt update
apt install -y systemd openssh-server nftables unbound-anchor \
    qemu-guest-agent dnsutils curl openssl
```

> Catatan: `blcreate`, `unbound`, dan `dnstrust-admin` sudah disertakan dalam project ini, tidak perlu diinstal manual.

## Cara Install

1. Salin folder project ini ke server (misalnya `/root/zet-dns`).
2. Masuk sebagai root lalu jalankan:

   ```sh
   cd /root/zet-dns
   ./install.sh
   ```

3. Akan diminta **password dashboard** (minimal 12 karakter). Kosongkan saja jika ingin dibuatkan password acak.
4. Tunggu sampai muncul pesan:

   ```
   DNS Trust installation completed successfully.
   Dashboard: https://<IP-server>:9080/
   ```

Instalasi selesai. Server DNS langsung aktif dan dashboard bisa dibuka.

## Cara Menggunakan

### Dashboard Admin

Buka di browser: `https://<IP-server>:9080/`

- Login dengan password yang dimasukkan saat instalasi.
- Peringatan sertifikat di browser bisa dilewati (klik **Advanced → Continue**).

### Menjadikan Server Ini DNS Komputer/HP

Atur DNS di perangkat klien menjadi IP server ini. Contoh di Android:

1. **Pengaturan → Wi‑Fi → (jaringan) → Ubah → IP statis**
2. Isi **DNS 1** dengan IP server, **DNS 2** kosong.

Semua perangkat di jaringan yang memakai DNS ini otomatis terfilter.

### Cek Apakah DNS Berjalan

Dari server:

```sh
systemctl is-active dnstrust-unbound
# hasil: active
```

### Status dan Layanan

| Perintah | Fungsi |
|---|---|
| `systemctl status dnstrust-unbound` | Status server DNS |
| `systemctl status dnstrust-admin` | Status dashboard |
| `systemctl status unbound-blacklist-update.timer` | Status pembaruan daftar blokir |

Daftar situs blokir diperbarui otomatis setiap 1 jam.

## Cara Menghapus (Uninstall)

```sh
./uninstall.sh
```

Ketik `REMOVE DNS TRUST` saat diminta konfirmasi. Semua data lama di-backup ke `/var/backups/` sebelum dihapus.

## Tes Instalasi di Docker (Opsional)

Bisa dicoba dulu tanpa server fisik:

```sh
./test/docker/test.sh
```

Script ini menyalakan server uji, menjalankan instalasi, lalu memeriksa hasilnya secara otomatis.
