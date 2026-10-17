# Audit Role Finance — Threadline

**Tanggal audit:** 17 Oktober 2026  
**Status:** Audit statis terhadap kode aplikasi, migrasi Supabase, dan dokumen produk. Database produksi dan data transaksi nyata tidak diperiksa.

## Ringkasan

**Kesimpulan:** role Finance saat ini dapat melihat rekap fee job yang sudah `Finished`, melihat rekening bank freelancer yang disetujui, dan mengubah jadwal pembayaran. Namun, aplikasi belum mencatat transaksi pembayaran yang benar-benar dilakukan dan belum menyediakan rekap bulanan. Jadi, fungsi yang ada belum cukup untuk merekonsiliasi “berapa hak fee, berapa yang sudah ditransfer, dan berapa yang masih belum dibayar”.

Saya menafsirkan “eruser” sebagai freelancer/penerima fee, mengikuti istilah dan modul yang ada di proyek.

**Risiko utama:** nilai fee bisa terlihat seperti total pembayaran walaupun belum dibayar; hasil dapat terpotong setelah 500 baris job; serta tidak tersedia histori transfer untuk mencegah pembayaran ganda atau menelusuri selisih.

## Temuan

### P1 — Aplikasi tidak merekam pembayaran aktual

Halaman Rekap secara eksplisit menyebut pembayaran tetap manual di luar sistem dan bukan bukti bayar ([social.tsx](</Users/drefan/Projects/JERSYE FLOW/threadline/src/components/social.tsx:353>), [social.tsx](</Users/drefan/Projects/JERSYE FLOW/threadline/src/components/social.tsx:428>)). Migrasi yang terkait pembayaran hanya menyimpan frekuensi dan metode transfer serta pengaturan rekening; tidak ditemukan tabel transaksi, alokasi transfer ke job, nominal yang sudah dibayar, tanggal bayar, referensi bank, atau bukti transfer ([migrasi pengaturan pembayaran](</Users/drefan/Projects/JERSYE FLOW/threadline/supabase/migrations/20261017000012_freelancer_payment_schedule.sql:27>)).

**Dampak:** Finance tidak dapat membedakan fee yang menjadi kewajiban dengan uang yang sudah ditransfer. Pembayaran sebagian, cicilan lintas job, koreksi, dan pemeriksaan pembayaran ganda juga tidak memiliki jejak di aplikasi.

### P1 — Rekap job dibatasi 500 baris tanpa memberi tahu pengguna

Saat memuat data, klien meminta job dengan urutan terbaru dan `.limit(500)` ([store-context.tsx](</Users/drefan/Projects/JERSYE FLOW/threadline/src/lib/store-context.tsx:177>)). Rekap lalu menjumlahkan daftar tersebut di browser ([social.tsx](</Users/drefan/Projects/JERSYE FLOW/threadline/src/components/social.tsx:327>)). Tidak terlihat pagination, agregasi server, atau penanda bahwa data telah terpotong.

**Dampak:** ketika jumlah job melewati batas, rekap bisa kurang dari nilai sebenarnya tanpa peringatan. Ini bertentangan dengan kebutuhan “rekap semua”.

### P1 — Tidak ada rekap per bulan

Rekap saat ini menghitung seluruh job `Finished` sekaligus dan mengelompokkannya per penerima. Tidak ada pemilih bulan, rentang tanggal, nilai belum dibayar, total yang sudah dibayar, atau keluaran laporan bulanan ([social.tsx](</Users/drefan/Projects/JERSYE FLOW/threadline/src/components/social.tsx:327>)). Opsi “Bulanan” yang tersedia hanya menyimpan preferensi jadwal freelancer, bukan membuat periode atau laporan pembayaran ([domain.ts](</Users/drefan/Projects/JERSYE FLOW/threadline/src/lib/domain.ts:75>), [migrasi pengaturan pembayaran](</Users/drefan/Projects/JERSYE FLOW/threadline/supabase/migrations/20261017000012_freelancer_payment_schedule.sql:14>)).

