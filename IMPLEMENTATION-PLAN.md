# Rencana Implementasi Threadline

> Urutan kerja: selesaikan dan tinjau seluruh frontend dalam Mode Demo terlebih dahulu. Backend baru dimulai setelah alur frontend disetujui.

> Status implementasi yang diperiksa pada 17 Oktober 2026: `threadline/` sudah berisi aplikasi Next.js, alur Auth Supabase, store Mode Online, dan migrasi SQL. Implementasi ini belum membuktikan MVP 1–3 lulus. Rencana frontend-first tetap menjadi urutan persetujuan; belum ada catatan persetujuan frontend atau verifikasi deployment. Store Demo terpisah juga belum tampak pada kode yang ditinjau.

## Prinsip pelaksanaan

1. Bangun **MVP 1** dan **MVP 2** sebagai frontend yang bisa digunakan dalam Mode Demo, dengan data contoh dan penyimpanan lokal.
2. Semua layar memakai satu antarmuka data/workflow yang kecil. Adapter Demo membaca dan menulis data lokal; adapter Supabase untuk Mode Online baru dibuat pada MVP 3. Komponen UI tidak mengakses `localStorage` atau Supabase secara langsung.
3. Jangan menghubungkan UI ke Supabase atau R2 selama dua MVP frontend. Backend menjadi otoritas untuk izin dan aturan bisnis dalam Mode Online.
4. Setelah alur frontend disetujui, implementasikan **MVP 3**: backend Supabase self-hosted, PostgreSQL, Auth, RLS, Realtime, dan R2.
5. Pertahankan kontrak perilaku pada [PRD](PRD-Threadline.md) dan model akses pada [kontrak teknis](TECHNICAL-CONTRACT.md). Perubahan kebutuhan dicatat di dokumen sumber sebelum implementasi.
6. File pada Mode Demo menggunakan metadata contoh dan pratinjau lokal sementara. Jangan menyimpan biner file ke `localStorage` atau memperlakukan validasi browser sebagai kontrol keamanan.

## MVP 1 — Frontend alur kerja inti

### Tujuan

Memastikan Admin/Super Admin dan Freelance dapat menjalani alur satu job dari antrean sampai hasil disetujui atau diminta revisi.

### Cakupan

- Kerangka aplikasi memakai rilis stabil terbaru Next.js dengan App Router sesuai [kontrak teknis](TECHNICAL-CONTRACT.md), navigasi, layout responsif, dan komponen dasar.
- Pintu masuk Mode Demo dengan pilihan simulasi Super Admin, Finance, Admin, atau Freelance; belum ada autentikasi sungguhan.
- Data contoh untuk beberapa Freelance dan job pada berbagai status.
- Dashboard operasional Admin/Super Admin dengan antrean Belum Ditugaskan dan daftar job.
- Form pembuatan job yang mencakup semua field PRD dan penugasan ke Freelance.
- Dashboard Freelance dengan daftar job yang ditugaskan kepadanya, serta tampilan Finance untuk rekap kewajiban, transfer, dan histori finansial terbatas.
- Detail job dengan brief, deadline, penerima, status, dan riwayat aktivitas.
- Alur utama Antre → Dikerjakan → MintaACC → ACC atau Revisi → Dikerjakan.
- Pengajuan hasil memakai file contoh/mock, termasuk tampilan daftar file.
- Pembatalan job oleh Admin dengan alasan dan tampilan riwayat.
- Tanggal dan waktu deadline pada zona Asia/Jakarta sebagai asumsi kerja demo yang menunggu konfirmasi.
- Penyimpanan state demo lokal serta tombol reset yang hanya menghapus data Demo.

### Kriteria selesai

- Pengguna dapat berganti simulasi role dan melihat batas tampilan Super Admin/Finance/Admin/Freelance.
- Satu job dapat dibuat, ditugaskan, dikerjakan, diajukan untuk ACC, lalu disetujui atau dikembalikan untuk revisi.
- Job yang dibatalkan menampilkan alasan dan tetap terlihat di riwayat.
- Aksi yang tidak sesuai peran atau transisi status ditolak oleh UI.
- Perubahan demo tetap terlihat setelah halaman dimuat ulang; reset mengembalikan fixture awal.
- Pemilik produk telah meninjau alur inti sebelum cakupan frontend diperluas.

## MVP 2 — Frontend lengkap untuk ditinjau

### Tujuan

Melengkapi seluruh pengalaman pengguna yang relevan agar keputusan alur dan layar dapat ditinjau sebelum backend dibuat.

### Cakupan

