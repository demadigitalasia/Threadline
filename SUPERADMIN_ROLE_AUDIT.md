# Audit Role Super Admin Threadline

**Tanggal:** 17 Oktober 2026  
**Cakupan:** role Super Admin, batas akses empat role, fitur yang tersedia, pengelolaan akun, dan kontrol terkait.  
**Metode:** tinjauan kode dan kebijakan SQL dibandingkan dengan PRD serta kontrak teknis. Audit awal bersifat statis; status penerapan dan validasi tindak lanjut dicatat di bawah.

## Status implementasi rekomendasi — 17 Oktober 2026

Rekomendasi yang disetujui sudah diterapkan pada aplikasi lokal:

- Halaman **Manajemen Pengguna** tersedia di `/pengguna`, berisi undangan Admin/Finance/Freelance, direktori akun dengan email/status verifikasi/aktivitas terakhir, pencarian dan filter, serta perubahan role/status beralasan.
- Tindakan kirim ulang verifikasi, kirim tautan reset kata sandi, dan pencabutan semua sesi tersedia di direktori. Endpoint server memeriksa sesi Auth dan status Super Admin aktif, tanpa mewajibkan TOTP; kunci `service_role` tidak dikirim ke browser.
- Riwayat audit mencakup undangan, perubahan akses, tindakan keamanan akun, dan pengaturan bersama. Perubahan SLA/kapasitas kini melewati RPC beralasan yang mencatat nilai sebelum/sesudah.
- Atas permintaan pengguna, kewajiban TOTP/AAL2 untuk Super Admin sudah dihapus dari UI, endpoint server, serta fungsi RLS/RPC. TOTP Supabase tetap tersedia secara opsional.
- Migrasi `20261017000001_super_admin_controls.sql` dan `20261017000002_super_admin_authenticator_optional.sql` telah diterapkan ke database Supabase lokal. Variabel server lokal untuk endpoint akun telah dikonfigurasi.
- `npx tsc --noEmit --incremental false` dan `npm run lint -- --no-cache` lulus setelah perubahan MFA.

Faktor TOTP yang mungkin sudah tersimpan pada akun tidak dihapus, tetapi aplikasi tidak lagi meminta atau mensyaratkannya. Validasi operasional produksi masih perlu dilakukan: kirim email nyata bergantung pada SMTP deployment; alur undangan/reset/pencabutan sesi serta matriks akses perlu dijalankan dengan akun uji sebelum pilot. Tidak ada pengujian end-to-end yang dijalankan pada implementasi ini.

## Temuan baseline sebelum implementasi

Pada saat audit awal, fondasi role Super Admin sudah cukup kuat. Backend memeriksa role aktif melalui RLS/RPC, perubahan role/status membutuhkan alasan dan dicatat, pengguna tidak dapat mengubah akses sendiri, dan Super Admin aktif terakhir dilindungi.

Kebutuhan membuat Admin, Finance, dan Freelance **belum terpenuhi sebagai pembuatan akun**. Pendaftaran publik membuat akun Freelance; Super Admin dapat menaikkan role akun yang sudah ada. Selain itu, catatan perubahan role tersedia di database, tetapi belum ditemukan tampilan audit di aplikasi. Panel pengelolaan akun juga belum cukup informatif untuk operasional harian.

**Kesimpulan:** pertahankan kewenangan operasional Super Admin dan batas role yang ada. Prioritaskan undangan akun, halaman audit yang bisa dibaca, serta identifikasi akun yang lebih jelas. Tidak ada fitur inti Super Admin yang perlu dihapus berdasarkan audit ini.

## Fitur Super Admin pada baseline audit

| Area | Yang tersedia | Catatan |
| --- | --- | --- |
| Operasional | Seluruh kemampuan Admin: melihat dan mengelola job, penugasan/pengalihan, review ACC/revisi, pembatalan, file, chat, arsip, dan rekap fee. | Sesuai matriks akses produk. Penghapusan permanen dibatasi pada job Belum Ditugaskan yang belum memiliki aktivitas atau file. |
| Akun | Melihat daftar profil; mengubah role dan status aktif akun lain. Role yang dapat dipilih mencakup Super Admin, Finance, Admin, dan Freelance. | Perubahan wajib disertai alasan. Tidak ada kontrol untuk mengubah role/status diri sendiri. |
| Pengaturan bersama | Mengubah SLA urgensi dan batas job aktif untuk semua perangkat. | Admin juga memiliki hak ini. Nilai batas job diperiksa di backend. |
| Profil sendiri | Mengubah nama kerja, melihat sesi/perangkat ini dan aktivitas sendiri, keluar, serta membuka alur ganti/reset kata sandi. | Bukan alat untuk mereset akun pengguna lain. |
| Audit role | Database menyimpan target, role/status lama dan baru, pelaku, waktu, serta alasan; hanya Super Admin aktif dapat membaca tabel audit menurut RLS. | Belum ditemukan halaman atau kueri UI untuk menampilkan tabel tersebut. |

