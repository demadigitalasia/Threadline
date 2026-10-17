# Audit End-to-End Role Freelancer

**Tanggal:** 17 Oktober 2026  
**Cakupan:** pendaftaran, aktivasi, pembatasan akses, check-in/presence, penugasan, file, review/revisi, penyelesaian, fee, chat, dan penonaktifan.  
**Metode:** penelusuran statis PRD, kontrak teknis, halaman dan API Next.js, serta migrasi Supabase sampai migrasi `20261017000019`. Tidak membuat akun uji dan tidak mengubah aplikasi atau database.

## Ringkasan

Alur kerja setelah freelancer aktif memiliki fondasi kontrol yang baik: akses job/thread dibatasi di database, transisi kerja dilakukan melalui RPC yang memeriksa penerima dan status, dan snapshot fee serta penerima dikunci saat ACC. Namun, saya menemukan **tujuh temuan: empat P1 dan tiga P2**. Yang paling penting adalah pendaftaran menyatakan email sudah diverifikasi tanpa membuktikan kepemilikan, presence dapat dimanipulasi lewat update profil langsung, RPC penugasan menerima profil freelancer yang belum aktif/approved, dan Admin dapat membaca rekening mentah.

Temuan P2 lainnya adalah endpoint pendaftaran tanpa pembatasan abuse khusus, unggahan objek Storage yang melewati reservation kuota, dan rekening bank wajib diisi sebelum menggunakan aplikasi meskipun syarat itu belum tertulis di PRD.

## Peta alur yang ditemukan

1. **Daftar:** form mengirim nama, email, WhatsApp, dan kata sandi ke endpoint server. Endpoint membuat akun Auth dengan `email_confirm: true`. Trigger membuat profil ber-role `freelance`, `pending`, dan nonaktif; thread dukungan freelancer juga langsung dibuat.
2. **Tinjau pendaftaran:** Admin/Super Admin menyetujui atau menolak pendaftaran. Freelancer pending dapat masuk untuk melihat status, tetapi helper identitas operasional tidak mengizinkan akses job, file, atau operasi lain. Keputusan mencatat aktor dan alasan.
3. **Aktivasi:** setelah disetujui, freelancer harus menyimpan rekening bank sebelum layar aplikasi lain terbuka. `is_freelance()` juga mensyaratkan rekening itu, sehingga form bukan sekadar gerbang antarmuka.
4. **Check-in dan penugasan:** freelancer memilih status kesiapan; browser memperbarui heartbeat setiap 30 detik. Admin dapat memilih penerima dari daftar dan RPC memeriksa role, presence kurang dari 90 detik, serta kapasitas.
5. **Pengerjaan:** freelancer memulai job Antre, mengunggah preview, lalu mengirim submission. Admin memberi ACC atau meminta revisi dengan alasan. Setelah ACC, freelancer mengunggah file CDR asli dan menyelesaikan job.
6. **Fee dan percakapan:** setelah status `Finished`, fee ditampilkan sebagai total fee Finished pada halaman Akun freelancer. Pencatatan transfer dan histori pembayaran ditangani role Finance. Thread dukungan tetap hanya dapat dibaca freelancer pemilik, Admin, dan Super Admin.
7. **Penonaktifan:** akun nonaktif kehilangan akses operasional melalui helper/RLS/RPC dan melihat layar status. Job aktif yang sudah ditugaskan tidak otomatis dipindahkan; Admin perlu menangani pengalihan atau pembatalannya.

## Temuan prioritas

### P1 — Endpoint pendaftaran melewati verifikasi kepemilikan email

Route publik membuat user melalui Auth Admin API dengan `email_confirm: true`; form juga mengatakan pengguna tidak perlu mengeklik tautan verifikasi. Ini bertentangan dengan PRD AC-02, yang mensyaratkan verifikasi email sebelum penggunaan aplikasi, dan OPERATIONS yang meminta konfirmasi email.

Persetujuan Admin tidak membuktikan bahwa pendaftar memiliki alamat email tersebut. Seseorang dapat mendaftarkan email orang lain dengan kata sandi yang ia pilih. Jika Admin menyetujui akun itu, orang tersebut dapat masuk memakai email korban.

**Rekomendasi:** pertahankan akun sebagai pending, tetapi wajibkan konfirmasi email sungguhan sebelum masuk ke antrean review atau sebelum aktivasi. Jangan mengisi `email_confirmed_at` secara otomatis. Tampilkan pendaftaran yang sudah memiliki `email_confirmed_at` kepada reviewer. Putuskan dan dokumentasikan apakah persetujuan Admin tetap bagian dari alur karena implementasi sekarang mensyaratkannya sedangkan PRD menyatakan tidak.

