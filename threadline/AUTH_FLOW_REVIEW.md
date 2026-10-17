# Laporan Review Alur Autentikasi

**Tanggal:** 17 Oktober 2026  
**Cakupan:** Login, Register, Lupa Password, Reset Password, verifikasi email, sesi Supabase, serta konfigurasi Auth lokal.

## Ringkasan

Alur dasar tersedia, dan temuan pada source lokal sudah ditindaklanjuti. Perubahan menyelaraskan verifikasi email dan kata sandi minimum, menstandarkan callback, menutup form reset saat tautan tidak valid, serta memberi respons netral untuk status akun dan kegagalan permintaan.

Temuan awal di bawah berasal dari pembacaan kode dan konfigurasi lokal. Bagian “Tindak lanjut” mencatat perubahan yang sudah dibuat. Saya tidak menjalankan alur di browser atau menguji pengiriman email. Konfigurasi Supabase produksi tidak tersedia untuk diperiksa, sehingga pengaturan Auth dan redirect di dashboard produksi masih perlu dicocokkan.

Nomor baris pada rujukan temuan mengacu pada source sebelum tindak lanjut.

## Temuan

### 1. Verifikasi email tidak wajib pada konfigurasi lokal — Tinggi bila verifikasi adalah syarat akses

`supabase/config.toml` menetapkan `enable_confirmations = false`, sementara halaman daftar mengatakan akun wajib diverifikasi. Kode daftar mengarahkan pengguna langsung ke `/dashboard` bila Supabase mengembalikan sesi dari `signUp`; kondisi ini lazim terjadi saat konfirmasi email dinonaktifkan. Akibatnya, perilaku lokal bertentangan dengan alur yang dijanjikan.

**Rujukan:** `supabase/config.toml:219-228`; `src/app/register/page.tsx:31-44`.

**Rekomendasi:** Aktifkan konfirmasi email pada konfigurasi lokal dan produksi jika verifikasi memang diwajibkan. Pastikan SMTP/template email dan callback sudah siap. Jika verifikasi tidak wajib, ubah teks dan alur pendaftaran agar tidak menjanjikannya.

### 2. Daftar redirect lokal tidak sejalan dengan alamat callback aplikasi — Sedang

Konfigurasi lokal memakai `site_url = "http://127.0.0.1:3000"`, tetapi daftar tambahan berisi `https://127.0.0.1:3000`. Register dan reset membentuk `redirectTo` dari `window.location.origin`. Saat aplikasi dibuka melalui `http://localhost:3000` atau alamat lain yang belum diizinkan, Supabase dapat menolak redirect email.

**Rujukan:** `supabase/config.toml:157-163`; `src/app/register/page.tsx:34`; `src/app/lupa-password/page.tsx:24-26`.

**Rekomendasi:** Tetapkan satu URL kanonis per lingkungan, daftarkan URL callback lokal dan produksi secara tepat di Supabase, lalu gunakan konfigurasi URL aplikasi yang eksplisit untuk callback.

### 3. Gangguan jaringan dapat membuat tombol terus dalam status sibuk — Sedang

Permintaan Auth memakai `.then(...)` tanpa penanganan penolakan promise dan tanpa `finally`. Jika permintaan gagal sebelum menghasilkan objek `{ error }`—misalnya koneksi terputus—`busy` tidak dikembalikan ke `false` dan pengguna tidak mendapat pesan yang bisa ditindaklanjuti. Pola ini ada pada login, daftar, permintaan reset, penyimpanan kata sandi, dan kirim ulang verifikasi.

**Rujukan:** `src/app/login/page.tsx:74-88,119-123`; `src/app/register/page.tsx:30-45`; `src/app/lupa-password/page.tsx:23-30`; `src/app/reset-password/page.tsx:42-48`.

**Rekomendasi:** Tangani setiap aksi dengan `try/catch/finally`, pulihkan status sibuk di semua jalur, tampilkan pesan jaringan generik, dan tambahkan status sibuk tersendiri untuk kirim ulang email.

### 4. Form reset tetap aktif ketika kode reset gagal ditukar — Sedang

Jika `exchangeCodeForSession` gagal, halaman menyimpan pesan kedaluwarsa tetapi tetap mengatur `ready = true` dan merender form. Saat pengguna mengirim form, pesan awal dihapus lalu `updateUser` gagal karena tidak ada sesi reset yang sah. Ini membuat pengguna melewati langkah yang tidak mungkin berhasil sebelum meminta tautan baru.

**Rujukan:** `src/app/reset-password/page.tsx:19-32,37-48`.

**Rekomendasi:** Pisahkan status `valid`, `invalid/expired`, dan `processing`. Jangan tampilkan form kata sandi bila penukaran kode gagal; tampilkan tindakan untuk meminta tautan baru dan pesan yang menjelaskan bahwa tautan harus dibuka di browser yang memiliki sesi/verifier.

### 5. Login membedakan akun yang belum diverifikasi dari kredensial salah — Sedang

