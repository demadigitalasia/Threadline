# PRD — Threadline

| Informasi | Nilai |
| --- | --- |
| Status | Draft konsolidasi lokal |
| Tanggal | 17 Oktober 2026 |
| Produk | Aplikasi pengelolaan pekerjaan freelance konveksi jersey |
| Peran | Super Admin, Finance, Admin, dan Freelance |
| Target implementasi | Next.js dengan App Router; gunakan rilis stabil terbaru saat implementasi. Baseline riset resmi yang tercatat pada 17 Oktober 2026 adalah Next.js 16.4; verifikasi dan kunci nomor patch di [TECHNICAL-CONTRACT.md](TECHNICAL-CONTRACT.md). |
| Target data platform | Supabase self-hosted di VPS untuk PostgreSQL 17, Auth, Storage API, dan Realtime; Cloudflare R2 menjadi backend objek privat Supabase Storage. Detail operasional ada di [TECHNICAL-CONTRACT.md](TECHNICAL-CONTRACT.md). |

Dokumen ini menjadi sumber utama kebutuhan dan keputusan produk. Detail penyimpanan, kontrol akses, realtime, serta setup berada di [TECHNICAL-CONTRACT.md](TECHNICAL-CONTRACT.md) dan [OPERATIONS.md](OPERATIONS.md). Keputusan produk yang disepakati dicatat pada bagian 9.

## 1. Masalah

Brief, tenggat, revisi, file hasil, dan percakapan pekerjaan tersebar di banyak grup WhatsApp. Admin sulit memantau beban freelance dan pekerjaan yang perlu ditangani; freelance dapat melewatkan perubahan atau pekerjaan baru.

## 2. Tujuan dan ukuran keberhasilan

1. Dalam Mode Online, setiap role melihat data yang sesuai dengan kewenangannya dari perangkat masing-masing.
2. Dalam Mode Online, job baru tampil di perangkat Freelance penerima dalam waktu kurang dari 3 detik ketika realtime berfungsi.
3. Dalam Mode Online, Admin dan Super Admin dapat mengetahui siapa yang online, penuh, terlambat, menunggu ACC, atau sudah selesai.
4. Dalam Mode Online, Freelance hanya dapat melihat job miliknya dan thread langsungnya dengan Admin.
5. File pekerjaan layak dipurge saat `now >= uploaded_at + 30 hari`, diproses tugas server pada eksekusi harian berikutnya; hasil dan status purge dapat ditinjau operator.

## 3. Pengguna

| Peran | Tanggung jawab |
| --- | --- |
| Super Admin | Memiliki seluruh kewenangan Admin, melihat semua rekap fee, serta mengelola role dan status akses akun lain. Super Admin aktif terakhir tidak dapat diturunkan atau dinonaktifkan. |
| Finance | Membaca rekap fee dan kewajiban, melihat rekening sesuai kebutuhan, serta mencatat atau membatalkan pencatatan transfer dengan bukti dan alasan; tidak mengubah pekerjaan, fee, role, atau akses akun. |
| Admin | Membuat job, mengelola antrean dan penugasan, memantau pekerjaan, meminta revisi, memberi ACC, membatalkan job dengan alasan, membaca semua thread, dan melihat rekap fee. Tidak mengelola role atau status akses akun. |
| Freelance | Melihat dan mengerjakan job yang ditugaskan; mengunggah hasil; meminta ACC; berdiskusi dengan Admin. |

Satu akun mewakili satu orang. Beberapa akun dapat memiliki setiap role. Dalam Mode Online, identitas dan peran mengikuti akun yang masuk.

Kecuali dinyatakan khusus, Super Admin mewarisi semua kewenangan operasional Admin. Finance memiliki akses finansial terbatas sebagaimana R-09 dan R-16; Finance tidak mendapat akses operasional pekerjaan.

### Alur akun

1. Dalam Mode Online, siapa pun dapat mengajukan pendaftaran menggunakan email dan kata sandi tanpa undangan. Pendaftaran publik membuat akun berperan Freelance dengan status menunggu verifikasi dan tinjauan.
2. Pengguna harus memverifikasi alamat email sebelum akun muncul dalam antrean tinjauan. Admin atau Super Admin menyetujui atau menolak pendaftaran; hanya akun yang disetujui dan aktif yang dapat memakai fitur operasional.
3. Pengguna terverifikasi dapat masuk dengan email dan kata sandi untuk melihat status tinjauan; akun yang disetujui dapat memakai aplikasi. Pengguna yang lupa kata sandi meminta tautan reset melalui email dan membuat kata sandi baru.
4. Freelance hanya dapat mengakses job yang ditugaskan kepadanya, file terkait job tersebut, dan thread dukungan miliknya sendiri. Pendaftaran terbuka tidak memberikan akses ke job, thread, atau file pengguna lain maupun daftar profil freelance.
5. Operator proyek menetapkan Super Admin pertama melalui prosedur tepercaya setelah email diverifikasi. Setelah bootstrap, Super Admin dapat mengubah role dan status akses pengguna di aplikasi. Setiap perubahan mencatat target, role/status lama dan baru, pelaku, waktu, serta alasan. Pemilik akun tidak dapat mengubah role atau status aksesnya sendiri; Super Admin aktif terakhir tidak dapat diturunkan atau dinonaktifkan.
6. Pengguna dapat keluar untuk mengakhiri sesi pada perangkat tersebut.

