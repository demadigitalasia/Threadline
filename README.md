# Threadline

> Ringkasan proyek dan pintu masuk ke dokumentasi lokal.

## Tentang proyek

Threadline dirancang untuk mengelola pekerjaan freelance konveksi jersey dalam satu aplikasi. Job baru masuk ke antrean Belum Ditugaskan; Admin menugaskan pekerjaan, lalu Freelance mengerjakan dan mengirim versi hasil untuk diperiksa. Admin menyetujui versi tertentu atau meminta revisi dengan alasan. Status, penanda Urgen/Terlambat, tenggat, file, diskusi, pembatalan, dan rekap fee membantu menggantikan koordinasi yang tersebar di banyak grup WhatsApp.

Produk memiliki empat peran dengan urutan akses: **Super Admin**, **Finance**, **Admin**, dan **Freelance**. Super Admin memiliki akses penuh dan mengelola role/status akses; Finance membaca kewajiban serta histori, mengatur jadwal, dan mencatat transfer melalui alur terbatas; Admin mengelola pekerjaan dan tetap dapat melihat rekap fee; Freelance mengerjakan job yang ditugaskan. Rancangan memiliki Mode Demo lokal dan Mode Online berbasis Supabase self-hosted pada VPS milik proyek.

Pendaftaran Mode Online terbuka menggunakan email dan kata sandi. Akun baru mendapat peran Freelance dan harus memverifikasi email; reset kata sandi dikirim melalui email. Operator tepercaya menetapkan Super Admin pertama; setelah itu Super Admin mengelola role dan status akses pengguna melalui aplikasi. Perubahan akses dicatat dan Super Admin aktif terakhir tidak dapat diturunkan atau dinonaktifkan.

Finance tidak memiliki akses SELECT langsung ke tabel job, file, submission, event operasional, chat, atau direktori profil. Laporan hanya mengembalikan data finansial minimum lewat RPC; nomor rekening disamarkan kecuali dibuka melalui tindakan yang dicatat. Freelance hanya dapat melihat job yang ditugaskan, thread miliknya sendiri, presence akunnya, dan nama yang diperlukan pada riwayat tersebut. Daftar profil serta presence Freelance lain hanya tersedia bagi Super Admin dan Admin untuk mengelola pekerjaan.

Target frontend adalah **rilis stabil terbaru Next.js dengan App Router**. Rujukan resmi yang diperiksa pada 17 Oktober 2026 adalah lini 16.4; verifikasi dan kunci nomor patch saat implementasi. Runtime minimum adalah Node.js 20.9; detail framework, autentikasi Supabase, dan aturan cache ada di [TECHNICAL-CONTRACT.md](TECHNICAL-CONTRACT.md).

Data terstruktur, autentikasi, realtime, dan API file menggunakan **Supabase self-hosted** dengan **PostgreSQL 17** pada VPS. **Cloudflare R2** menjadi backend objek untuk Supabase Storage; akses aplikasi tetap melalui Supabase Storage API dan kebijakan RLS. Jumlah file tidak dibatasi; ukuran maksimum adalah 1 GiB per file dan 10 GiB untuk biner aktif serta unggahan berjalan pada satu job. File yang sudah dipurge tidak lagi dihitung. File menjadi layak dipurge pada umur 30 hari dan diproses pada eksekusi harian pertama sesudahnya. Backup PostgreSQL dan perlindungan objek R2 berjalan terpisah setiap hari, dengan retensi 7 hari, RPO maksimum 24 jam, dan RTO maksimum 8 jam; salinan objek memakai tujuan serta kredensial terpisah, yang harus dipilih dan diuji sebelum pilot. Detail integrasi ada di [TECHNICAL-CONTRACT.md](TECHNICAL-CONTRACT.md) dan [OPERATIONS.md](OPERATIONS.md).
VPS ini menjadi target untuk Supabase; lokasi hosting frontend Next.js belum ditentukan dan tidak diasumsikan harus berada pada VPS yang sama.

## Dokumen lokal

- [PRD-Threadline.md](PRD-Threadline.md) — masalah, pengguna, alur produk, kebutuhan, dan kriteria penerimaan.
- [TECHNICAL-CONTRACT.md](TECHNICAL-CONTRACT.md) — model data, aturan akses, penyimpanan file, realtime, dan sinkronisasi.
- [OPERATIONS.md](OPERATIONS.md) — prasyarat dan urutan setup/pilot lokal.
- [IMPLEMENTATION-PLAN.md](IMPLEMENTATION-PLAN.md) — urutan MVP frontend terlebih dahulu, lalu backend setelah frontend ditinjau.
- [GLOSSARY.md](GLOSSARY.md) — istilah baku yang digunakan di seluruh dokumen.
- [FINANCE_ROLE_AUDIT.md](FINANCE_ROLE_AUDIT.md) — temuan audit role Finance, rekomendasi yang diterapkan, dan batas rilis.
- [CLOUDFLARE-R2-RESEARCH.md](CLOUDFLARE-R2-RESEARCH.md) — temuan integrasi R2 dari dokumentasi resmi.

## Status folder kerja

Implementasi aplikasi Next.js dan migrasi Supabase lokal berada di folder [threadline](threadline/). Konfigurasi deployment VPS, bucket Cloudflare R2, tugas purge harian, serta proses backup dan pemulihan belum tersedia sebagai konfigurasi operasional lokal; target pilot di dokumen belum dianggap siap sampai seluruh alur tersebut disiapkan dan diuji.

Dokumentasi ini tidak bergantung pada GitHub. Tinjau aplikasi dan migrasi di `threadline/` bersama dokumen kontrak sebelum menyiapkan deployment Supabase/R2 atau menyatakan kriteria teknis lulus.
