# Operasi Lokal — Threadline

| Status | Nilai |
| --- | --- |
| Kesiapan lokal | Aplikasi Next.js dan migrasi Supabase tersedia di `threadline/`; konfigurasi deployment dan operasi pilot belum lengkap |
| Aturan kerja | Gunakan hanya berkas lokal proyek |
| Keputusan produk | D-01 sampai D-28 telah disepakati; lihat [PRD-Threadline.md](PRD-Threadline.md) §9 |

## 1. Target framework dan prasyarat lokal

- Frontend memakai rilis stabil terbaru Next.js dengan App Router, bukan canary. Rujukan resmi yang diperiksa pada 17 Oktober 2026 adalah lini 16.4; verifikasi dan kunci nomor patch ketika implementasi dimulai. Lihat [TECHNICAL-CONTRACT.md](TECHNICAL-CONTRACT.md).
- Runtime minimum: Node.js 20.9. Jika frontend memakai TypeScript, gunakan versi 5.1 atau lebih baru.
- Database target adalah PostgreSQL 17 dalam stack Supabase self-hosted resmi, dijalankan di VPS Linux menggunakan Docker Compose. Versi final mengikuti rilis bundle Supabase yang dipin. Supabase menangani Auth, Storage API, dan Realtime; Cloudflare R2 menjadi backend objek privat untuk Storage.
- Supabase self-hosted pada rancangan ini adalah seluruh stack Supabase (termasuk Auth, Storage, dan Realtime), bukan PostgreSQL mandiri yang hanya diakses dengan `supabase-js`. Browser tetap memakai Supabase Storage API; service Storage di VPS menyimpan objek biner ke R2.
- VPS yang direncanakan menjalankan Supabase; lokasi hosting frontend Next.js masih belum diputuskan dan tidak harus sama dengan VPS database.
- Mode Online memakai klien Supabase browser/server berbasis cookie melalui `@supabase/ssr` dan `@supabase/supabase-js` v2. Pembaruan sesi mengikuti `proxy.ts`; akses data tetap dijaga RLS.
- Jangan memasukkan data akun, job, thread, atau file privat ke cache bersama lintas pengguna. Jangan menaruh kunci `service_role` atau kredensial Cloudflare R2 pada variabel `NEXT_PUBLIC_*` atau kode browser.

Berkas implementasi aplikasi dan migrasi berada di folder `threadline/`. Berkas operasional berikut belum tersedia sebagai implementasi lokal:

- Fixture JSON untuk pengujian integrasi.
- Tugas server terjadwal untuk purge file dan proses backup/pemulihan terpisah bagi PostgreSQL dan objek R2.

Migrasi yang ada perlu ditinjau terhadap kontrak teknis sebelum dipakai pada instance baru. Deployment pilot juga memerlukan secrets, konfigurasi VPS/Supabase, bucket R2, jadwal purge, dan prosedur backup/pemulihan yang belum disiapkan di workspace.

## 2. Urutan setup deployment dan pilot