## 4. Aturan produk

| ID | Aturan |
| --- | --- |
| R-01 Alur status | Status: Belum Ditugaskan, Antre, Dikerjakan, Preview, MintaACC, Revisi, ACC, Finished, dan Dibatalkan. Job baru berstatus Belum Ditugaskan. Setelah ditugaskan, job masuk Antre. Freelance mengirim preview dari Dikerjakan/Revisi; Admin dapat menyetujui Preview menjadi ACC atau meminta Revisi. Setelah ACC, Freelance mengirim file asli CDR lalu menandai job Finished. Snapshot penerima dan fee terkunci saat ACC; Finished dan Dibatalkan adalah status terminal. |
| R-02 Kapasitas | Freelance penuh saat memiliki 4 atau lebih job aktif yang ditugaskan kepadanya. Status Antre, Dikerjakan, Preview, MintaACC, Revisi, dan ACC dihitung karena masih memerlukan pekerjaan atau pengiriman file asli. Belum Ditugaskan, Finished, dan Dibatalkan tidak dihitung. |
| R-03 Presence | Dalam Mode Online, server mencatat heartbeat setiap 30 detik. Freelance online bila `last_seen` tidak berada di masa depan dan umurnya kurang dari 90 detik; pada 90 detik atau lebih ia offline. Profil baru dan profil tanpa heartbeat dianggap offline. Klien tidak dapat menentukan nilai `last_seen` sendiri. |
| R-04 Penugasan | Job boleh dibuat tanpa penerima dalam Belum Ditugaskan. Admin hanya dapat menugaskan atau mengalihkan ke Freelance yang aktif, telah disetujui, sedang online, memilih status siap menerima job, dan belum penuh; Mode Online memeriksanya secara atomik di backend. Penugasan awal memindahkan job ke Antre dan memulai `antre_since`. Pengalihan job Antre mempertahankan Antre dan memulai ulang timer. Pengalihan job Dikerjakan atau Revisi memerlukan alasan Admin dan mempertahankan status serta riwayat. Job Preview/MintaACC harus diputuskan Admin sebelum dialihkan. Job ACC hanya dapat dilanjutkan oleh penerima untuk mengirim file asli; job Finished atau Dibatalkan tidak dapat dialihkan. |
| R-05 Express | Job express ditampilkan paling atas dan memicu notifikasi di dalam aplikasi. Jika pengguna memberi izin browser, aplikasi boleh menampilkan notifikasi browser saat aplikasi sedang terbuka. Tidak ada notifikasi latar belakang saat aplikasi ditutup. |
| R-06 Urgensi | Job berstatus Antre menjadi Urgen setelah waktu sejak `antre_since` mencapai SLA bersama. Dalam Mode Online semua perangkat memakai nilai yang sama; nilai awalnya 3 jam dan Admin dapat mengubahnya. Penugasan awal dan pengalihan saat Antre memulai timer baru. Saat aplikasi terbuka, UI menampilkan pengingat Urgen; pengingat otomatis yang memerlukan scheduler atau push latar belakang belum termasuk MVP. |
| R-07 Chat | Satu thread menghubungkan satu Freelance dengan seluruh akun Admin dan Super Admin; kedua role tersebut dapat membaca dan membalasnya, dan identitas akun pengirim tetap terlihat. Maksimal 500 karakter per pesan. Finance tidak memiliki akses chat. Diskusi per-job dicatat terpisah pada timeline job. Pesan baru menampilkan notifikasi di dalam aplikasi; notifikasi browser hanya opsional saat aplikasi terbuka dan izin diberikan, tanpa notifikasi latar belakang. |
| R-08 File | Masa retensi setiap file adalah 30 hari sejak diunggah, termasuk file pada job ACC. File layak dipurge saat waktu saat ini mencapai `uploaded_at + 30 hari`; tugas server di VPS memprosesnya pada eksekusi harian pertama setelah waktu tersebut melalui Supabase Storage API. Kegagalan dicatat dan dicoba ulang. |
| R-09 Fee dan pembayaran | Fee yang disetujui saat ACC menjadi kewajiban ketika job berstatus `Finished` setelah file asli diterima. Snapshot fee dan penerima saat ACC tidak berubah; tanggal timbulnya kewajiban adalah `finished_at`. Data rekening Freelancer boleh disimpan di halaman Akun dan tidak menjadi syarat menerima atau mengerjakan job; Finance wajib memiliki rekening yang valid sebelum mencatat payout. Finance mencatat transfer manual dengan `paid_at`, referensi bank, bukti, dan alokasi ke satu atau beberapa job; alokasi sebagian diperbolehkan tetapi total pembayaran per job tidak boleh melebihi fee. Rekap bulanan menampilkan saldo awal, fee baru, transfer bersih (termasuk pembalik pada bulan pencatatan dibatalkan), saldo akhir, dan rincian job/transaksi. Pencatatan yang salah dibatalkan dengan alasan; jejak aslinya tetap tersimpan dan saldo dibalik pada bulan pembatalan. Aplikasi tidak mengirim atau memproses transfer melalui gateway. |
| R-10 Unggahan | Format yang diterima: PDF, CDR, PNG, JPEG, SVG, DOCX, XLSX, PPTX, AI, dan PSD; preview hanya PNG/JPEG/SVG dan file asli setelah ACC hanya CDR. Jumlah file tidak dibatasi; ukuran maksimum 1 GiB per file dan total 10 GiB untuk biner aktif serta unggahan yang sedang berlangsung pada satu job. Setiap transfer memerlukan reservation server berisi path, peran, dan ukuran; Storage serta metadata memeriksa reservation dan ukuran objek aktual. File yatim tetap dihitung sampai objeknya dibersihkan melalui Supabase Storage API. |
| R-11 Terlambat | Deadline adalah tanggal dan waktu yang disimpan sebagai timestamp. Untuk demo dan pilot awal, input serta tampilan memakai zona waktu Asia/Jakarta sebagai asumsi kerja. Job menjadi Terlambat saat waktu saat ini mencapai atau melewati deadline dan statusnya bukan ACC atau Dibatalkan. Terlambat adalah penanda turunan deadline, terpisah dari Urgen dan tidak mengubah status job. |
| R-12 Pengajuan hasil | Setiap MintaACC mengikat satu versi hasil dan sedikitnya satu file hasil pada daftar yang tidak berubah. Admin memeriksa dan menyetujui versi yang sama persis atau meminta Revisi dengan alasan. Setelah suatu file terikat ke submission, file dan relasinya tidak dapat diedit atau dihapus melalui alur biasa. Pengajuan setelah Revisi menjadi versi baru; keputusan sebelumnya tetap tercatat. |
| R-13 Pembatalan dan penghapusan | Admin dapat membatalkan job pada status Belum Ditugaskan, Antre, Dikerjakan, MintaACC, atau Revisi dengan alasan wajib. Job menjadi Dibatalkan dan riwayat tetap tersedia; job Dibatalkan tidak dihitung dalam kapasitas atau rekap fee. Penghapusan permanen hanya diperbolehkan untuk job Belum Ditugaskan tanpa aktivitas maupun file. |
| R-14 Riwayat | Perubahan status, penugasan/pengalihan, pengajuan hasil, keputusan Admin, dan pembatalan dicatat sebagai peristiwa berurutan dengan waktu dan pelaku. Peristiwa tidak diedit atau dihapus melalui alur produk biasa. |
| R-15 Privasi profil | Admin dan Super Admin dapat melihat profil serta presence Freelance untuk mengelola penugasan. Finance hanya melihat nama dan identitas finansial penerima yang diperlukan untuk mencatat kewajiban/pembayaran; nomor rekening disamarkan secara default dan ditampilkan penuh hanya melalui tindakan yang dicatat. Finance tidak menerima daftar profil operasional atau data kontak. Freelance dapat membaca profil dan presence akunnya sendiri, tetapi tidak dapat menelusuri profil atau presence Freelance lain; ia hanya melihat nama pelaku pada job yang ditugaskan atau thread miliknya. Email dan data akun tidak ditampilkan kepada pengguna lain. |
| R-16 Role dan akses akun | Urutan role adalah Super Admin, Finance, Admin, Freelance. Role awal pendaftaran publik adalah Freelance. Super Admin memiliki semua kewenangan Admin ditambah pengelolaan role/status akun lain; Finance memiliki akses baca laporan finansial, pengaturan jadwal, dan pencatatan/koreksi pembayaran melalui alur ber-audit, tetapi tidak membaca atau mengubah job operasional secara langsung; Admin mempertahankan kewenangan operasional dan akses rekap fee; Freelance hanya mengakses pekerjaannya sendiri. Super Admin dapat mengundang Admin, Finance, dan Freelance melalui email; penerima membuat kata sandinya sendiri setelah memverifikasi email. Perubahan role/status dan tindakan keamanan akun ditulis ke audit yang dapat ditinjau Super Admin. Super Admin aktif terakhir tidak dapat diturunkan atau dinonaktifkan; pengguna tidak dapat mengubah akses dirinya sendiri. Akun nonaktif hanya dapat membaca status profil nonaktifnya sendiri, tetapi RLS/RPC menolak data dan operasi Threadline lainnya. |
| R-17 Autentikasi Super Admin | Super Admin memakai sesi Auth aktif dan akun berstatus aktif; faktor TOTP bersifat opsional dan sesi AAL2 tidak diwajibkan. Pengaturan role, tindakan akun, dan perubahan aturan bersama wajib mencatat actor, waktu, target/nilai sebelum-sesudah, dan alasan. |