- Seluruh layar dan navigasi Super Admin/Admin/Freelance untuk dashboard, antrean intake, detail, pencarian, filter, statistik, dan arsip ACC/Dibatalkan; Finance mendapat laporan pembayaran dan akun pribadi tanpa akses job operasional.
- Simulasi beberapa akun Super Admin, Finance, Admin, dan Freelance, termasuk identitas pengirim chat.
- Pengubahan nama profil sendiri; identitas job dan thread tetap mengacu pada profil simulasi yang sama.
- Pengelolaan job oleh Admin: edit field sesuai status, penugasan/pengalihan, pembatalan, penghapusan permanen hanya untuk job Belum Ditugaskan tanpa aktivitas/file, serta pengelolaan/penghapusan file yang belum terikat submission.
- Batas kemampuan Freelance: mengubah status/timeline dan mengunggah file hasil baru; tidak mengubah brief, deadline, fee, penerima, atau file yang sudah ada.
- Kapasitas Freelance, presence, SLA urgensi bersama, penanda Urgen/Terlambat, prioritas Express, serta rekomendasi pengalihan.
- Alur penugasan dan pengalihan sesuai status, termasuk alasan yang diwajibkan.
- Timeline job dan chat per Freelance; thread demo dapat dibuka sebelum job diterima.
- Pengajuan berversi, pilihan file hasil, status review ACC/Revisi, dan tampilan hasil yang dibekukan setelah ACC.
- Rekap fee dengan penerima saat ACC dan pencatatan transfer manual teralokasi ke job. Format mata uang mengikuti Rupiah bilangan bulat.
- Simulasi manajemen role/status akses khusus Super Admin, termasuk alasan audit dan perlindungan Super Admin aktif terakhir; Finance memakai akses finansial terbatas.
- Layar pendaftaran, verifikasi email, login, reset kata sandi, dan logout sebagai simulasi UI; tidak mengirim email atau membuat akun sungguhan.
- Notifikasi dalam aplikasi untuk pesan baru, job Express, dan Urgen; simulasi notifikasi browser hanya saat aplikasi terbuka dan izin diberikan. Tidak ada notifikasi latar belakang.
- Tautan WhatsApp yang menyiapkan draft dengan isi pesan; pengiriman tetap dilakukan pengguna.
- Validasi antarmuka untuk format file, batas 1 GiB per file, dan total 10 GiB untuk biner aktif serta unggahan berjalan per job; file yang dipurge tidak dihitung. Validasi ini hanya untuk demo; backend akan memeriksa ulang.
- Kondisi kosong, memuat, gagal, offline/realtime terputus, dialog konfirmasi, dan responsif pada ukuran layar utama.
- Kontrol reset Demo yang jelas memisahkan data Demo dari Mode Online yang kelak ditambahkan.

Pemetaan cakupan MVP 2: F-01/F-11/F-16 (layar akun dan pemisahan demo), F-02 (nama profil), F-03 sampai F-06 (pengelolaan job, aturan peran, dan pencarian), F-07/F-09 (thread dan realtime simulasi), F-08 (file simulasi), F-10 (dashboard/rekap), F-12 (SLA/deadline), F-13 (submission), F-14 (pembatalan/penghapusan), F-15 (riwayat). Perilaku UI ini dapat didemokan tanpa backend.

### Kriteria selesai

- Seluruh layar dan alur PRD yang dapat didemokan dapat diperagakan dengan adapter Demo dan data lokal.
- Setiap role hanya melihat data yang diizinkan dalam Mode Demo; Finance tidak mendapat file, submission, timeline umum, chat, atau pengaturan operasional.
- Pengguna dapat meninjau kondisi sukses, validasi gagal, dan kondisi tanpa data pada layar utama.
- Alur file, chat, fee, deadline, revisi, pembatalan, dan pengalihan dapat diperagakan dengan data contoh.
- Keputusan produk yang masih terbuka ditandai, bukan diasumsikan oleh UI.
- Mode Demo tidak dianggap membuktikan kriteria penerimaan Mode Online. Kriteria yang memerlukan Auth, RLS, Realtime lintas perangkat, penyimpanan R2, purge, backup, dan pemulihan baru dinilai setelah MVP 3.
- Pemilik produk menyetujui frontend sebagai acuan integrasi sebelum pekerjaan backend dimulai.

## MVP 3 — Backend dan integrasi Mode Online

### Tujuan

Menghubungkan frontend yang telah disetujui ke layanan nyata dengan kontrol akses, penyimpanan, dan operasi yang ditetapkan dokumen proyek.

### Urutan kerja

1. **Fondasi layanan dan akun**
   - Siapkan Supabase self-hosted pada VPS melalui Docker Compose, mengikuti versi bundle yang dipin dan baseline PostgreSQL 17.
   - Konfigurasikan Supabase Auth untuk pendaftaran terbuka, verifikasi email, login email/kata sandi, reset kata sandi, SMTP, redirect yang diizinkan, dan pembatasan abuse.
   - Buat profil ber-role, bootstrap Super Admin pertama melalui operator tepercaya, RPC pengelolaan role/status ber-audit, penonaktifan akses Threadline, dan offboarding akun Auth.