**Dampak:** daftar saat ini tidak bisa dipakai sebagai tutup buku bulanan dan tidak menunjukkan carry-over fee yang belum dibayar.

### P1 — Tanggal rekap yang ditampilkan bukan tanggal pembayaran

Daftar job mengambil waktu `preview_approve` sebagai tanggal yang ditampilkan, melalui RPC bernama `finance_acc_approval_times` ([store-context.tsx](</Users/drefan/Projects/JERSYE FLOW/threadline/src/lib/store-context.tsx:267>), [migrasi alur preview](</Users/drefan/Projects/JERSYE FLOW/threadline/supabase/migrations/20261017000010_preview_workflow.sql:370>)). Padahal job baru masuk `Finished` setelah freelancer mengunggah file asli CDR ([migrasi alur preview](</Users/drefan/Projects/JERSYE FLOW/threadline/supabase/migrations/20261017000010_preview_workflow.sql:243>)). Belum ada `paid_at` karena pembayaran aktual tidak dicatat.

**Dampak:** bila tanggal persetujuan dipakai untuk laporan bulanan, laporan akan memasukkan fee ke bulan persetujuan, bukan bulan file diserahkan atau bulan transfer terjadi. Ketiganya perlu dibedakan sesuai tujuan laporan.

### P2 — Finance menerima seluruh kolom job Finished, bukan hanya data rekap

Klien meminta `jobs.select("*")` ([store-context.tsx](</Users/drefan/Projects/JERSYE FLOW/threadline/src/lib/store-context.tsx:180>)). Kebijakan RLS Finance membatasi baris ke status `Finished`, tetapi kebijakan tersebut tidak membatasi kolom ([migrasi alur preview](</Users/drefan/Projects/JERSYE FLOW/threadline/supabase/migrations/20261017000010_preview_workflow.sql:378>)). Skema job juga memuat `brief`, `ref`, `deadline`, dan kolom operasional lain ([skema inti](</Users/drefan/Projects/JERSYE FLOW/threadline/supabase/migrations/20251017000000_threadline_core.sql:47>)).

**Dampak:** Finance dapat meminta kolom yang tidak diperlukan untuk rekap fee, meskipun layar Rekap hanya menampilkan kode job, tim, jenis job, tanggal persetujuan, dan nominal. Pertimbangkan view/RPC dengan daftar kolom minimal atau hak SELECT per kolom.

### P2 — Nomor rekening lengkap ditampilkan kepada semua Finance

RPC Finance mengembalikan nama, bank, nomor rekening, dan nama pemilik untuk seluruh freelancer yang disetujui ([migrasi pengaturan pembayaran](</Users/drefan/Projects/JERSYE FLOW/threadline/supabase/migrations/20261017000012_freelancer_payment_schedule.sql:27>)). UI menampilkan rincian itu secara langsung, termasuk nomor rekening penuh ([social.tsx](</Users/drefan/Projects/JERSYE FLOW/threadline/src/components/social.tsx:235>)).

**Dampak:** data rekening sensitif tersedia di browser Finance meskipun pengguna hanya sedang melihat rekap. Akses ini dapat dibutuhkan untuk transfer manual, tetapi sebaiknya ditampilkan seperlunya dan ditelusuri.

### P2 — Dokumen role Finance tidak sesuai dengan kemampuan yang sudah diterapkan

PRD, glosarium, operasi, dan kontrak teknis masih menggambarkan Finance sebagai baca-saja atas job ACC/rekap fee ([PRD](</Users/drefan/Projects/JERSYE FLOW/PRD-Threadline.md:31>), [glosarium](</Users/drefan/Projects/JERSYE FLOW/GLOSSARY.md:6>), [OPERATIONS](</Users/drefan/Projects/JERSYE FLOW/OPERATIONS.md:65>), [kontrak teknis](</Users/drefan/Projects/JERSYE FLOW/TECHNICAL-CONTRACT.md:67>)). Kode terbaru justru menampilkan jadwal transfer, rekening bank, dan mengizinkan Finance menyimpan perubahan jadwal melalui RPC yang dicatat ke audit ([UI Rekap](</Users/drefan/Projects/JERSYE FLOW/threadline/src/components/social.tsx:281>), [RPC jadwal](</Users/drefan/Projects/JERSYE FLOW/threadline/supabase/migrations/20261017000012_freelancer_payment_schedule.sql:55>)). Status data juga berbeda: dokumen menyebut ACC, sedangkan implementasi rekap Finance memakai `Finished` setelah file asli dikirim.