### Nilai domain

- Jenis job: Fullprint, Printing Depan Saja, Jersey + Celana, dan Jaket.
- Prioritas job: normal dan express.

Nama kerja adalah label pengguna pada penugasan dan thread. Nama harus unik dan dapat diubah oleh pemilik akun; perubahan nama tidak boleh memutus keterkaitan job dan percakapan.

## 5. Alur utama

| Langkah | Pelaku | Hasil |
| --- | --- | --- |
| Buat job | Admin | Job masuk Belum Ditugaskan dan dapat menunggu di antrean intake tanpa memakai kapasitas Freelance. |
| Tugaskan job | Admin | Job masuk Antre dan timer SLA dimulai setelah penerima yang memenuhi R-02 sampai R-04 dipilih. |
| Mulai bekerja | Freelance penerima | Status menjadi Dikerjakan. |
| Minta pemeriksaan | Freelance penerima | Status menjadi MintaACC. |
| Periksa hasil | Admin | Admin menyetujui versi dan file yang diajukan sehingga status menjadi ACC, atau meminta Revisi dengan alasan. |
| Kerjakan revisi | Freelance penerima | Status kembali menjadi Dikerjakan; alur pemeriksaan dapat diulang. |
| Selesaikan | Admin | ACC membekukan versi hasil dan fee yang disetujui; job masuk arsip dan rekap R-09. |
| Batalkan | Admin | Job yang tidak dilanjutkan menjadi Dibatalkan dengan alasan; riwayatnya tetap tersedia. |