2. **Skema, aturan bisnis, dan akses**
   - Buat migrasi SQL untuk profil, job, event/timeline, submission, file, thread, pesan, pengaturan SLA, reservation unggahan, serta ledger pembayaran dan alokasi job.
   - Tambahkan constraint, indeks, relasi, serta operasi atomik untuk penugasan, perubahan status, submission/review, pembatalan, dan kuota unggahan.
   - Terapkan RLS sesuai empat role dan relasi job/thread; Finance memakai RPC finansial yang dipaginasi dan tidak memiliki SELECT langsung pada job.
   - Terapkan penolakan perubahan job berdasarkan revision lama dan definisi presence (`<90` detik online; `>=90` detik offline).

3. **Sambungkan UI ke Mode Online**
   - Implementasikan adapter Supabase di balik antarmuka data yang dipakai frontend demo.
   - Sambungkan sesi berbasis cookie melalui `@supabase/ssr`, pembaruan sesi melalui `proxy.ts`, dan Realtime untuk job serta chat.
   - Pertahankan Mode Demo dan Mode Online sebagai sumber data yang terpisah.

4. **File dan Cloudflare R2**
   - Hubungkan Supabase Storage privat ke bucket R2 privat sebagai backend S3-compatible.
   - Set `FILE_SIZE_LIMIT` Supabase Storage sekurang-kurangnya 1 GiB dan pastikan batas bucket tidak lebih rendah; terapkan batas produk 1 GiB per file dan 10 GiB untuk biner aktif serta reservation per job.
   - Gunakan TUS resumable untuk file di atas 6 MB dan validasi alurnya dengan backend R2 pada bundle yang dipin. Jika relevan untuk bundle itu, atur `TUS_ALLOW_S3_TAGS=false`.
   - Terapkan RLS Storage, pemeriksaan akses job, pemeriksaan jenis/ukuran server-side, dan reservation atomik; file yang dipurge tidak dihitung.
   - Pastikan submission mengunci daftar file yang diajukan dan ACC menunjuk versi yang tepat.
   - Uji unggah, unduh, hapus, file besar, kegagalan transfer, serta konsistensi metadata dan objek R2.

5. **Operasi dan kesiapan pilot**
   - Jalankan purge melalui Supabase Storage API untuk semua file saat `now >= uploaded_at + 30 hari`, termasuk file hasil ACC; proses pada eksekusi harian pertama setelah batas dan pertahankan metadata riwayat.
   - Siapkan backup PostgreSQL dan perlindungan objek R2 sebagai dua jalur terpisah: harian, retensi 7 hari, RPO maksimum 24 jam, dan RTO maksimum 8 jam. Salinan objek harus berada pada tujuan dan kredensial terpisah dari bucket produksi.
   - Tetapkan penyedia/lokasi dan prosedur pemulihan objek R2, lalu uji restore database serta objek sebagai gerbang wajib sebelum pilot.
   - Uji pemulihan database dan objek, pencabutan sesi, batas akses lintas peran, serta alur multi-perangkat.
   - Catat hasil aktual terhadap kriteria penerimaan PRD sebelum pilot.

### Kriteria selesai

- Frontend yang disetujui menggunakan akun dan data Supabase Mode Online.
- RLS menegakkan seluruh batas empat role; Finance membaca laporan dan histori lewat RPC, mencatat pembayaran terbatas, dan tidak membaca tabel job secara langsung.
- Perubahan job dan chat tersinkron antarperangkat melalui Realtime, dengan pemuatan ulang sebagai fallback.
- File privat mengalir melalui Supabase Storage dan disimpan sebagai objek di R2; batas, retensi, dan riwayat bekerja sesuai dokumen.
- Backup dan pemulihan PostgreSQL maupun R2 telah diuji dan memenuhi target pilot.
- Kriteria penerimaan PRD telah dicatat lulus/gagal berdasarkan implementasi aktual.

## Keputusan yang perlu ditutup sebelum fitur terkait dibangun

- Tentukan mata uang dan presisi pembulatan fee sebelum pemodelan final nilai uang dan rekap.
- Tentukan apakah koreksi hasil setelah ACC diperbolehkan dan bagaimana jejak serta dampaknya pada fee ditangani.
- Tentukan target waktu review MintaACC dan apakah diperlukan pengingat otomatis untuk job lama yang belum ditugaskan. Pengingat/scheduler produk belum termasuk MVP sampai diputuskan.
- Konfirmasi zona waktu bisnis deadline; Asia/Jakarta adalah asumsi kerja untuk Demo dan pilot awal.

Keputusan tersebut tidak menghalangi pembuatan layar demo, tetapi perlu diselesaikan sebelum backend atau perilaku terkait dikunci.

## Dokumen acuan

- [PRD-Threadline.md](PRD-Threadline.md) — kebutuhan produk dan kriteria penerimaan.
- [TECHNICAL-CONTRACT.md](TECHNICAL-CONTRACT.md) — arsitektur, model data, dan akses.
- [OPERATIONS.md](OPERATIONS.md) — setup dan target operasi pilot.
- [CLOUDFLARE-R2-RESEARCH.md](CLOUDFLARE-R2-RESEARCH.md) — dasar integrasi Cloudflare R2.
