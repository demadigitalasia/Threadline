# Riset Cloudflare R2 untuk Threadline

> Riset dokumentasi resmi, diperiksa pada 17 Oktober 2026. Integrasi R2 yang diadopsi tercatat pada PRD D-11; aturan workflow file, submission, ACC, dan retensi ada pada PRD D-14/D-17 serta TECHNICAL-CONTRACT.md. Berkas ini menyimpan dasar teknis dan sumber primer.

## Ringkasan

Cloudflare R2 dapat menjadi penyimpanan biner file job, sementara PostgreSQL 17 tetap menyimpan metadata dan relasi job pada Supabase self-hosted di VPS, mengikuti target di [kontrak teknis](TECHNICAL-CONTRACT.md). Frontend Threadline memakai rilis stabil terbaru Next.js dengan App Router sebagaimana ditetapkan di kontrak tersebut. Untuk rancangan Threadline yang sekarang, pendekatan yang paling sedikit mengubah kontrak adalah tetap memakai **Supabase Storage API** sebagai pintu aplikasi dan mengatur **R2 sebagai S3 backend** untuk Supabase Storage. Supabase mendokumentasikan konfigurasi ini secara eksplisit, termasuk endpoint R2. [Panduan S3 backend Supabase self-hosted](https://supabase.com/docs/guides/self-hosting/self-hosted-s3)

Dengan pola tersebut, data objek berada di R2, sedangkan metadata Storage tetap dikelola Supabase. Aplikasi masih dapat menerapkan kebijakan akses berbasis sesi dan RLS melalui Supabase Storage. Ini cocok dengan keputusan Threadline bahwa file privat hanya dapat diakses Admin/Super Admin atau Freelance yang berhak atas job. [Kontrol akses Storage Supabase](https://supabase.com/docs/guides/storage/security/access-control) · [Skema metadata Storage Supabase](https://supabase.com/docs/guides/storage/schema/design)

Alternatif yang tidak dipilih untuk MVP adalah Next.js mengakses R2 langsung memakai S3 API dan URL bertanda tangan. Pola ini mendukung transfer langsung dari browser, tetapi R2 tidak mengetahui sesi Supabase atau aturan RLS Threadline. Route server harus memeriksa akun, peran, dan akses ke job sebelum menerbitkan URL. [Presigned URL R2](https://developers.cloudflare.com/r2/api/s3/presigned-urls/) · [Route Handlers Next.js](https://nextjs.org/docs/app/api-reference/file-conventions/route)

## Konteks Threadline

Dokumen saat ini menetapkan bucket logis Supabase Storage privat `job-files`; metadata referensi file berada pada entitas `job_files`, sedangkan Supabase mengelola metadata objek. Snapshot hasil pada `job_submissions` mengikat versi ACC ke daftar file tertentu. Nama bucket fisik R2 ditetapkan terpisah sebagai backend `GLOBAL_S3_BUCKET`. Admin dan Super Admin dapat mengelola file yang belum terikat submission; Freelance dapat membaca file job yang ditugaskan dan mengunggah file hasil baru. File yang terikat submission terkunci terhadap perubahan/penghapusan biasa. Retensi 30 hari berlaku untuk semua file termasuk hasil ACC; file layak dihapus saat `now >= uploaded_at + 30 hari` dan tugas server VPS memprosesnya pada eksekusi harian berikutnya lewat Supabase Storage API, sambil mempertahankan metadata riwayat. Format unggahan adalah PDF, CDR, PNG, dan JPEG, jumlah file tidak dibatasi, ukuran maksimum 1 GiB per file dan 10 GiB untuk biner aktif serta unggahan berjalan per job; file yang dipurge tidak dihitung lagi. Konfigurasi Supabase Storage harus mengizinkan sedikitnya 1 GiB per objek. Rujukan internal: [PRD](PRD-Threadline.md) dan [kontrak teknis](TECHNICAL-CONTRACT.md).

## Pilihan integrasi

| Pola | Cara kerja | Dampak pada Threadline |
| --- | --- | --- |
| **R2 sebagai backend Supabase Storage — rekomendasi** | Aplikasi memakai Supabase SDK/API dan sesi Auth yang ada. Layanan Storage pada VPS menyimpan biner ke bucket R2 melalui S3 API; metadata Storage tetap berada di PostgreSQL. | Mempertahankan pintu API dan model RLS Storage yang sudah ada di kontrak. Tidak mengekspos kredensial R2 ke browser. |
| **Akses langsung dari aplikasi ke R2** | Next.js memeriksa sesi dan akses job, lalu membuat URL presigned R2 untuk `PUT`, `GET`, atau `DELETE`. Browser mentransfer file langsung ke R2. | Memindahkan sebagian otorisasi dari kebijakan Storage Supabase ke Route Handler Next.js. Perlu CORS R2 dan proses tambahan untuk menjaga objek R2 serta metadata PostgreSQL tetap selaras. |

Supabase menjelaskan bahwa S3 backend dan endpoint protokol S3 adalah dua fitur terpisah. Untuk Threadline, mengatur backend S3 tidak berarti aplikasi harus berpindah ke endpoint S3; Supabase REST API dan SDK tetap dapat digunakan. Konfigurasi backend pada layanan `storage` mencakup `STORAGE_BACKEND=s3`, `GLOBAL_S3_BUCKET`, `GLOBAL_S3_ENDPOINT`, `GLOBAL_S3_FORCE_PATH_STYLE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, dan `REGION`. Panduan Supabase memberi contoh endpoint R2 dan `GLOBAL_S3_FORCE_PATH_STYLE: 'true'`. [Panduan Supabase: konfigurasi S3 backend dan R2](https://supabase.com/docs/guides/self-hosting/self-hosted-s3)

**Rekomendasi arsitektur:** tempatkan file biner di Cloudflare R2 melalui S3 backend Supabase Storage; pertahankan PostgreSQL di VPS untuk job, metadata file, dan otorisasi. Gunakan Supabase Storage API/SDK untuk operasi file dalam aplikasi. Rekomendasi ini adalah sintesis dari kontrak Threadline dan dukungan konfigurasi resmi Supabase.

## Akses, privasi, dan keamanan

- **Bucket harus privat.** Bucket R2 baru tidak publik secara default; akses publik memerlukan tindakan eksplisit. Jangan aktifkan `r2.dev` atau custom domain publik untuk `job-files`, sebab R2 public bucket membuat objek dapat diakses melalui Internet. [Membuat bucket R2](https://developers.cloudflare.com/r2/buckets/create-buckets/) · [Public buckets R2](https://developers.cloudflare.com/r2/buckets/public-buckets/)
- **RLS Supabase tetap otoritatif bila aplikasi memakai Supabase Storage.** Supabase Storage menegakkan kebijakan RLS pada `storage.objects`; tanpa kebijakan yang sesuai, akses dibatasi. Kebijakan Threadline harus tetap membatasi baca berdasarkan hak atas job, memberi Freelance hak unggah baru untuk job miliknya, dan membatasi edit/hapus ke Admin serta Super Admin hanya untuk file yang belum terikat submission. Jangan gunakan URL publik untuk file job. [Kontrol akses Storage Supabase](https://supabase.com/docs/guides/storage/security/access-control)
- **Batasi kredensial R2 ke bucket dan izin yang diperlukan.** Token R2 dapat diberi izin Object Read dan Write, lalu dibatasi pada bucket tertentu. Simpan Access Key ID dan Secret Access Key hanya di secret environment layanan Supabase Storage pada VPS. Jangan menaruhnya di `NEXT_PUBLIC_*`, Client Component, source code, log, atau respons API. [Token dan scope izin R2](https://developers.cloudflare.com/r2/api/tokens/) · [Variabel environment Next.js](https://nextjs.org/docs/app/guides/environment-variables)
- **Jika memakai R2 langsung dari Next.js:** Route Handler harus mendapatkan pengguna dari sesi Supabase yang tervalidasi, membaca relasi job dari database, lalu memeriksa role serta izin operasi sebelum menandatangani URL. Jangan menerima object key bebas dari klien; bentuk key dari ID job dan ID file yang tervalidasi. R2 tidak menerapkan aturan job Threadline dengan sendirinya. Ini rekomendasi desain berdasarkan cara kerja URL presigned dan Route Handler. [Route Handlers Next.js](https://nextjs.org/docs/app/api-reference/file-conventions/route)
- **Presigned URL adalah bearer token.** Siapa pun yang memegang URL dapat menjalankan operasi yang tertulis di dalamnya sampai kedaluwarsa. Gunakan masa berlaku sesingkat yang praktis, operasi dan satu key spesifik, dan jangan menyimpan URL tersebut sebagai metadata permanen. Presigned URL mendukung `GET`, `HEAD`, `PUT`, dan `DELETE`; HTML form `POST` multipart tidak didukung. [Dokumentasi presigned URL R2](https://developers.cloudflare.com/r2/api/s3/presigned-urls/)
- **CORS bukan pengganti autentikasi.** Jika browser mengirim file langsung ke URL presigned lintas origin, bucket tetap perlu CORS. Batasi `AllowedOrigins` ke domain aplikasi dan `AllowedMethods`/`AllowedHeaders` ke kebutuhan seperti `PUT`, `GET`, `Content-Type`; unggahan dari browser gagal melewati pemeriksaan CORS jika kebijakan tidak cocok. CORS tidak menentukan apakah pengguna berhak atas job. [Konfigurasi CORS R2](https://developers.cloudflare.com/r2/buckets/cors/)
- **Validasi jenis dan ukuran tetap tanggung jawab aplikasi.** Tanda tangan URL dapat mengikat `Content-Type`, tetapi nilai MIME dari klien tidak membuktikan isi file. Cocokkan ekstensi dan jenis konten dengan PDF, CDR, PNG, atau JPEG, gunakan nama/path objek yang dibuat server, dan verifikasi unggahan sebelum mencatat metadata. Batas Threadline adalah 1 GiB per file dan 10 GiB untuk biner aktif serta transfer yang sedang berlangsung per job; file terhapus melalui purge tidak dihitung lagi. R2 membatasi satu request atau bagian multipart hingga 4.995 GiB; ukuran maksimum objek/multipart adalah 4.995 TiB dengan maksimum 10.000 bagian. [Presigned URL R2](https://developers.cloudflare.com/r2/api/s3/presigned-urls/) · [Batas R2](https://developers.cloudflare.com/r2/platform/limits/)

- **Batas Supabase Storage perlu dikonfigurasi.** `FILE_SIZE_LIMIT` global dan batas bucket `job-files` harus sekurang-kurangnya 1 GiB agar batas produk 1 GiB per file dapat dicapai; batas agregat 10 GiB per job tetap ditegakkan oleh logika Threadline dan reservation atomik. [Konfigurasi Storage self-hosted](https://supabase.com/docs/guides/self-hosting/storage/config)

- **Pilih unggahan resumable untuk file besar.** Supabase merekomendasikan TUS resumable untuk file di atas 6 MB. Karena Threadline memakai R2 sebagai backend S3, uji alur itu terhadap versi bundle yang dipin; jika error `x-amz-tagging` terjadi, verifikasi `TUS_ALLOW_S3_TAGS=false`. [Jenis unggahan Supabase](https://supabase.com/docs/guides/storage/uploads/standard-uploads) · [Troubleshooting R2 pada Supabase Storage](https://supabase.com/docs/guides/self-hosting/self-hosted-s3)

## Unggah dan unduh

### Rekomendasi: melalui Supabase Storage

1. Klien terautentikasi meminta operasi melalui SDK/API Supabase Storage.
2. Kebijakan Storage memeriksa sesi dan RLS untuk bucket/path sesuai relasi profil dengan job.
3. Layanan Supabase Storage di VPS meneruskan operasi objek ke R2 melalui S3 backend.
4. Metadata objek dicatat/dikelola oleh Supabase Storage di PostgreSQL; Threadline menyimpan metadata bisnis file pada `job_files` dan relasi hasil yang diajukan pada `job_submissions`/`job_submission_files`.
5. File tetap privat; pembacaan menggunakan jalur terautentikasi atau URL bertanda tangan yang diterbitkan Storage saat diperlukan.

Alur ini mempertahankan Supabase sebagai antarmuka file aplikasi sekaligus memakai R2 sebagai lokasi biner. Supabase mendokumentasikan bahwa metadata Storage disimpan di PostgreSQL dan objek biner disimpan di penyedia storage. [Skema Storage Supabase](https://supabase.com/docs/guides/storage/schema/design)

### Alternatif yang tidak dipilih untuk MVP: transfer langsung ke R2

1. Route Handler Next.js memvalidasi sesi, hak job, jenis operasi, format file, dan key.
2. Route Handler menerbitkan presigned `PUT` atau `GET` untuk satu key dengan expiry pendek dan `Content-Type` yang dibatasi saat presigning.
3. Browser melakukan transfer langsung ke R2; R2 CORS hanya mengizinkan origin aplikasi dan header/metode yang diperlukan.
4. Setelah `PUT` sukses, aplikasi memverifikasi metadata objek melalui server sebelum menyimpan metadata file di PostgreSQL.
5. Unduh selalu dimulai dengan pemeriksaan hak job baru dan URL `GET` hanya berlaku sementara.

R2 menunjukkan contoh browser upload langsung melalui URL `PUT`; kredensial S3 tetap berada di server yang membuat URL. [Panduan unggah R2](https://developers.cloudflare.com/r2/objects/upload-objects/) · [Presigned URL R2](https://developers.cloudflare.com/r2/api/s3/presigned-urls/)

## Penghapusan dan retensi 30 hari

- Jalankan penghapusan melalui Supabase Storage API agar operasi mengikuti mekanisme Storage dan metadata. Setelah objek berhasil dihapus, tandai `job_files.expired_at`; pertahankan metadata bisnis file, relasi `job_submission_files`, submission, dan keputusan ACC agar riwayat hasil yang disetujui tetap tercatat.
- Hindari menghapus baris `storage.objects` langsung melalui SQL. Supabase memperingatkan metadata dan objek biner terpisah: menghapus metadata saja tidak menghapus objek pada provider dan objek masih dapat menimbulkan biaya. Operasi file, termasuk delete, harus melalui API Storage. [Skema Storage Supabase](https://supabase.com/docs/guides/storage/schema/design)
- R2 mendukung lifecycle yang menghapus objek berdasarkan umur/prefix, tetapi penghapusan biasanya terjadi dalam 24 jam dari waktu kedaluwarsa dan objek lama dapat memerlukan waktu lebih lama. Lifecycle R2 berjalan terpisah dari metadata Storage dan metadata job Threadline; jika dipakai untuk file job, siapkan rekonsiliasi metadata/objek. Karena itu lifecycle R2 bukan cara untuk menjamin penghapusan tepat pada hari ke-30. [Lifecycle R2](https://developers.cloudflare.com/r2/buckets/object-lifecycles/)
- R2 secara default memiliki lifecycle untuk menghapus unggahan multipart yang tidak selesai tujuh hari setelah dimulai. Ini membantu membersihkan unggahan terbengkalai. [Lifecycle R2](https://developers.cloudflare.com/r2/buckets/object-lifecycles/)
- Untuk memenuhi R-08, file layak dipurge saat `now >= uploaded_at + 30 hari`; tugas server terjadwal di VPS memprosesnya pada eksekusi harian pertama setelah ambang tersebut melalui Supabase Storage API. Aturan berlaku juga untuk hasil ACC. Setelah objek terhapus, proses menandai `job_files.expired_at`; kegagalan dicatat dan dicoba ulang. Jangan mengaktifkan lifecycle R2 30 hari karena penghapusan berjalan terpisah dari metadata Supabase dan membutuhkan rekonsiliasi.

## Penempatan layanan

- VPS Linux tetap menjalankan PostgreSQL dan stack Supabase self-hosted. Konfigurasi S3 backend berada di service Storage dalam deployment Supabase; koneksi keluar dari VPS ke endpoint S3 R2 menggunakan HTTPS.
- Frontend Next.js dapat tetap berada di host terpisah sebagaimana keputusan di dokumen yang ada. Dengan pola Supabase Storage, browser berkomunikasi dengan URL publik Supabase; R2 API key hanya dibutuhkan service Storage di VPS.
- Gunakan endpoint akun `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`, nama bucket R2 yang privat, kredensial scoped untuk bucket, dan konfigurasi S3 compatible yang diuji pada versi bundle Supabase yang dipin. [Konfigurasi R2 Supabase](https://supabase.com/docs/guides/self-hosting/self-hosted-s3) · [Endpoint dan token R2](https://developers.cloudflare.com/r2/api/tokens/)
- Backup PostgreSQL dan perlindungan objek R2 adalah dua jalur pemulihan yang berbeda. Target pilot yang disepakati adalah salinan harian, retensi 7 hari, RPO maksimum 24 jam, dan RTO maksimum 8 jam untuk keduanya. Salinan objek wajib berada pada tujuan dan memakai kredensial terpisah dari bucket produksi. Penyedia/lokasi serta prosedur restore masih perlu dipilih dan diuji sebelum pilot; backup database tidak menyalin objek R2.

## Catatan kompatibilitas

- Supabase mendokumentasikan R2 sebagai contoh penyedia S3-compatible untuk S3 backend self-hosted. Namun tidak semua fitur S3 tersedia di R2; periksa daftar kompatibilitas untuk fitur yang digunakan. [Kompatibilitas S3 R2](https://developers.cloudflare.com/r2/api/s3/api/)
- Untuk unggahan resumable TUS dengan backend R2, Supabase menyebut R2 tidak mengimplementasikan fitur S3 `x-amz-tagging`. Jika terjadi HTTP 500 terkait fitur tersebut, dokumentasi meminta `TUS_ALLOW_S3_TAGS: "false"` pada environment layanan Storage. Verifikasi kebutuhan ini terhadap versi Supabase yang dipin sebelum deployment. [Troubleshooting R2 pada Supabase Storage](https://supabase.com/docs/guides/self-hosting/self-hosted-s3)
- R2 presigned URL harus memakai domain S3 API akun dan tidak dapat dipakai melalui custom domain. File Threadline privat tidak perlu memakai custom domain publik. [Presigned URL R2](https://developers.cloudflare.com/r2/api/s3/presigned-urls/)

## Keputusan yang diadopsi

1. Cloudflare R2 adalah backend objek biner dan Supabase Storage tetap menjadi API aplikasi serta pengelola metadata/RLS.
2. Unggah, unduh, dan hapus file Threadline melewati Supabase Storage API; browser tidak mengakses bucket R2 secara langsung.
3. Entitas `job_files` menyimpan object path/referensi, bukan URL permanen. `job_submissions` mengikat ACC pada file tertentu; URL privat dibuat oleh Supabase Storage saat diperlukan.
4. Kredensial R2 disimpan pada service Storage di VPS; backup PostgreSQL dan pemulihan objek R2 dikelola sebagai dua jalur berbeda.
5. Format PDF, CDR, PNG, dan JPEG tetap dipakai; jumlah file tidak dibatasi, ukuran maksimum 1 GiB per file dan 10 GiB untuk biner aktif serta unggahan berjalan per job. File yang dipurge tidak dihitung lagi. Batas Supabase Storage diatur minimal 1 GiB dan anggaran ukuran diuji pada unggahan tunggal maupun bersamaan.
6. File di atas 6 MB menggunakan TUS resumable setelah kompatibilitasnya dengan bundle Supabase/R2 teruji.

## Sumber primer

Semua rujukan di bawah berasal dari dokumentasi resmi penyedia atau Next.js.

| Topik | Sumber |
| --- | --- |
| S3 backend Supabase self-hosted, endpoint R2, TUS | [Supabase: Configure S3 Storage](https://supabase.com/docs/guides/self-hosting/self-hosted-s3) |
| Batas unggah Storage self-hosted | [Supabase: Storage configuration](https://supabase.com/docs/guides/self-hosting/storage/config) |
| Rekomendasi unggah resumable untuk file besar | [Supabase: Standard and resumable uploads](https://supabase.com/docs/guides/storage/uploads/standard-uploads) |
| RLS untuk objek Storage | [Supabase: Storage Access Control](https://supabase.com/docs/guides/storage/security/access-control) |
| Metadata database dan objek file provider | [Supabase: Storage Schema](https://supabase.com/docs/guides/storage/schema/design) |
| Privasi dan presigned URL R2 | [Cloudflare: Presigned URLs](https://developers.cloudflare.com/r2/api/s3/presigned-urls/) |
| Kredensial dan scope R2 | [Cloudflare: Authentication](https://developers.cloudflare.com/r2/api/tokens/) |
| Unggah browser tanpa kredensial pada klien | [Cloudflare: Upload objects](https://developers.cloudflare.com/r2/objects/upload-objects/) |
| CORS browser | [Cloudflare: Configure CORS](https://developers.cloudflare.com/r2/buckets/cors/) |
| Lifecycle dan penghapusan tertunda | [Cloudflare: Object lifecycles](https://developers.cloudflare.com/r2/buckets/object-lifecycles/) |
| Batas unggah dan objek | [Cloudflare: Limits](https://developers.cloudflare.com/r2/platform/limits/) |
| Kompatibilitas S3 | [Cloudflare: S3 API compatibility](https://developers.cloudflare.com/r2/api/s3/api/) |
| Secret environment Next.js | [Next.js: Environment variables](https://nextjs.org/docs/app/guides/environment-variables) |
| Server endpoint di App Router | [Next.js: Route Handlers](https://nextjs.org/docs/app/api-reference/file-conventions/route) |