Navigasi Super Admin memuat Dashboard, Antrean Intake, Arsip & Batal, Chat, Rekap Fee, Akun, dan Pengaturan. Pengelolaan role/status berada di bagian bawah halaman Akun, bukan pada menu pengguna tersendiri.

## Temuan audit

### 1. Pembuatan akun Admin, Finance, atau Freelance belum tersedia — prioritas tinggi

Halaman pendaftaran publik membuat akun lewat Supabase Auth dengan data nama dan email; alur produk menetapkan role awal sebagai Freelance. Tidak ditemukan form undangan atau aksi pembuatan akun di panel Super Admin. Saat ini, Super Admin perlu meminta orang tersebut mendaftar sebagai Freelance terlebih dahulu, lalu mengubah rolenya.

Ini belum memenuhi kebutuhan “Create Admin”, “Create Finance”, dan “Create Freelance” sebagai proses yang dikendalikan Super Admin. Pendaftaran Freelance terbuka tetap berguna, tetapi akun staf sebaiknya dapat diundang secara terkontrol.

### 2. Audit perubahan role belum dapat ditinjau di aplikasi — prioritas tinggi

RPC `manage_profile_access` menyimpan perubahan role/status secara atomik ke `profile_role_events`; RLS membatasi pembacaan tabel itu kepada Super Admin. Namun, kode antarmuka hanya memuat profil dan aktivitas job. Tidak ditemukan kueri `profile_role_events` atau panel riwayatnya.

Akibatnya, informasi audit yang diwajibkan spesifikasi tidak dapat diperiksa Super Admin dari aplikasi. Audit hanya bisa dibaca lewat akses database.

### 3. Identitas akun pada daftar pengelolaan kurang lengkap — prioritas tinggi

Baris akun menampilkan nama dan UUID, lalu kontrol role/status. Email login, status verifikasi, waktu terakhir aktif, serta pencarian/filter tidak ditampilkan. Ini menyulitkan Super Admin memilih akun dengan benar dan mengelola banyak pengguna.

### 4. Pengaturan bersama belum terlihat memiliki riwayat perubahan — prioritas menengah

SLA dan batas kapasitas disimpan langsung ke `app_settings` melalui update tabel. Pada jalur UI/SQL yang ditinjau, tidak ditemukan pencatatan nilai sebelum/sesudah, pelaku, waktu, dan alasan untuk perubahan tersebut. Pengaturan ini berlaku global dan dapat diubah Admin maupun Super Admin; perubahan historis akan membantu penelusuran kesalahan operasional.

### 5. Kontrol keamanan akun terpusat belum tersedia — prioritas menengah

Super Admin dapat menonaktifkan akun, tetapi panel yang ditinjau belum menyediakan pengiriman ulang verifikasi email, pengiriman tautan reset kata sandi untuk pengguna lain, atau pencabutan semua sesi akun. Perubahan kata sandi saat ini diarahkan ke alur milik pengguna sendiri.

## Rekomendasi

### Prioritas 1 — lengkapi pengelolaan akun

1. Tambahkan **Undang akun** dengan input nama, email, dan role awal: Admin, Finance, atau Freelance. Kirim undangan/verifikasi ke email; jangan meminta atau menampilkan kata sandi sementara.
2. Jalankan pembuatan undangan melalui server tepercaya. Kunci `service_role` tidak boleh berada di browser. Batasi endpoint ke Super Admin aktif dan catat pengundang, target, role, waktu, serta hasil undangan.
3. Pertahankan pendaftaran publik dengan role awal Freelance. Super Admin tetap dapat mengubah role akun setelah akun terverifikasi.
4. Tambahkan halaman atau bagian **Manajemen Pengguna** dengan kolom nama, email login, role, akses aktif/nonaktif, verifikasi email, dan terakhir aktif; lengkapi pencarian serta filter role/status.
5. Tambahkan **Riwayat akses** yang menampilkan target, nilai lama/baru, pelaku, waktu, dan alasan. Sediakan filter berdasarkan pengguna, role, status, pelaku, dan rentang waktu.

### Prioritas 2 — lengkapi kontrol dan audit operasional