**Dampak:** pengembangan selanjutnya berisiko mengikuti dokumen yang berbeda dari produk aktual; batas tulis Finance juga tidak terdefinisi jelas.

## Kontrol yang sudah baik

- Menu Finance dibatasi ke Rekap dan Akun; area aplikasi mengarahkan Finance keluar dari rute operasional ([app-shell.tsx](</Users/drefan/Projects/JERSYE FLOW/threadline/src/components/app-shell.tsx:69>), [app-frame.tsx](</Users/drefan/Projects/JERSYE FLOW/threadline/src/components/app-frame.tsx:97>)).
- Batas akses tidak hanya mengandalkan UI: RLS membatasi job Finance ke `Finished`, dan Finance tidak mendapatkan kebijakan baca untuk file, submission, event mentah, chat, atau pengaturan bersama ([migrasi role](</Users/drefan/Projects/JERSYE FLOW/threadline/supabase/migrations/20261017000000_role_hierarchy.sql:119>), [migrasi alur preview](</Users/drefan/Projects/JERSYE FLOW/threadline/supabase/migrations/20261017000010_preview_workflow.sql:378>)).
- RPC rekening dan jadwal memeriksa role Finance serta membatasi target ke freelancer yang disetujui; perubahan jadwal ditulis ke audit ([migrasi pengaturan pembayaran](</Users/drefan/Projects/JERSYE FLOW/threadline/supabase/migrations/20261017000012_freelancer_payment_schedule.sql:47>), [audit perubahan jadwal](</Users/drefan/Projects/JERSYE FLOW/threadline/supabase/migrations/20261017000012_freelancer_payment_schedule.sql:99>)).

## Rekomendasi

### Prioritas 1 — Tetapkan definisi angka dan periode

Pisahkan setidaknya dua angka: **fee yang menjadi hak/utang** dan **pembayaran yang benar-benar keluar**. Tentukan kapan fee dianggap layak dibayar—saat preview di-ACC atau saat file asli diterima—dan gunakan tanggal itu untuk laporan kewajiban. Gunakan tanggal transfer untuk laporan realisasi kas. Pertahankan zona waktu bisnis Asia/Jakarta secara konsisten.

### Prioritas 1 — Tambahkan buku transaksi pembayaran yang dapat ditelusuri

Catat setiap transfer sebagai transaksi dengan ID, freelancer, nominal, tanggal/waktu, metode, referensi bank, bukti transfer, pencatat, dan status. Hubungkan transaksi ke satu atau beberapa job agar pembayaran gabungan dan pembayaran sebagian bisa direkonsiliasi. Simpan snapshot penerima/rekening saat transfer. Koreksi atau pembatalan sebaiknya membuat entri pembalik dengan alasan dan pelaku; jangan menghapus atau menimpa histori pembayaran.

### Prioritas 1 — Buat rekap bulanan dari database

Sediakan pemilih bulan dan rekap per freelancer yang memuat saldo awal, fee baru pada bulan itu, pembayaran pada bulan itu, saldo akhir/belum dibayar, jumlah job, serta tautan rincian transaksi. Sediakan ekspor CSV untuk rekonsiliasi. Agregasikan dan paginasi di server; jangan membuat total keuangan dari daftar yang berhenti di 500 job.

### Prioritas 2 — Persempit akses Finance dan rekening bank