Filter dan pencarian membantu admin menemukan job berdasarkan ID, tim, penerima, atau status. Admin dapat melihat job per freelance maupun per status; freelance hanya melihat job miliknya. Statistik freelance dibatasi pada data miliknya.

## 6. Ruang lingkup

### Termasuk

- Pendaftaran dan login.
- Empat role berurutan: Super Admin, Finance, Admin, dan Freelance, dengan pembatasan akses sesuai R-16.
- Dashboard, detail job, pencarian, filter, dan arsip job ACC.
- Pembuatan dan penugasan job, file hasil, timeline, status, dan rekap fee.
- Presence, pengingat Urgen dan notifikasi Express di dalam aplikasi, prioritas Express, serta rekomendasi pengalihan. Notifikasi browser bersifat opsional dan hanya berjalan saat aplikasi terbuka serta izin diberikan.
- Chat langsung per freelance dan realtime. Notifikasi pesan baru muncul di dalam aplikasi; notifikasi browser hanya opsional saat aplikasi terbuka dan izin diberikan, tanpa notifikasi latar belakang.
- Mode Demo dengan data lokal dan Mode Online multiuser.

### Tidak termasuk

- Payment gateway, payroll, atau bukti pembayaran.
- Backend REST kustom di luar Supabase, scheduler untuk pengingat produk, notifikasi latar belakang/server push/FCM, dan gateway WhatsApp. Tugas pemeliharaan harian VPS untuk purge file tetap termasuk dalam R-08.
- Edit, penarikan, atau penghapusan pesan oleh freelance.
- Pengiriman pesan WhatsApp otomatis. Tautan WhatsApp hanya menyiapkan draft yang dikirim pengguna.

## 7. Kebutuhan fungsional

| ID | Kebutuhan |
| --- | --- |
| F-01 | Dalam Mode Online, siapa pun dapat mengajukan pendaftaran dengan email dan kata sandi. Akun baru berperan Freelance; email harus diverifikasi sebelum masuk antrean tinjauan Admin/Super Admin, dan akun harus disetujui serta aktif sebelum mengakses fitur operasional. Pengguna dapat masuk untuk melihat status setelah verifikasi, keluar, dan meminta reset kata sandi melalui email. Operator proyek menetapkan Super Admin pertama melalui prosedur tepercaya; setelah bootstrap, hanya Super Admin dapat mengubah role/status akses melalui UI dan RPC ber-audit. |
| F-02 | Pengguna dapat mengubah nama profilnya sendiri, tetapi tidak dapat mengubah role atau status aksesnya sendiri. Super Admin dapat mengubah role/status akses akun lain melalui RPC terotorisasi; akun nonaktif tidak dapat memakai data atau operasi Threadline. |
| F-03 | Admin mengelola field job dan file sesuai status. Freelance hanya membaca job miliknya, mengubah status/timeline, dan mengunggah file hasil baru; pengubahan atau penghapusan file yang belum terikat submission dikelola Admin. Setelah file terikat submission, file dan relasinya terkunci; retensi 30 hari tetap menghapus objeknya. Setelah ACC, fee snapshot dan versi hasil yang disetujui tidak dapat diubah melalui edit biasa. |
| F-04 | UI menegakkan alur status R-01 pada kedua mode; dalam Mode Online backend juga menolak perubahan status di luar alur. |
| F-05 | UI mencegah penugasan yang melanggar R-02 sampai R-04 pada kedua mode; dalam Mode Online backend memeriksa akun aktif/disetujui, presence yang tidak berada di masa depan, kesiapan `ready`, dan kapasitas serta mengembalikan alasan penolakan. |
| F-06 | Sistem mendukung brief, deadline, fee, referensi, file, timeline, pencarian, filter, antrean Belum Ditugaskan, arsip ACC, dan job Dibatalkan. |
| F-07 | Chat memisahkan thread per Freelance. Freelance dapat membaca thread dukungannya sendiri walau belum mendapat job; Admin dan Super Admin dapat membaca semua thread. Finance tidak dapat membaca atau mengirim chat. Mode Online menegakkan batas ini di penyimpanan bersama. |
| F-08 | Dalam Mode Online, file privat yang disimpan di Cloudflare R2 melalui Supabase Storage dapat dibuka dari perangkat lain oleh pengguna terautentikasi yang berhak atas job; proses purge mengikuti R-08. |
| F-09 | Dalam Mode Online, perubahan job dan pesan baru diperbarui ke klien yang berlangganan realtime. |
| F-10 | Dashboard dan rekap mengikuti R-09/R-16. Admin dan Super Admin melihat rekap global; Finance melihat laporan kewajiban, transaksi aktual, saldo, rincian job yang belum lunas, jadwal, dan histori audit melalui akses terbatas; Freelance hanya melihat fee yang diatribusikan kepadanya. |
| F-11 | Mode Demo dan Mode Online tetap terpisah; Mode Online menggunakan identitas akun terautentikasi. |
| F-12 | Admin dapat mengubah SLA urgensi bersama; seluruh klien Mode Online menggunakan nilai terbaru yang sama. Sistem juga menampilkan penanda Terlambat berdasarkan deadline tanpa mengubah status job. |
| F-13 | Sistem mengikat setiap pengajuan MintaACC pada versi dan daftar file tertentu. ACC menyetujui pengajuan tersebut; Revisi wajib memiliki alasan; pengajuan ulang menjadi versi baru. |
| F-14 | Admin dapat membatalkan job pada status nonterminal sebelum ACC dengan alasan wajib. Job Dibatalkan tidak bisa ditugaskan kembali dan tidak masuk hitungan kapasitas atau rekap fee. Penghapusan permanen hanya tersedia untuk job Belum Ditugaskan tanpa aktivitas maupun file. |
| F-15 | Sistem mencatat peristiwa status, penugasan, pengalihan, pengajuan, keputusan, dan pembatalan pada riwayat job yang tidak dapat diubah melalui alur biasa. |
| F-16 | Mode Demo menyimpan data lokal terpisah dari Mode Online. Pengguna dapat mengosongkan data Demo tanpa mengubah data akun atau job Online. |
| F-17 | Super Admin dapat mengundang Admin, Finance, dan Freelance; mengubah role/status akses akun selain dirinya; mencari dan memfilter daftar akun; serta mengirim ulang verifikasi, mengirim tautan reset kata sandi, dan mencabut sesi pengguna. Semua tindakan akun meminta alasan dan masuk ke audit. Sistem menolak perubahan yang akan menurunkan atau menonaktifkan Super Admin aktif terakhir. |
| F-18 | Super Admin dapat mengakses fitur Super Admin tanpa TOTP. RLS/RPC dan endpoint server tetap memvalidasi sesi Auth, role Super Admin, serta status aktif, bukan hanya antarmuka. |
| F-19 | Perubahan SLA dan batas job aktif melalui jalur produk meminta alasan, menyimpan nilai sebelum/sesudah, pelaku, dan waktu, serta muncul pada riwayat keamanan Super Admin. |

