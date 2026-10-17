# Laporan Review Desain Halaman Autentikasi

Tanggal: 17 Oktober 2026  
Halaman: Login (`/login`), Register (`/register`), dan Lupa Password (`/lupa-password`)  
Basis pemeriksaan: tampilan aktual di browser pada desktop 1624 × 894 px dan komponen/style terkait. Ini adalah review presentasi visual dan microcopy; alur submit tidak dijalankan.

Status tindak lanjut: copy dan pesan sukses Lupa Password, catatan kaki kontekstual, jarak dan label Register, placeholder email, serta breakpoint Login sudah diterapkan setelah review. Variasi logo dipertahankan untuk kontras pada latar berbeda; tombol daftar di Login tetap lebih menonjol daripada tautan kembali karena merupakan tindakan alternatif utama.

Copy autentikasi dan metadata aplikasi juga sudah diperbarui agar memosisikan Threadline sebagai ruang kerja kolaborasi freelancer lintas bidang, bukan khusus pekerjaan jersey.

## Deskripsi singkat Threadline

> Platform kolaborasi freelancer dan tim untuk mengelola proyek, tugas, revisi, persetujuan, dan fee.

## Ringkasan

Ketiga halaman sudah memiliki identitas visual yang jelas: latar lavender, kartu putih transparan, sudut membulat, dan tombol utama bergradasi indigo–ungu. Login paling kuat secara visual karena panel kiri menjelaskan manfaat produk, sementara Register dan Lupa Password tetap fokus pada tugasnya.

Perbaikan yang paling berdampak adalah mengoreksi teks pada halaman Lupa Password yang terdengar seolah tautan sudah dikirim sebelum formulir dikirim, membuat catatan verifikasi sesuai konteks tiap halaman, serta melonggarkan label dan jarak antar-field di Register. Ada juga potensi kepadatan di breakpoint tablet yang perlu dicek pada viewport sempit.

## Temuan per halaman

### Login

**Yang sudah baik**

- Panel kiri membangun konteks produk dengan tiga manfaat yang mudah dipindai.
- Judul, deskripsi, field, tautan “Lupa?”, dan tombol utama tersusun dalam urutan yang jelas.
- Tombol “Buat akun Freelance baru” terlihat sebagai tindakan sekunder yang mudah ditemukan.
- Panel kiri dan form kanan memakai warna serta bentuk yang konsisten dengan identitas aplikasi.

**Peluang perbaikan**

- Form dan panel informasi mulai berbagi ruang pada breakpoint `md`. Pada rentang tablet, teks panel dan form berpotensi terasa sempit; perilaku pada lebar ini perlu diverifikasi sebelum menetapkan breakpoint final.
- Logo pada panel login tampil tanpa bidang gelap, sedangkan pada halaman ber-card logo berada di dalam bidang indigo. Perbedaan ini masih terbaca, tetapi sebaiknya ditetapkan sebagai varian brand yang disengaja.

### Register

**Yang sudah baik**

- Satu kolom membuat urutan nama, email, kata sandi, konfirmasi, lalu aksi daftar mudah diikuti.
- Label “Nama kerja” menjelaskan bahwa nama tersebut akan terlihat pada job dan chat.
- CTA utama memiliki hierarki visual yang kuat.

**Peluang perbaikan**

- Label menggunakan ukuran kecil dan form memakai jarak `space-y-2`; empat field tampak rapat saat dilihat sekilas. Tambahkan jarak label–input dan jarak antarkelompok field agar form lebih mudah dipindai, terutama pada layar kecil.
- Keterangan verifikasi email muncul di subtitle dan sekali lagi pada catatan kaki. Satu penjelasan yang ringkas sudah cukup.
- Tautan kembali ke login tampil sebagai teks, sementara tautan buat akun di Login berupa tombol outline penuh. Samakan pola visual navigasi sekunder atau tetapkan alasan hierarkinya.

### Lupa Password

**Yang sudah baik**

- Halaman ringkas dan fokus pada satu tindakan utama.
- Tombol kirim dan tautan kembali masuk mudah ditemukan.

**Temuan yang perlu diperbaiki**

- Subtitle “Tautan reset dikirim via email.” menyiratkan email sudah terkirim, padahal halaman masih meminta alamat email. Gunakan instruksi sebelum submit, misalnya “Masukkan email akun Anda untuk menerima tautan reset.”
- Catatan kaki verifikasi akun baru tidak relevan pada proses reset password dan membuat bagian bawah kartu terasa seperti informasi yang tertinggal dari halaman Register.
- Field email tidak menampilkan contoh format, tidak seperti field email pada Login/Register. Tambahkan placeholder yang konsisten, misalnya `nama@contoh.id`.
- Setelah form dikirim, tampilkan petunjuk tindak lanjut yang jelas: periksa kotak masuk dan folder spam/promosi. Pertahankan kalimat netral agar tidak mengungkap apakah alamat email terdaftar.

## Rekomendasi berprioritas

| Prioritas | Rekomendasi | Dampak |
| --- | --- | --- |
| P1 | Ubah subtitle Lupa Password menjadi instruksi sebelum pengiriman; sediakan pesan sukses yang menjelaskan langkah berikutnya. | Menghilangkan kesan bahwa proses sudah selesai dan membuat keadaan halaman jelas. |
| P1 | Jadikan catatan kaki autentikasi kontekstual: pertahankan informasi verifikasi bila membantu Login, hilangkan duplikasi di Register, dan jangan tampilkan di Lupa Password. | Mengurangi informasi berulang atau tidak relevan. |
| P2 | Longgarkan layout Register: tambah jarak antar-field, jarak label ke input, dan pertimbangkan label sedikit lebih besar. | Memudahkan pemindaian dan mengurangi tampilan form yang padat. |
| P2 | Periksa layout Login pada lebar tablet sekitar 768–1023 px. Jika dua kolom terlalu sempit, pindahkan aktivasi split ke breakpoint yang lebih lebar. | Menjaga proporsi panel dan form sebelum masuk ke layout desktop penuh. |
| P3 | Selaraskan detail brand dan navigasi sekunder antarhalaman; tambahkan placeholder email yang konsisten di Lupa Password. | Membuat ketiga halaman terasa sebagai satu sistem desain yang utuh. |

## Referensi implementasi

- Shell, logo, catatan kaki, breakpoint, dan ukuran form: [`src/components/auth-shell.tsx`](src/components/auth-shell.tsx)
- Halaman Login: [`src/app/login/page.tsx`](src/app/login/page.tsx)
- Halaman Register: [`src/app/register/page.tsx`](src/app/register/page.tsx)
- Halaman Lupa Password: [`src/app/lupa-password/page.tsx`](src/app/lupa-password/page.tsx)
- Warna, kartu, tombol, dan latar auth: [`src/app/globals.css`](src/app/globals.css)

## Batas pemeriksaan

Screenshot aktual saat review diambil pada desktop 1624 × 894 px. Viewport tablet dan ponsel tidak diubah dalam browser untuk review ini; catatan responsif di atas adalah risiko yang terlihat dari breakpoint dan susunan class, bukan temuan hasil screenshot mobile. Perubahan yang diterapkan setelah review belum diperiksa ulang melalui screenshot tablet atau ponsel.