Berikan Finance hak khusus untuk membaca kewajiban dan mencatat pembayaran; tetap tolak perubahan fee/job, akun, dan pengaturan umum. Sajikan data job melalui view/RPC dengan kolom minimum. Samarkan nomor rekening secara default dan tampilkan penuh hanya pada langkah menyiapkan transfer; catat siapa yang membuka atau mengubah data rekening.

### Prioritas 2 — Samakan dokumen dengan alur aktual

Perbarui PRD, kontrak teknis, OPERATIONS, dan glosarium agar menyatakan Finance boleh mengelola catatan pembayaran secara terbatas. Tegaskan status pemicu kewajiban (`ACC` atau `Finished`), definisi periode, perlakuan pembayaran sebagian, serta siapa yang boleh mengoreksi transaksi.

## Kriteria selesai yang disarankan

1. Finance dapat melihat semua kewajiban fee dan status saldo per freelancer.
2. Finance dapat mencatat transfer sekali dengan referensi/bukti dan alokasi job; pencatatan duplikat ditolak atau diberi peringatan.
3. Rekap bulan memisahkan fee yang timbul dari uang yang benar-benar dibayar dan membawa saldo belum lunas ke bulan berikutnya.
4. Total konsisten untuk jumlah job di atas 500, dan laporan menyatakan periode serta zona waktunya.
5. Finance tidak dapat mengubah fee/job, membaca file/chat/event mentah, atau mengakses kolom job yang tidak dibutuhkan.
6. Setiap pencatatan, koreksi, dan pembatalan pembayaran memiliki jejak pelaku, waktu, nilai sebelum/sesudah, dan alasan.

## Batas audit

Audit ini meninjau implementasi dan migrasi yang ada di workspace; saya tidak memeriksa apakah migrasi tersebut sudah diterapkan pada Supabase produksi, tidak mengakses data rekening atau transaksi nyata, dan tidak menjalankan pengujian dinamis. Karena itu, kesimpulan tentang perilaku produksi perlu dikonfirmasi terhadap versi database yang sedang berjalan.

## Tindak lanjut setelah rekomendasi disetujui

Implementasi disiapkan di workspace setelah persetujuan:

- Migrasi ledger baru menambahkan tanggal `finished_at`, transaksi manual, alokasi transfer per job, snapshot rekening saat pencatatan, bukti privat, pembatalan beralasan, laporan saldo bulanan, pagination, serta audit untuk transfer, jadwal, dan pembukaan data rekening/bukti.
- Layar Finance kini memakai laporan berbasis database, menampilkan saldo awal/fee/transfer/saldo akhir, rincian job yang belum lunas, unduh CSV, histori transaksi, dan log audit.
- Finance tidak lagi meminta daftar job di browser dan policy baca langsung Finance pada tabel `jobs` dihapus. Nomor rekening hanya ditampilkan tersamarkan sampai dibuka lewat RPC yang mencatat aktivitas.
- Policy baca bukti di Storage mensyaratkan log pembukaan bukti oleh aktor yang sama dalam lima menit terakhir; ini membuat pembuatan signed URL lewat Storage tetap ber-audit.
- PRD, kontrak teknis, operasi, glosarium, dan rencana implementasi diselaraskan dengan alur tersebut.

**Status verifikasi:** migrasi dan perubahan kode belum diterapkan ke database Supabase; tidak ada data produksi yang diperiksa. Pengujian dinamis dan test suite tidak dijalankan. Untuk job lama yang tidak memiliki event `finish`, migrasi memperkirakan `finished_at` dari `created_at`; catatan tersebut ditampilkan di layar laporan dan dapat membuat pengelompokan bulan historis berbeda dari tanggal serah terima sebenarnya. Migrasi juga tidak mengimpor transfer lama yang sebelumnya dicatat di luar aplikasi. Sebelum laporan dipakai untuk tutup buku, jalankan migrasi pada lingkungan sasaran, tinjau tanggal perkiraan job lama, lalu catat transfer historis beserta tanggal dan bukti aslinya agar saldo awal cocok.