Login mengubah respons Auth yang memuat `confirm` atau `verif` menjadi pesan khusus dan menampilkan tombol kirim ulang. Ini mengungkap bahwa alamat email tertentu sudah terdaftar tetapi belum diverifikasi kepada orang yang mencoba masuk.

**Rujukan:** `src/app/login/page.tsx:77-83,113-127`.

**Rekomendasi:** Gunakan pesan publik yang tidak membedakan status akun. Kirim ulang dapat tetap tersedia dengan respons netral yang sama, lalu catat detail diagnostik hanya di sisi yang tidak terlihat oleh pengguna.

### 6. Kirim ulang verifikasi tidak menetapkan callback halaman verifikasi — Rendah

Pendaftaran awal menetapkan `emailRedirectTo` ke `/verifikasi-email`, tetapi aksi kirim ulang hanya memanggil `resend({ type: "signup", email })`. Tautan yang dikirim ulang akan memakai URL Auth default, sehingga pengguna mungkin mendarat di halaman root/login alih-alih melihat status verifikasi.

**Rujukan:** `src/app/register/page.tsx:34`; `src/app/login/page.tsx:119-123`; `src/app/page.tsx:5-9`.

**Rekomendasi:** Tetapkan callback yang sama saat kirim ulang dan pastikan halaman callback menukar kode lalu menampilkan status berhasil/gagal.

### 7. Kebijakan kata sandi hanya meminta enam karakter — Sedang

Validasi UI dan konfigurasi Supabase sama-sama menerima enam karakter (`password_requirements` juga kosong). Ini mempermudah penggunaan kata sandi yang lemah untuk aplikasi dengan pendaftaran terbuka.

**Rujukan:** `supabase/config.toml:181-185`; `src/app/register/page.tsx:28,53-55`; `src/app/reset-password/page.tsx:40,51-52`.

**Rekomendasi:** Naikkan batas minimum menjadi setidaknya delapan karakter—atau lebih sesuai kebijakan produk—dan samakan validasi UI dengan kebijakan server. Utamakan panjang kata sandi dan dukung pengelola kata sandi.

### 8. Halaman verifikasi menganggap sesi yang sudah ada sebagai bukti verifikasi — Rendah

Jika URL callback tidak memiliki `code`, halaman menunggu lalu menganggap `getSession()` yang menemukan sesi sebagai verifikasi berhasil. Sesi aktif yang sudah ada tidak membuktikan bahwa tautan email saat ini valid atau bahwa email baru saja diverifikasi.

**Rujukan:** `src/app/verifikasi-email/page.tsx:22-30`.

**Rekomendasi:** Tampilkan sukses hanya setelah callback Auth berhasil diproses atau status email terverifikasi dikonfirmasi secara eksplisit. Untuk callback tanpa token, tampilkan instruksi atau kegagalan, bukan sukses berdasarkan sesi umum.

## Urutan perbaikan yang disarankan

1. Selaraskan kewajiban verifikasi email dengan konfigurasi lokal dan produksi.
2. Benahi daftar URL redirect dan pastikan callback daftar, kirim ulang, serta reset konsisten.
3. Buat penanganan gagal jaringan dan status sibuk konsisten di semua aksi Auth.
4. Kunci form reset saat callback tidak valid dan buat pesan pemulihan yang jelas.
5. Kurangi pengungkapan status email dan tingkatkan kebijakan kata sandi.

## Tindak lanjut

- **Sudah diterapkan secara lokal:** konfirmasi email aktif; URL callback verifikasi dan reset diizinkan untuk `localhost` dan `127.0.0.1`; batas kata sandi minimum naik ke delapan karakter.
- **Sudah diterapkan di alur UI:** callback daftar dan kirim ulang menuju halaman verifikasi; reset memakai URL callback bersama; kegagalan jaringan mengembalikan status sibuk dan menampilkan pesan yang aman; error login/daftar/reset tidak mengungkap detail status akun.
- **Sudah diterapkan di callback:** kode PKCE ditukar satu kali meski efek React diulang; reset hanya membuka form setelah sesi pemulihan cocok dengan token callback; halaman verifikasi hanya sukses setelah callback valid dan email terkonfirmasi.
- **Masih perlu dilakukan di Supabase produksi:** aktifkan email confirmation, set minimum password delapan karakter, atur `Site URL` dan allowlist redirect untuk domain publik, lalu uji kirim email verifikasi, kirim ulang, dan reset.
- **Belum diverifikasi:** alur browser, penerimaan email, serta lint/build/test tidak dijalankan.

## Batas review

Ini adalah review dan tindak lanjut pada sumber lokal. Saya tidak memiliki akses ke pengaturan Supabase produksi dan tidak mengirim email percobaan atau menjalankan browser maupun pengujian. Skill `mattpocock-skills:code-review` menggunakan diff dari titik Git tertentu; folder proyek ini tidak memiliki metadata Git dan tidak ada titik pembanding atau spesifikasi perubahan, sehingga laporan ini bukan review diff dua sumbu dari skill tersebut.