## 8. Kriteria penerimaan

### Kriteria baseline untuk Mode Online

- [ ] **AC-01** Schema dapat dijalankan pada instance Supabase self-hosted baru dengan versi PostgreSQL yang dipin bersama rilis stack.
- [ ] **AC-02** Pendaftaran terbuka membuat profil Freelance pending. Email yang belum terverifikasi tidak muncul dalam antrean review; setelah verifikasi, Admin/Super Admin dapat meninjau. Pengguna terverifikasi dapat masuk untuk melihat status, tetapi hanya akun yang disetujui dan aktif dapat memakai fitur operasional. Super Admin pertama hanya dapat dibuat melalui jalur tepercaya.
- [ ] **AC-03** Job baru tampil pada perangkat freelance penerima dalam kurang dari 3 detik.
- [ ] **AC-04** Aturan akses data mencegah Freelance membaca atau mengubah job milik Freelance lain; Freelance tidak dapat menelusuri daftar profil atau presence Freelance lain.
- [ ] **AC-05** Freelance dapat membaca thread dukungannya sendiri sebelum maupun sesudah mendapat job, dan tidak dapat membaca thread freelance lain.
- [ ] **AC-06** File privat pada backend Cloudflare R2 dapat dibuka dari perangkat lain melalui Supabase Storage oleh pengguna terautentikasi yang berhak atas job.
- [ ] **AC-07** Freelance terlihat online hanya jika `last_seen` tidak berada di masa depan dan `0 <= now - last_seen < 90 detik`; heartbeat ditulis oleh server. Pada umur tepat 90 detik atau lebih, freelancer offline dan tidak dapat menerima job baru.
- [ ] **AC-08** Database menolak pesan yang lebih panjang dari 500 karakter.
- [ ] **AC-09** Fixture uji dapat dimasukkan setelah ID akun diisi.

### Kriteria penguatan