1. Tambahkan tindakan kirim ulang verifikasi dan kirim tautan reset kata sandi; tindakan harus melalui server dan menghasilkan catatan audit.
2. Tambahkan pencabutan sesi semua perangkat untuk penanganan akun yang disalahgunakan atau staf yang keluar.
3. Catat perubahan SLA dan batas job aktif dengan nilai sebelum/sesudah, pelaku, waktu, dan alasan.
4. TOTP saat ini opsional sesuai keputusan pengguna; pemeriksaan sesi Auth, role Super Admin, dan status aktif tetap wajib. Jika kebijakan MFA diubah di masa depan, sinkronkan UI, endpoint server, dan fungsi RLS/RPC.
5. Gunakan penonaktifan untuk offboarding agar job, percakapan, dan riwayat tetap utuh. Jangan menambahkan penghapusan permanen akun sebagai tindakan rutin.

### Yang sebaiknya dipertahankan

- Semua kewenangan operasional Admin untuk Super Admin, karena Super Admin perlu menjaga pekerjaan dan menyelesaikan kendala sistem.
- Role awal pendaftaran publik sebagai Freelance.
- Larangan mengubah role/status sendiri dan perlindungan Super Admin aktif terakhir.
- Alasan wajib dan audit pada perubahan role/status.
- Batas Finance pada data finansial saja; catatan pembayaran dan jadwal ber-audit, tanpa akses job langsung, chat, file pekerjaan, presence, atau pengaturan umum.

### Fitur yang tidak perlu ditambahkan sekarang

- Penghapusan permanen akun pengguna. Nonaktifkan akun dan simpan riwayat bisnis/audit.
- Kontrol operasional Admin tambahan yang menduplikasi fitur job, chat, atau rekap yang sudah tersedia.
- Akses Finance ke data profil lengkap atau akses baca langsung ke tabel job.

## Batas role yang direkomendasikan

| Role | Kewenangan |
| --- | --- |
| Super Admin | Semua fitur operasional Admin; undang dan kelola akun; mengubah role/status akun lain; melihat audit akun dan perubahan pengaturan; mengatur kebijakan bersama. |
| Admin | Mengelola job, file dan review sesuai aturan; mengatur SLA/kapasitas; membaca rekap fee; tidak mengelola akun/role dan tidak membaca audit role. |
| Finance | Melihat laporan kewajiban/transfer dan histori; mengatur jadwal serta mencatat/membatalkan pembayaran dengan alasan, bukti, dan audit; tidak membaca tabel job langsung atau mengakses file pekerjaan/chat/presence/pengaturan umum. |
| Freelance | Mengakses job yang ditugaskan, mengirim hasil/revisi, dan menggunakan thread miliknya; tidak melihat akun atau pekerjaan pengguna lain. |

## Rujukan implementasi dan spesifikasi

- [PRD-Threadline.md](PRD-Threadline.md): aturan akun dan role (§4, R-16), pendaftaran (§7, F-01/F-02), daftar dan pengelolaan akun (F-17), serta AC-30 dan AC-38–39.
- [TECHNICAL-CONTRACT.md](TECHNICAL-CONTRACT.md): matriks akses tabel dan operasi (§3).
- [OPERATIONS.md](OPERATIONS.md): bootstrap Super Admin dengan operator tepercaya dan larangan memakai `service_role` di browser.
- [threadline/src/app/register/page.tsx](threadline/src/app/register/page.tsx): pendaftaran publik.
- [threadline/src/components/super-admin-users.tsx](threadline/src/components/super-admin-users.tsx): direktori, undangan, tindakan akun, dan audit.
- [threadline/src/app/api/super-admin/invitations/route.ts](threadline/src/app/api/super-admin/invitations/route.ts) dan [threadline/src/app/api/super-admin/accounts/[profileId]/actions/route.ts](threadline/src/app/api/super-admin/accounts/[profileId]/actions/route.ts): endpoint server untuk undangan dan tindakan akun.
- [threadline/src/components/account.tsx](threadline/src/components/account.tsx): manajemen akun, profil, dan pengaturan.
- [threadline/src/components/app-shell.tsx](threadline/src/components/app-shell.tsx): navigasi berdasarkan role.
- [threadline/src/lib/store-context.tsx](threadline/src/lib/store-context.tsx): pemanggilan RPC pengelolaan akses dan update pengaturan.
- [threadline/supabase/migrations/20261017000000_role_hierarchy.sql](threadline/supabase/migrations/20261017000000_role_hierarchy.sql): kebijakan RLS, `manage_profile_access`, perlindungan Super Admin aktif terakhir, dan bootstrap operator.
- [threadline/supabase/migrations/20261017000001_super_admin_controls.sql](threadline/supabase/migrations/20261017000001_super_admin_controls.sql): AAL2, direktori akun, audit terpadu, dan pengaturan bersama ber-audit.
- [threadline/supabase/migrations/20261017000002_super_admin_authenticator_optional.sql](threadline/supabase/migrations/20261017000002_super_admin_authenticator_optional.sql): menghapus syarat AAL2 untuk fungsi Super Admin.

