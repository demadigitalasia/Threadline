import { NextResponse } from "next/server";
import { requireSuperAdmin, createServiceRoleClient, hasSameOrigin } from "@/lib/supabase/super-admin";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function PATCH(
  request: Request,
  context: { params: Promise<{ profileId: string }> },
) {
  if (!hasSameOrigin(request)) return NextResponse.json({ error: "Permintaan lintas situs ditolak." }, { status: 403 });
  const access = await requireSuperAdmin();
  if (!access) return NextResponse.json({ error: "Akses Super Admin diperlukan." }, { status: 403 });

  const { profileId } = await context.params;
  if (!UUID_PATTERN.test(profileId)) return NextResponse.json({ error: "ID akun tidak valid." }, { status: 400 });

  let input: { name?: unknown; whatsapp?: unknown; email?: unknown; password?: unknown; confirmPassword?: unknown; reason?: unknown };
  try {
    input = await request.json();
  } catch {
    return NextResponse.json({ error: "Data akun tidak valid." }, { status: 400 });
  }
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    return NextResponse.json({ error: "Data akun tidak valid." }, { status: 400 });
  }

  const name = typeof input.name === "string" ? input.name.trim() : "";
  const whatsapp = typeof input.whatsapp === "string" ? input.whatsapp.trim() : "";
  const email = typeof input.email === "string" ? input.email.trim().toLowerCase() : "";
  const password = typeof input.password === "string" ? input.password : "";
  const confirmPassword = typeof input.confirmPassword === "string" ? input.confirmPassword : "";
  const reason = typeof input.reason === "string" ? input.reason.trim() : "";

  if (name.length < 3 || name.length > 100) return NextResponse.json({ error: "Nama harus terdiri dari 3–100 karakter." }, { status: 400 });
  if (whatsapp && !/^\+?[0-9(). -]{8,24}$/.test(whatsapp)) return NextResponse.json({ error: "Nomor WhatsApp tidak valid." }, { status: 400 });
  if (!/^\S+@\S+\.\S+$/.test(email) || email.length > 254) return NextResponse.json({ error: "Email tidak valid." }, { status: 400 });
  if (password && (password.length < 8 || password.length > 128)) return NextResponse.json({ error: "Kata sandi baru harus berisi 8–128 karakter." }, { status: 400 });
  if (password && password !== confirmPassword) return NextResponse.json({ error: "Konfirmasi kata sandi tidak sama." }, { status: 400 });
  if (!reason || reason.length > 500) return NextResponse.json({ error: "Alasan perubahan wajib diisi (maksimal 500 karakter)." }, { status: 400 });

  const admin = createServiceRoleClient();
  if (!admin) return NextResponse.json({ error: "Fitur edit akun belum dikonfigurasi di server." }, { status: 503 });

  const [{ data: authResult, error: authReadError }, { data: profile, error: profileReadError }, { data: duplicateName }] = await Promise.all([
    admin.auth.admin.getUserById(profileId),
    admin.from("profiles").select("id").eq("id", profileId).maybeSingle(),
    admin.from("profiles").select("id").eq("name", name).neq("id", profileId).maybeSingle(),
  ]);
  const target = authResult.user;
  if (authReadError || profileReadError || !target || !profile) {
    return NextResponse.json({ error: "Akun tidak ditemukan." }, { status: 404 });
  }
  if (duplicateName) return NextResponse.json({ error: "Nama tersebut sudah digunakan akun lain." }, { status: 409 });
  if (!target.email) return NextResponse.json({ error: "Akun belum memiliki email login." }, { status: 409 });

  const emailChanged = target.email.toLowerCase() !== email;
  const passwordChanged = password.length > 0;
  const authAttributes: { email?: string; email_confirm?: boolean; password?: string } = {};
  if (emailChanged) {
    authAttributes.email = email;
    authAttributes.email_confirm = true;
  }
  if (passwordChanged) authAttributes.password = password;

  if (emailChanged || passwordChanged) {
    const { error } = await admin.auth.admin.updateUserById(profileId, authAttributes);
    if (error) {
      if (/already (registered|exists)|already been registered|duplicate/i.test(error.message)) {
        return NextResponse.json({ error: "Email tersebut sudah dipakai akun lain." }, { status: 409 });
      }
      return NextResponse.json({ error: "Perubahan email atau kata sandi gagal disimpan." }, { status: 400 });
    }
  }

  const { data: updateResult, error: updateError } = await admin.rpc("update_managed_account", {
    p_target: profileId,
    p_actor: access.user.id,
    p_name: name,
    p_whatsapp: whatsapp,
    p_old_email: target.email,
    p_email_changed: emailChanged,
    p_password_changed: passwordChanged,
    p_reason: reason,
  });
  const update = updateResult as { ok?: boolean; error?: string; changed?: boolean } | null;
  if (updateError || !update?.ok) {
    const detail = update?.error ?? "pencatatan profil gagal";
    return NextResponse.json({
      error: emailChanged || passwordChanged
        ? `Email/kata sandi sudah diperbarui, tetapi data profil belum tersimpan (${detail}). Coba simpan kembali.`
        : detail,
      partial: emailChanged || passwordChanged,
    }, { status: 500 });
  }

  return NextResponse.json({ ok: true, message: update.changed || emailChanged || passwordChanged ? "Data akun berhasil diperbarui dan dicatat." : "Tidak ada perubahan pada akun." });
}