- [ ] **AC-10** Dalam Mode Online, pengguna tidak dapat mengubah role atau status akses profilnya sendiri; Finance memakai fungsi laporan pembayaran terbatas tanpa presence/profil operasional atau log job mentah. RLS/RPC menolak akses Finance ke data operasional lainnya.
- [ ] **AC-11** Dalam Mode Online, pengirim ditentukan dari akun terautentikasi; backend menolak penerima atau thread yang tidak berhak diakses akun tersebut.
- [ ] **AC-12** UI dan penyimpanan Mode Online hanya menerima ACC dari Admin atau Super Admin setelah status MintaACC.
- [ ] **AC-13** Nama kerja unik; pemilik akun dapat mengubah namanya dan riwayat job/thread tetap terhubung.
- [ ] **AC-14** Dalam Mode Online, backend menolak penugasan ke akun nonaktif/belum disetujui, freelancer offline/belum siap, atau freelancer penuh, termasuk saat dua penugasan terjadi berdekatan.
- [ ] **AC-15** Pengalihan job selalu memperbarui penerima, status, dan waktu antre.
- [ ] **AC-16** Dalam Mode Online, kebijakan RLS Supabase Storage membatasi baca, unggah, perubahan, dan penghapusan objek pada backend R2 sesuai keputusan privasi D-01; tidak ada akses bucket publik.
- [ ] **AC-17** Dalam Mode Online, perubahan job yang dibuat dari revisi lama ditolak; pengguna diminta memuat ulang sebelum menyimpan lagi.
- [ ] **AC-18** Dalam Mode Online, lebih dari satu akun Admin dan Super Admin dapat mengelola job sesuai R-16.
- [ ] **AC-19** Unggahan menerima PDF, CDR, PNG, JPEG, SVG, DOCX, XLSX, PPTX, AI, dan PSD; preview hanya gambar yang diizinkan dan file asli setelah ACC hanya CDR.
- [ ] **AC-20** Freelance dapat mengunggah file hasil baru untuk job miliknya, tetapi tidak dapat mengubah atau menghapus file yang sudah ada.
- [ ] **AC-21** Admin dapat mengubah SLA urgensi Mode Online; nilai baru tersimpan dan digunakan sama oleh semua perangkat, sedangkan Freelance hanya dapat membacanya.
- [ ] **AC-22** Job baru masuk Belum Ditugaskan tanpa penerima dan tidak dihitung pada kapasitas Freelance; penugasan yang valid mengubahnya ke Antre dan memulai timer SLA.
- [ ] **AC-23** Job Antre menjadi Urgen saat waktu sejak `antre_since` mencapai SLA; job menjadi Terlambat saat waktu mencapai atau melewati deadline dan selama statusnya bukan ACC atau Dibatalkan. Kedua penanda tidak saling menggantikan.
- [ ] **AC-24** Setiap pengajuan MintaACC memiliki versi serta daftar tetap dengan sedikitnya satu file; file yang sudah terikat submission terkunci dari edit/delete biasa. ACC menyetujui pengajuan yang sama, Revisi mewajibkan alasan, dan pengajuan berikutnya membuat versi baru.
- [ ] **AC-25** Admin dapat membatalkan job pada status nonterminal sebelum ACC dengan alasan wajib; riwayat dipertahankan, tidak ada fee masuk rekap, dan job dikecualikan dari kapasitas. Pengalihan job mengikuti R-04; job MintaACC harus diputuskan sebelum dialihkan.
- [ ] **AC-26** ACC membekukan referensi versi hasil, fee snapshot, dan penerima rekap saat ACC; edit biasa setelah ACC tidak mengubah ketiganya.
- [ ] **AC-27** Peristiwa status, penugasan/pengalihan, pengajuan, keputusan, dan pembatalan tersimpan dengan waktu serta pelaku dan tidak dapat diedit/dihapus melalui alur produk biasa.
- [ ] **AC-28** Pengguna dapat meminta reset kata sandi melalui email, menyelesaikan reset, lalu masuk dengan kata sandi baru; pendaftaran terbuka tidak memberi akses ke job yang tidak ditugaskan.
- [ ] **AC-29** Mode Demo berjalan dengan data lokal tanpa menulis ke Mode Online; mengosongkan data Demo tidak mengubah akun, job, file, atau thread Online.
- [ ] **AC-30** Operator tepercaya dapat menetapkan Super Admin pertama; selanjutnya Super Admin dapat mengubah role/status akses akun lain melalui aplikasi. Perubahan mencatat UUID target, role/status lama dan baru, pelaku, waktu, dan alasan; role/status tidak dapat diubah oleh pemilik akun.
- [ ] **AC-31** Konfigurasi Supabase Storage mengizinkan setidaknya 1 GiB per objek dan batas bucket `job-files` tidak lebih rendah; backend aplikasi tetap menolak file di atas 1 GiB dan menolak unggahan yang membuat total file aktif, reservation, serta objek yatim pada satu job melebihi 10 GiB, termasuk saat beberapa unggahan berlangsung bersamaan. Storage INSERT hanya menerima path, peran, dan ukuran yang cocok dengan reservation server; metadata file harus cocok dengan ukuran objek aktual.
- [ ] **AC-32** Tugas VPS menjalankan purge harian untuk file saat `now >= uploaded_at + 30 hari`, termasuk hasil ACC; objek diproses pada eksekusi harian pertama setelah memenuhi batas, kegagalan tercatat untuk retry, objek biner dihapus melalui Supabase Storage API, dan metadata submission/riwayat tetap ada.
- [ ] **AC-33** Backup PostgreSQL dan perlindungan objek R2 memenuhi target harian, retensi 7 hari, RPO maksimum 24 jam, dan RTO maksimum 8 jam. Salinan objek berada pada tujuan dan memakai kredensial terpisah dari bucket produksi; penyedia/lokasi serta prosedur restore dipilih dan pemulihan masing-masing diuji sebelum pilot.
- [ ] **AC-34** Jika transfer file gagal atau metadata tidak tersimpan, reservation dilepas dan objek yatim dapat dibersihkan melalui Supabase Storage API tanpa menghapus file lain; objek tersebut tetap masuk hitungan kuota sampai terhapus.
- [ ] **AC-35** Dalam Mode Demo maupun Mode Online, notifikasi pesan baru, Urgen, dan Express tampil di dalam aplikasi; notifikasi browser hanya opsional saat aplikasi terbuka dan izin diberikan. Tidak ada notifikasi latar belakang saat aplikasi ditutup.
- [ ] **AC-36** Tautan WhatsApp menyiapkan draft untuk dikirim pengguna dan tidak mengirim pesan otomatis.
- [ ] **AC-37** Finance tidak dapat membaca tabel job, brief/referensi, file, submission, timeline umum, chat, profil operasional, atau pengaturan umum; laporan finansial hanya tersedia lewat fungsi terbatas dan mutasi job ditolak.
- [ ] **AC-38** Super Admin dapat mengelola role/status akses akun, tetapi perubahan terhadap dirinya sendiri ditolak dan sistem secara atomik mencegah penurunan/nonaktifnya Super Admin aktif terakhir.
- [ ] **AC-39** Akun dengan status akses nonaktif hanya dapat membaca status profil nonaktifnya sendiri, tetapi tidak dapat membaca job, file, chat, atau memakai RPC Threadline; profil serta riwayat bisnis tetap dipertahankan.
- [ ] **AC-40** Super Admin dengan sesi Auth aktif dapat mengundang Admin, Finance, dan Freelance melalui email. Role undangan divalidasi di server, pengguna membuat kata sandi sendiri setelah verifikasi, pendaftaran publik tetap Freelance, dan `service_role` tidak pernah tersedia di browser.
- [ ] **AC-41** Super Admin dapat melihat direktori akun dan audit tindakan role, undangan, keamanan akun, serta pengaturan bersama; entri audit menampilkan target, pelaku, waktu, sebelum/sesudah bila ada, dan alasan.
- [ ] **AC-42** Super Admin dengan sesi Auth aktif dapat membaca data operasional dan menjalankan RPC/endpoint tanpa faktor TOTP; akun nonaktif dan role lain tetap ditolak dari fungsi Super Admin.
- [ ] **AC-43** Rekap Finance menghitung seluruh job Finished tanpa batas 500 baris, membawa saldo sebelumnya, memisahkan `finished_at` dan `paid_at` dalam zona waktu Asia/Jakarta, serta mendukung rincian dan ekspor CSV.
- [ ] **AC-44** Pencatatan pembayaran wajib memiliki referensi, bukti privat, tanggal transfer, dan alokasi job; duplikasi referensi serta alokasi melebihi sisa fee ditolak. Pembatalan memerlukan alasan, tidak menghapus histori, dan seluruh pencatatan/pembatalan/akses bukti/rekening tampil pada log audit.
- [ ] **AC-45** Nomor rekening tersamarkan secara default; pembukaan nomor penuh dicatat dengan pelaku, penerima, dan waktu.