Referensi: [route pendaftaran](threadline/src/app/api/freelancer-registrations/route.ts#L31), [form pendaftaran](threadline/src/app/register/page.tsx#L18), [aturan akun PRD](PRD-Threadline.md#L39), [AC-02](PRD-Threadline.md#L138), [trigger profil pending](threadline/supabase/migrations/20261017000006_freelancer_registration_review.sql#L41).

### P1 — Freelancer dapat memalsukan heartbeat dan status online

Heartbeat dikirim dengan update langsung ke `profiles.last_seen`. Kebijakan RLS mengizinkan freelancer mengubah baris profilnya sendiri, sedangkan trigger hanya melindungi role/status akses dan status review. Tidak ada validasi bahwa `last_seen` ditetapkan server atau tidak berada di masa depan. Rumus presence menganggap timestamp masa depan tetap online.

Akibatnya, pemilik akun dapat mengirim `last_seen` jauh ke depan dan tetap tampak online; RPC penugasan memakai nilai yang sama. Ini membuat daftar presence Admin dan aturan penugasan tidak dapat dipercaya.

**Rekomendasi:** larang update `last_seen` langsung dari klien dan pindahkan heartbeat ke RPC terbatas yang menulis waktu server (`now()`/`clock_timestamp()`). Tambahkan syarat timestamp tidak di masa depan pada pemeriksaan presence dan pada RPC penugasan.

Referensi: [policy update profil sendiri](threadline/supabase/migrations/20261017000000_role_hierarchy.sql#L82), [heartbeat browser](threadline/src/lib/store-context.tsx#L360), [rumus online](threadline/src/lib/domain.ts#L280), [pemeriksaan presence saat assign](threadline/supabase/migrations/20261017000010_preview_workflow.sql#L129).

### P1 — RPC penugasan tidak memeriksa freelancer aktif dan approved

`assign_job` hanya memverifikasi target memiliki role `freelance`, timestamp online, dan kapasitas. RPC tidak memeriksa `is_active`, `registration_status = 'approved'`, atau apakah target sudah memenuhi gerbang operasional. Sementara itu, profil baru dibuat dengan `last_seen DEFAULT now()`, jadi pendaftar pending dapat tampak online hingga 90 detik. UI juga menampilkan semua freelancer sebagai pilihan; status “belum check-in” dan “tidak siap” hanya berupa keterangan.

Job dapat ditugaskan kepada akun yang belum disetujui atau sudah dinonaktifkan tetapi timestamp-nya masih segar. Freelancer itu tidak dapat membuka job karena RLS menolaknya, sehingga pekerjaan tertahan dan harus dipindah manual.

**Rekomendasi:** di dalam RPC, wajibkan profil target aktif, approved, ber-role freelancer, memiliki prasyarat operasional, dan heartbeat valid sebelum assignment. Pilih secara eksplisit apakah `availability_status = 'ready'` merupakan syarat; bila iya, tegakkan aturan yang sama pada UI dan database. Untuk profil baru, mulai `last_seen` sebagai offline sampai heartbeat pertama diterima.

Referensi: [default heartbeat profil](threadline/supabase/migrations/20251017000000_threadline_core.sql#L27), [profil pendaftaran nonaktif](threadline/supabase/migrations/20261017000006_freelancer_registration_review.sql#L56), [RPC penugasan](threadline/supabase/migrations/20261017000010_preview_workflow.sql#L117), [pilihan penerima UI](threadline/src/components/job-detail.tsx#L239), [helper akses operasional](threadline/supabase/migrations/20261017000007_freelancer_bank_accounts.sql#L71).

### P1 — Admin dapat membaca nomor rekening mentah melalui database

Tabel rekening memberi hak `SELECT` kepada semua pengguna authenticated dan policy baca menggunakan `is_admin()`. Helper itu mencakup Admin dan Super Admin. Maka Admin bisa membaca `account_number` mentah melalui API database meskipun halaman Finance menggunakan alur khusus untuk membuka nomor penuh dan mencatat pengungkapan.

Ini memperluas akses data finansial freelancer di luar kebutuhan tugas Admin dan melewati jalur audit pembukaan rekening.

**Rekomendasi:** cabut baca langsung untuk Admin. Beri Finance akses melalui RPC yang hanya mengembalikan empat digit terakhir, lalu RPC reveal nomor penuh yang menulis event audit. Tentukan secara eksplisit apakah Super Admin boleh membaca rekening mentah dan pastikan jalurnya juga tercatat.

Referensi: [grant dan policy rekening](threadline/supabase/migrations/20261017000007_freelancer_bank_accounts.sql#L18), [RPC rekening Finance dan audit](threadline/supabase/migrations/20261017000019_finance_payment_ledger.sql#L455), [kontrak akses Finance](TECHNICAL-CONTRACT.md#L48), [aturan privasi finansial PRD](PRD-Threadline.md#L66).

### P2 — Endpoint pendaftaran tidak memiliki pembatasan abuse khusus

Endpoint pendaftaran menggunakan Auth Admin API dengan service role dan tidak memiliki pembatasan laju per IP/email atau CAPTCHA di route. Konfigurasi `auth.rate_limit.sign_in_sign_ups` berlaku pada endpoint Auth publik, sedangkan form ini memanggil route aplikasi sendiri. Route juga membedakan email yang sudah terdaftar dengan respons `409`, sehingga alamat yang telah memiliki akun dapat ditebak.

**Rekomendasi:** pasang rate limit server/edge pada route pendaftaran dan pertimbangkan CAPTCHA untuk pendaftaran publik. Gunakan pesan respons umum untuk konflik email agar route tidak menjadi oracle enumerasi akun.

Referensi: [route pendaftaran dan respons konflik](threadline/src/app/api/freelancer-registrations/route.ts#L4), [konfigurasi Auth rate limit](threadline/supabase/config.toml#L210).

### P2 — Upload Storage dapat melewati reservation dan batas 10 GiB

Aplikasi memanggil `reserve_upload` sebelum mengunggah dan trigger `job_files` memeriksa reservation/kuota saat metadata dibuat. Namun, policy insert `storage.objects` untuk freelancer hanya memeriksa bucket dan apakah ID job di path cocok dengan job yang ditugaskan. Policy itu tidak meminta reservation aktif atau status job yang dapat menerima unggahan.

Freelancer yang sudah ditugaskan dapat mengunggah objek langsung melalui Storage API tanpa membuat metadata `job_files`. Objek yatim tersebut tidak masuk perhitungan kuota 10 GiB dan dapat terus mengonsumsi ruang.

**Rekomendasi:** kaitkan izin insert Storage dengan reservation aktif milik sesi, job yang sama, dan status kerja yang sah. Bersihkan reservation serta objek yatim setelah unggahan gagal atau metadata tidak tercatat.

Referensi: [policy insert Storage](threadline/supabase/migrations/20261017000000_role_hierarchy.sql#L216), [reservation kuota](threadline/supabase/migrations/20261017000010_preview_workflow.sql#L298), [validasi metadata file](threadline/supabase/migrations/20251017000001_file_reservation_link.sql#L26), [alur upload aplikasi](threadline/src/lib/store-context.tsx#L715).

### P2 — Rekening bank wajib sebelum freelancer bisa memakai aplikasi, tetapi belum ada di spesifikasi

Setelah review disetujui, `AppFrame` memblokir seluruh halaman sampai form rekening selesai. Fungsi `is_freelance()` juga menolak akses operasional jika baris rekening tidak ada. Ini berarti rekening diminta sebelum freelancer dapat melihat atau memulai pekerjaan. Syarat tersebut tidak muncul sebagai langkah onboarding di PRD maupun checklist operasi.

**Rekomendasi:** bila rekening memang harus tersedia sejak awal, tambahkan alasan, kebijakan privasi/retensi, dan langkah ini ke spesifikasi/onboarding. Bila rekening baru diperlukan untuk pembayaran pertama, hapus rekening sebagai syarat akses job dan validasi kelengkapannya saat Finance mencatat transfer.

Referensi: [gerbang rekening di aplikasi](threadline/src/components/app-frame.tsx#L198), [helper freelance mensyaratkan rekening](threadline/supabase/migrations/20261017000007_freelancer_bank_accounts.sql#L71), [aturan freelancer PRD](PRD-Threadline.md#L33).

## Kontrol yang sudah tampak baik

- Profil freelancer baru dibuat dengan role tetap `freelance`; pemilik tidak dapat mengubah role/status akses. Keputusan review ditulis oleh server tepercaya.
- Akun pending/rejected/nonaktif tidak memperoleh identitas operasional. Operasi job, file, chat, dan RPC memeriksa role/identitas di database.
- Freelancer hanya membaca job yang ditugaskan dan thread dukungan sendiri. Pesan dikaitkan dengan identitas sesi, bukan ID pengirim dari klien.
- `submit_preview` memeriksa assignee, status, revisi, file preview, dan file milik sesi. Review mengikat keputusan Admin ke submission aktif; alasan revisi wajib diisi.
- Setelah ACC, fee dan penerima terkunci. `finish_job` mensyaratkan CDR asli aktif yang diunggah freelancer penanggung jawab. Event perubahan alur dicatat.
- Freelancer Akun menampilkan total fee dari job Finished miliknya; pencatatan transfer aktual tetap terpisah di alur Finance.

## Urutan tindak lanjut yang disarankan

1. **Tutup risiko identitas:** aktifkan bukti kepemilikan email dan selaraskan aturan persetujuan dengan PRD.
2. **Kuatkan presence dan assignment:** jadikan heartbeat server-side; validasi aktif/approved/prasyarat, timestamp, kapasitas, dan keputusan kesiapan secara atomik.
3. **Batasi data rekening:** hilangkan SELECT rekening mentah untuk Admin dan wajibkan jalur Finance yang ber-audit.
4. **Tegakkan anggaran upload di Storage:** setiap object harus punya reservation yang dapat diverifikasi dan terkait ke job/session yang benar.
5. **Putuskan kebutuhan rekening saat onboarding** dan perbarui PRD/OPERATIONS agar implementasi dan proses reviewer konsisten.

## Batas audit

Ini adalah audit statis terhadap source dan migrasi lokal. Saya belum menjalankan pengujian dengan akun freelancer nyata atau meminta Supabase lokal memverifikasi policy/RPC secara runtime. Checklist pilot di `OPERATIONS.md` tetap harus dijalankan setelah perbaikan, terutama pengujian lintas akun, status 90 detik, approval/revisi, akses file, dan offboarding.