1. Tinjau migrasi SQL di `threadline/supabase/migrations/` dan pastikan sesuai dengan [TECHNICAL-CONTRACT.md](TECHNICAL-CONTRACT.md).
2. Siapkan VPS Linux untuk pilot, termasuk domain, DNS, TLS, firewall, dan penyimpanan persisten. Kebutuhan minimum stack resmi saat ini adalah 4 GB RAM, 2 CPU, dan SSD 40 GB; rekomendasi 8 GB RAM, 4 CPU, dan SSD 80 GB atau lebih.
3. Pasang Docker Engine dan Docker Compose, lalu deploy bundle Supabase self-hosted resmi dengan versi yang dipin. Jangan mengekspos stack Supabase CLI untuk development sebagai deployment production.
4. Konfigurasikan URL publik dan secrets Supabase sesuai panduan resmi, lalu pastikan seluruh layanan sehat. Aktifkan konfirmasi email, siapkan SMTP produksi untuk verifikasi dan reset kata sandi, aktifkan pembatasan abuse/rate limit Auth, serta batasi URL redirect ke domain aplikasi. Satu deployment self-hosted mewakili satu project Supabase.
5. Siapkan bucket R2 khusus yang privat sebagai backend Supabase Storage dan token dengan hak Object Read & Write terbatas pada bucket itu. Catat endpoint akun R2 dan region `auto`; jangan aktifkan akses publik. Nama bucket logis Supabase untuk aplikasi tetap `job-files`.
6. Konfigurasikan S3 backend pada service Supabase Storage sesuai panduan resmi: `STORAGE_BACKEND=s3`, bucket, endpoint R2, force path style, region, dan kredensial. Atur `FILE_SIZE_LIMIT` global sekurang-kurangnya 1 GiB dan batas bucket `job-files` minimal 1 GiB; bucket logis `finance-payment-proofs` dibatasi 10 MiB untuk PDF/JPEG/PNG/WebP. Simpan kredensial hanya di environment service Storage. Gunakan TUS untuk file di atas 6 MB dan uji pada bundle Supabase/R2 yang dipin; jika gagal terkait `x-amz-tagging`, verifikasi `TUS_ALLOW_S3_TAGS=false`.
7. Siapkan backup PostgreSQL dan perlindungan objek R2 sebagai dua jalur terpisah. Target pilot untuk keduanya: salinan harian, retensi 7 hari, RPO maksimum 24 jam, RTO maksimum 8 jam. Simpan salinan PostgreSQL di luar VPS. Salinan objek R2 harus menuju tempat penyimpanan dan memakai kredensial terpisah dari bucket produksi; penyedia/lokasi dan prosedur restore harus ditetapkan serta diuji sebelum pilot.
8. Jalankan seluruh migrasi dari berkas lokal pada database PostgreSQL instance tersebut melalui Supabase Studio SQL Editor atau migrasi terkontrol. Pastikan bucket privat `job-files` dan `finance-payment-proofs` beserta kebijakan RLS terbentuk.
9. Masukkan `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, dan `NEXT_PUBLIC_SITE_URL` ke `.env.local` lokal. Isi `SUPABASE_SERVICE_ROLE_KEY` hanya sebagai environment server Next.js untuk undangan dan tindakan akun Super Admin; jangan beri prefix `NEXT_PUBLIC_`, jangan kirim ke browser, dan jangan memakai kredensial R2 di Next.js.
10. Daftarkan akun pertama dan verifikasi emailnya.
11. Operator proyek menetapkan Super Admin pertama memakai UUID akun Auth terverifikasi, bukan nama tampilan, melalui `promote_super_admin` menggunakan `service_role` di lingkungan tepercaya. Catat role/status lama/baru, target, pelaku, waktu, dan alasan di `profile_role_events`. Setelah bootstrap, Super Admin dapat memakai TOTP secara opsional; akses aplikasi tidak mensyaratkan TOTP atau JWT `aal2`.
12. Buat akun Finance, Admin, dan Freelance untuk validasi. Pastikan Finance hanya membuka Rekap & Pembayaran dan Akun; laporan melalui RPC terbatas, tidak dapat membaca tabel job/file/submission/event/chat/profil operasional, dan dapat mencatat transfer dengan bukti serta alokasi. Admin dapat mengelola pekerjaan dan melihat rekap tetapi tidak mengelola role atau membaca audit role; Super Admin dapat mengelola akses akun serta semua operasi; Freelance tetap terbatas pada job/thread miliknya.
13. Daftarkan akun Freelance. Pastikan alamat yang belum terverifikasi belum muncul di antrean review; setelah verifikasi, Admin/Super Admin meninjau dan menyetujui akun sebelum operasi dibuka. Periksa nama dan presence pada dashboard, lalu pastikan penugasan hanya menerima freelancer aktif yang disetujui, online, berstatus siap, dan belum penuh. Freelancer hanya dapat melihat presence sendiri, tidak dapat menelusuri freelancer lain, dan dapat membuka thread sendiri sebelum menerima job. Rekening boleh dilengkapi kemudian sebelum payout pertama.
14. Jalankan kriteria penerimaan di [PRD-Threadline.md](PRD-Threadline.md) menggunakan akun uji.
15. Catat hasil aktual; kriteria belum lulus hanya karena setup berhasil.

### Operasi akun Super Admin

- Undangan Admin, Finance, dan Freelance memakai Auth Admin API dari server Next.js. `SUPABASE_SERVICE_ROLE_KEY` harus tersedia hanya di environment server; bila kosong, undangan dan tindakan akun mengembalikan status belum dikonfigurasi.
- Pengguna undangan menerima tautan verifikasi email lalu membuat kata sandi sendiri. Pendaftaran publik tetap menghasilkan role Freelance pending; email diverifikasi sebelum review Admin/Super Admin dan aktivasi operasional.
- Super Admin dapat mengirim ulang verifikasi, mengirim tautan reset kata sandi, dan mencabut seluruh sesi akun dari halaman Manajemen Pengguna. Setiap tindakan meminta alasan dan ditulis ke `admin_audit_events`.
- MFA TOTP bersifat opsional untuk semua role dan tidak menjadi syarat akses Super Admin. Untuk Supabase lokal, nilai `auth.mfa.totp.enroll_enabled` dan `verify_enabled` mengizinkan penggunaan TOTP opsional; restart stack jika konfigurasi berubah.
- Pemeriksaan backend tetap memvalidasi sesi Auth, role Super Admin, dan status akun aktif. Jangan menghapus pemeriksaan role/status saat mengubah pengaturan MFA.

## 3. Checklist pilot Mode Online

- [ ] Aplikasi memakai rilis stabil Next.js terbaru yang nomor patch-nya dicatat di lockfile, dengan Node.js 20.9 atau lebih baru.
- [ ] Stack Supabase self-hosted berjalan dari bundle Docker Compose resmi yang versinya dipin dan menghubungkan Storage ke backend S3-compatible Cloudflare R2 privat.
- [ ] Backup PostgreSQL dan perlindungan objek R2 berjalan harian, disimpan selama 7 hari, memiliki RPO maksimum 24 jam dan RTO maksimum 8 jam, dan proses pemulihan keduanya berhasil diuji.
- [ ] Salinan objek R2 memakai tujuan dan kredensial terpisah dari bucket produksi; penyedia/lokasi serta prosedur restore sudah dipilih dan diuji sebelum pilot.
- [ ] Klien Supabase browser/server menggunakan sesi cookie `@supabase/ssr`; `proxy.ts` memperbarui sesi dan RLS tetap menegakkan otorisasi.
- [ ] Data akun, job, thread, dan file privat tidak tercampur dalam cache bersama lintas pengguna.
- [ ] Schema berjalan pada instance Supabase self-hosted baru dengan versi PostgreSQL dari bundle yang dipin.
- [ ] Akun Super Admin, Finance, Admin, dan Freelance dapat login dengan role yang benar.
- [ ] Pendaftaran terbuka membuat akun ber-role Freelance; pengguna harus memverifikasi email sebelum menggunakan aplikasi.
- [ ] Login memakai email/kata sandi, reset kata sandi melalui email berhasil, dan logout mengakhiri sesi pada perangkat.
- [ ] Akun Freelance yang baru terdaftar hanya dapat membaca profilnya sendiri, thread dukungannya sendiri, dan belum memiliki akses job/file; ia tidak dapat melihat daftar profil/presence Freelance lain atau mengubah role/status akses sendiri.
- [ ] Finance tidak dapat membaca tabel job, brief/referensi, file, submission, timeline umum, chat, direktori profil, atau pengaturan umum; laporan hanya tersedia melalui RPC finansial terbatas.
- [ ] Laporan bulanan Finance menghitung semua job Finished, menampilkan saldo awal, fee bulan ini, transfer bersih termasuk pembalik pembatalan, saldo akhir, serta memakai zona waktu Asia/Jakarta; hasil tidak berhenti di 500 job.
- [ ] Transfer dapat dicatat dengan tanggal, referensi unik, bukti privat, dan alokasi satu atau beberapa job. Sistem menolak referensi duplikat dan alokasi di atas sisa fee.
- [ ] Pembatalan pencatatan memerlukan alasan dan tetap terlihat di histori; log audit mencatat transfer, pembatalan, perubahan jadwal, pembukaan rekening, dan pembukaan bukti.
- [ ] Nomor rekening disamarkan di daftar Finance; tindakan melihat nomor penuh menambahkan log pelaku/waktu/target.
- [ ] Pembukaan bukti pembayaran hanya berhasil setelah RPC mencatat event pembukaan oleh aktor yang sama; akses Storage langsung tanpa event audit ditolak.
- [ ] Sebelum tutup buku pertama, tinjau tanggal perkiraan `finished_at` untuk job lama dan catat transfer historis beserta tanggal serta bukti aslinya.
- [ ] Dua akun Admin dapat mengelola job dan membaca rekap fee sesuai kewenangannya, tetapi tidak dapat mengubah role/status akun.
- [ ] Super Admin dapat mengelola role/status akun lain dan semua operasi Admin; setiap perubahan mencatat alasan/pelaku, hanya Super Admin dapat membaca audit role/status, dan Super Admin aktif terakhir tidak dapat diturunkan atau dinonaktifkan.
- [ ] Job realtime diterima oleh freelance yang ditugaskan.
- [ ] Freelance tidak dapat membaca job atau thread orang lain.
- [ ] Freelance tidak dapat menelusuri profil/presence Freelance lain; nama pelaku pada job yang berhak dilihat tetap tampil.
- [ ] Role/status akses tidak dapat diubah oleh pemilik akun sendiri; akun nonaktif tidak dapat menggunakan data atau RPC Threadline.
- [ ] Penugasan offline/penuh ditolak sesuai keputusan produk.
- [ ] Job baru masuk Belum Ditugaskan, terlihat oleh Admin, dan tidak menggunakan kapasitas siapa pun sampai ditugaskan.
- [ ] Penugasan awal mengubah job menjadi Antre dan memulai SLA; pengalihan job Antre memulai ulang timer.
- [ ] Pengalihan job Dikerjakan/Revisi memerlukan alasan dan mempertahankan status serta riwayat; job MintaACC harus diputuskan sebelum dialihkan.
- [ ] Status ACC hanya dapat diberikan Admin setelah MintaACC.
- [ ] MintaACC menyimpan versi dan daftar tetap dengan sedikitnya satu file; ACC menyetujui versi itu, Revisi mewajibkan alasan, dan pengajuan ulang membuat versi baru. File yang telah terikat submission tidak dapat diedit/dihapus melalui alur biasa.
- [ ] Urgen dihitung dari SLA sejak antre; Terlambat dihitung dari deadline dan tidak mengubah status. Job ACC/Dibatalkan tidak ditandai Terlambat.
- [ ] Admin dapat membatalkan job nonterminal sebelum ACC dengan alasan wajib; Dibatalkan terminal, tidak masuk kapasitas/rekap fee, dan tetap memiliki riwayat.
- [ ] Penghapusan permanen hanya tersedia untuk job Belum Ditugaskan tanpa aktivitas atau file.
- [ ] ACC membekukan submission hasil, fee snapshot, dan penerima rekap saat ACC; edit biasa tidak mengubah hasil atau rekap.
- [ ] Bila job dialihkan, seluruh fee tetap diatribusikan kepada Freelance yang menerima job saat ACC.
- [ ] Event status, penugasan/pengalihan, submission/review, dan pembatalan tercatat beserta waktu dan pelaku serta tidak dapat diedit/dihapus melalui alur aplikasi biasa.
- [ ] Kebijakan RLS Supabase Storage hanya membuka file kepada pengguna terautentikasi yang berhak atas job; tugas server VPS menjalankan purge harian untuk semua file saat `now >= uploaded_at + 30 hari`, termasuk hasil ACC, dan mempertahankan catatan submission/riwayat.
- [ ] Unggah, unduh, dan hapus memakai Supabase Storage API; bucket backend R2 privat dan kredensial R2 hanya tersedia di service Storage pada VPS.
- [ ] Supabase Storage `FILE_SIZE_LIMIT` global dan batas bucket `job-files` mengizinkan setidaknya 1 GiB; unggahan menerima PDF, CDR, PNG, dan JPEG; batas produk 1 GiB per file serta total 10 GiB untuk biner aktif dan unggahan berjalan per job ditegakkan termasuk unggahan bersamaan. File yang sudah dipurge tidak dihitung.
- [ ] File di atas 6 MB memakai TUS resumable dan alur tersebut telah diuji dengan backend R2 pada versi bundle yang dipin.
- [ ] Freelance dapat mengunggah file hasil baru, tetapi tidak dapat mengubah atau menghapus file yang sudah ada.
- [ ] Nama Freelance dapat diubah tanpa memutus relasi job atau thread.
- [ ] Perubahan dari revision lama ditolak dan UI meminta pengguna memuat ulang.
- [ ] Nilai SLA urgensi yang sama terlihat di semua perangkat.
- [ ] Admin dan Super Admin dapat mengubah SLA bersama; Freelance hanya dapat membacanya dan perubahan muncul pada semua perangkat.
- [ ] Rekap fee terpisah dari pembayaran aktual; status transfer hanya berasal dari transaksi yang dicatat dengan bukti dan alokasi.
- [ ] Mode Demo hanya mengubah data lokal; mengosongkan data Demo tidak mengubah data Mode Online.
- [ ] Bootstrap Super Admin pertama hanya dilakukan operator tepercaya; perubahan role/status berikutnya lewat Super Admin dan memiliki catatan audit. Offboarding penuh menonaktifkan akun Auth serta mencabut sesi tanpa menghapus profil/riwayat.

## 4. Catatan operasi

- Heartbeat online dirancang berjalan tiap 30 detik; Freelance online bila umur heartbeat kurang dari 90 detik dan offline pada 90 detik atau lebih.
- Deadline disimpan sebagai timestamp; input dan tampilan memakai Asia/Jakarta sebagai asumsi kerja Demo/pilot sampai zona waktu bisnis dikonfirmasi. Job terlambat saat `now >= deadline`, kecuali ACC atau Dibatalkan.
- SLA urgensi Mode Online adalah satu nilai bersama untuk semua perangkat; nilai awalnya 3 jam dan Admin atau Super Admin dapat mengubahnya.
- Urgen adalah penanda durasi Antre; Terlambat adalah penanda deadline. Keduanya dihitung terpisah.
- Tugas server terjadwal pada VPS menjalankan purge setiap hari melalui Supabase Storage API. File layak dihapus saat `now >= uploaded_at + 30 hari`; proses menghapusnya pada eksekusi harian pertama setelah batas, menandai `expired_at`, dan mencatat hasil agar kegagalan dapat dicoba ulang. Gunakan kredensial berhak istimewa hanya pada proses server ini, jangan pada browser.
- Ukuran unggahan maksimum 1 GiB per file dan total 10 GiB untuk biner aktif serta unggahan berjalan pada satu job; jumlah file tidak dibatasi. Reservation harus mencegah unggahan bersamaan melampaui batas dan dilepas jika transfer gagal. File yang sudah dipurge tidak dihitung lagi.
- Backup PostgreSQL dan objek R2 adalah dua jalur berbeda. Target pilot masing-masing: harian, retensi 7 hari, RPO maksimum 24 jam, RTO maksimum 8 jam. Salinan objek memakai tujuan dan kredensial terpisah dari produksi. Catat pemilik, penyedia/lokasi, log hasil, dan bukti uji restore; keputusan serta uji restore wajib selesai sebelum pilot.
- Super Admin pertama ditetapkan operator melalui akses deployment setelah email terverifikasi; setiap perubahan role/status masuk `profile_role_events`. Super Admin mengelola akses akun lain. `is_active=false` menutup akses Threadline melalui RLS/RPC; saat offboarding penuh, nonaktifkan juga akun Auth dan cabut sesi refresh tanpa menghapus profil atau riwayat bisnis.
- ACC mengunci referensi hasil dan fee untuk rekap. Jika dibutuhkan koreksi setelah ACC, keputusan koreksi perlu aturan produk tersendiri; edit biasa tidak boleh mengubah hasil atau fee yang sudah disetujui.
- Gangguan realtime masih memungkinkan pemuatan ulang manual, tetapi perubahan harus diverifikasi kembali.
- Notifikasi pesan, Urgen, dan Express tampil di dalam aplikasi. Notifikasi browser hanya opsional saat aplikasi terbuka dan izin diberikan; tidak ada notifikasi latar belakang. Tautan WhatsApp membuka draft dan tidak mengirim pesan otomatis.