## 9. Keputusan produk

### Disepakati

| ID | Keputusan |
| --- | --- |
| D-01 | Dalam Mode Online, file pekerjaan disimpan privat dan hanya dapat dibuka melalui Supabase Storage oleh pengguna terautentikasi yang berhak mengakses job terkait. |
| D-02 | Dalam Mode Online, backend menjadi penjaga akhir untuk memeriksa kapasitas dan presence sebelum job ditugaskan atau dialihkan. Mode Demo memeriksa aturan ini pada UI/state lokal. |
| D-03 | Pemilik akun dapat mengubah nama kerja; job dan thread tetap terhubung setelah perubahan. |
| D-04 | Format unggahan adalah PDF, CDR, PNG, dan JPEG. Jumlah file tidak dibatasi; ukuran maksimum 1 GiB per file dan total 10 GiB untuk biner aktif serta unggahan yang sedang berlangsung pada satu job. File yang sudah dipurge tidak lagi dihitung. Batas teknis Supabase Storage dan backend Cloudflare R2 tetap berlaku. |
| D-05 | Dalam Mode Online, perubahan berdasarkan revisi job yang sudah usang ditolak; pengguna harus memuat ulang sebelum mengirim perubahan baru. |
| D-06 | Fee job menjadi kewajiban pada `Finished`; bukti dan nominal transfer aktual dicatat terpisah. Rekap bulanan memakai tanggal selesai untuk fee dan tanggal transfer untuk realisasi kas. |
| D-07 | Freelance hanya dapat mengubah status/timeline dan mengunggah file hasil baru. Pengubahan/penghapusan file yang belum terikat submission, brief, deadline, fee, serta penerima dikelola Admin. File yang sudah diikat ke submission terkunci; objek biner tetap mengikuti retensi 30 hari. |
| D-08 | Mode Online mendukung lebih dari satu akun Admin. |
| D-09 | Dalam Mode Online, SLA urgensi adalah satu nilai bersama untuk semua perangkat; nilai awalnya 3 jam. |
| D-10 | Admin dapat mengubah SLA urgensi; nilai baru tetap berlaku sama untuk semua perangkat Mode Online. |
| D-11 | Supabase self-hosted menangani PostgreSQL, Auth, Storage API, dan Realtime. Cloudflare R2 menjadi backend S3-compatible untuk objek Supabase Storage; aplikasi tetap menggunakan Supabase SDK/API dan RLS. Bucket Supabase `job-files` bersifat privat dan metadata objek dikelola Storage di PostgreSQL. |
| D-12 | Job baru masuk ke status Belum Ditugaskan. Hanya job yang sudah ditugaskan dan berstatus Antre, Dikerjakan, Preview, MintaACC, Revisi, atau ACC yang dihitung dalam kapasitas. |
| D-13 | Urgen mengukur waktu antre sejak `antre_since`; Terlambat mengukur deadline. Terlambat berlaku saat waktu mencapai atau melewati deadline kecuali status ACC atau Dibatalkan, dan tidak mengubah status job. |
| D-14 | MintaACC membuat pengajuan hasil berversi yang memuat sedikitnya satu file dengan daftar tetap. ACC merujuk pengajuan persis tersebut; permintaan Revisi mencatat alasan dan pengajuan berikutnya menjadi versi baru. File dan relasi yang telah terikat submission tidak dapat diedit/dihapus melalui alur biasa; objek biner tetap mengikuti retensi 30 hari sejak upload. |
| D-15 | Admin membatalkan job dengan alasan wajib. Job Dibatalkan terminal dan dikecualikan dari kapasitas/rekap fee. Penghapusan permanen hanya untuk job Belum Ditugaskan tanpa aktivitas dan tanpa file. |
| D-16 | Pengalihan job Antre mempertahankan status dan mengulang timer antre; pengalihan job Dikerjakan/Revisi memerlukan alasan dan mempertahankan status serta riwayat. MintaACC harus diputuskan sebelum pengalihan; ACC/Dibatalkan tidak dapat dialihkan. |
| D-17 | ACC membekukan versi hasil, fee snapshot, dan penerima rekap untuk job tersebut. Retensi 30 hari sejak upload berlaku untuk semua file, termasuk file ACC. |
| D-18 | Pendaftaran terbuka untuk siapa pun. Akun baru berperan Freelance dan pending; verifikasi email wajib sebelum Admin/Super Admin dapat meninjau, lalu persetujuan diperlukan sebelum fitur operasional dibuka. Pengguna terverifikasi dapat masuk untuk melihat status pendaftaran. Pendaftaran tidak memberikan akses role lain, job/file/thread pengguna lain, atau daftar profil freelance; akun tidak dapat menaikkan role/status akses sendiri. |
| D-19 | Login Mode Online menggunakan email dan kata sandi. Pengguna dapat meminta reset kata sandi melalui email dan keluar untuk mengakhiri sesi pada perangkatnya. |
| D-20 | Ketentuan status, alasan, dan dampak pembatalan mengikuti aturan kanonis R-13 dan kriteria AC-25. |
| D-21 | Penerima dan nilai fee dibekukan saat ACC; kewajiban pembayaran baru timbul saat job menjadi Finished sesuai R-09. |
| D-22 | Fee dicatat dalam Rupiah bilangan bulat (tanpa desimal); rekap menampilkan format Rp id-ID. |
| D-23 | Target operasional Admin memeriksa MintaACC adalah 1×24 jam. UI menampilkan lama menunggu dan menandai yang lewat target; pengingat otomatis/scheduler tetap di luar MVP. |
| D-24 | Job ACC terkunci permanen; koreksi hasil setelah ACC dilakukan lewat job baru (tombol "job lanjutan" membawa referensi job asal). |
| D-25 | Zona waktu bisnis untuk deadline adalah Asia/Jakarta (resmi, bukan lagi asumsi). |
| D-26 | Batas job aktif per freelance adalah satu angka global (awal 4, rentang 1–20) yang dapat diubah Admin di Pengaturan; backend memeriksanya atomik saat penugasan/pengalihan. |
| D-27 | Urutan dan batas role mengikuti R-16. Operator tepercaya menetapkan Super Admin pertama; sesudahnya hanya Super Admin dapat mengelola role/status akses akun lain melalui aplikasi. Finance memiliki akses finansial terbatas dan tercatat; Admin mempertahankan akses operasional serta rekap fee. Perubahan dicatat dan Super Admin aktif terakhir dilindungi. |
| D-28 | Finance mencatat transfer manual beserta referensi, bukti privat, dan alokasi ke job; pembatalan membutuhkan alasan dan meninggalkan histori audit. Sistem tidak menginisiasi transfer bank. Fee diakui saat `Finished`, sedangkan transfer diakui pada `paid_at`; laporan menggunakan Asia/Jakarta. |

### Keputusan yang masih perlu ditetapkan

- Keputusan apakah job lama berstatus Belum Ditugaskan memerlukan pengingat otomatis. Pengingat atau scheduler produk belum termasuk MVP sampai diputuskan.

### Target operasional pilot yang disepakati

- Purge file berjalan otomatis setiap hari di server VPS; setiap file menjadi layak dihapus tepat saat `now >= uploaded_at + 30 hari` dan diproses pada eksekusi harian berikutnya.
- Backup PostgreSQL dan perlindungan objek R2 berjalan harian dengan retensi salinan 7 hari. Target pemulihan untuk keduanya adalah RPO maksimum 24 jam dan RTO maksimum 8 jam. Salinan objek harus berada pada tujuan dan kredensial terpisah dari bucket produksi; penyedia/lokasi serta prosedur restore wajib dipilih dan diuji sebelum pilot.

## 10. Dokumen terkait

- [TECHNICAL-CONTRACT.md](TECHNICAL-CONTRACT.md) — rincian integrasi dan perlindungan data.
- [OPERATIONS.md](OPERATIONS.md) — prasyarat setup dan uji pilot.
- [GLOSSARY.md](GLOSSARY.md) — arti istilah domain.

Catatan: aplikasi Next.js dan migrasi Supabase tersedia di `threadline/`. Kriteria teknis tetap belum lulus sampai diuji terhadap deployment dan alur lintas perangkat.
