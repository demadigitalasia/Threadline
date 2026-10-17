import { NextResponse } from "next/server";
import { createServiceRoleClient, hasSameOrigin, requireSuperAdmin } from "@/lib/supabase/super-admin";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function DELETE(
  request: Request,
  context: { params: Promise<{ profileId: string }> },
) {
  if (!hasSameOrigin(request)) return NextResponse.json({ error: "Permintaan lintas situs ditolak." }, { status: 403 });
  const access = await requireSuperAdmin();
  if (!access) return NextResponse.json({ error: "Akses Super Admin diperlukan." }, { status: 403 });
  const { data: isSuperAdmin, error: mfaError } = await access.supabase.rpc("is_super_admin");
  if (mfaError || !isSuperAdmin) {
    return NextResponse.json({ error: "Akses Super Admin dengan verifikasi MFA diperlukan." }, { status: 403 });
  }

  const { profileId } = await context.params;
  if (!UUID_PATTERN.test(profileId)) return NextResponse.json({ error: "ID akun tidak valid." }, { status: 400 });
  if (profileId === access.user.id) return NextResponse.json({ error: "Anda tidak dapat menghapus akun yang sedang digunakan." }, { status: 409 });

  let input: unknown;
  try {
    input = await request.json();
  } catch {
    return NextResponse.json({ error: "Konfirmasi penghapusan tidak valid." }, { status: 400 });
  }
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    return NextResponse.json({ error: "Konfirmasi penghapusan tidak valid." }, { status: 400 });
  }
  const payload = input as { reason?: unknown; confirmation?: unknown };
  const reason = typeof payload.reason === "string" ? payload.reason.trim() : "";
  const confirmation = typeof payload.confirmation === "string" ? payload.confirmation.trim().toLowerCase() : "";
  if (!reason || reason.length > 500) return NextResponse.json({ error: "Alasan penghapusan wajib diisi (maksimal 500 karakter)." }, { status: 400 });

  const admin = createServiceRoleClient();
  if (!admin) return NextResponse.json({ error: "Fitur penghapusan akun belum dikonfigurasi di server." }, { status: 503 });

  const [{ data: authResult, error: authReadError }, { data: profile, error: profileReadError }] = await Promise.all([
    admin.auth.admin.getUserById(profileId),
    admin.from("profiles").select("id,name,role,avatar_path").eq("id", profileId).maybeSingle(),
  ]);
  const target = authResult.user;
  if (authReadError || profileReadError || !target?.email || !profile) {
    return NextResponse.json({ error: "Akun tidak ditemukan." }, { status: 404 });
  }
  if (profile.role === "super_admin") return NextResponse.json({ error: "Akun Super Admin dilindungi dan tidak dapat dihapus dari menu ini." }, { status: 403 });
  if (confirmation !== target.email.toLowerCase()) {
    return NextResponse.json({ error: "Ketik email akun dengan benar untuk mengonfirmasi penghapusan." }, { status: 400 });
  }

  const { data: approvedJob, error: jobCheckError } = await admin
    .from("jobs")
    .select("id")
    .eq("approved_for_profile_id", profileId)
    .limit(1)
    .maybeSingle();
  if (jobCheckError) return NextResponse.json({ error: "Keterkaitan akun dengan pekerjaan belum dapat diperiksa." }, { status: 503 });
  if (approvedJob) {
    return NextResponse.json({ error: "Akun masih tercatat pada pekerjaan yang sudah ACC. Nonaktifkan akses akun agar riwayat pekerjaan tetap utuh." }, { status: 409 });
  }

  const { error: deletionError } = await admin.auth.admin.deleteUser(profileId);
  if (deletionError) {
    const detail = deletionError.message.trim().slice(0, 240);
    return NextResponse.json({
      error: detail
        ? `Supabase menolak penghapusan akun: ${detail}`
        : "Akun tidak dapat dihapus karena masih dipakai oleh data pekerjaan atau riwayat sistem.",
    }, { status: 409 });
  }

  let photoCleanupFailed = false;
  if (profile.avatar_path) {
    const { error } = await admin.storage.from("profile-photos").remove([profile.avatar_path]);
    photoCleanupFailed = Boolean(error);
  }

  const { data: auditResult, error: auditError } = await admin.rpc("record_managed_account_deletion", {
    p_target: profileId,
    p_actor: access.user.id,
    p_target_label: profile.name,
    p_target_email: target.email,
    p_reason: reason,
  });
  const audit = auditResult as { ok?: boolean; error?: string } | null;
  if (auditError || !audit?.ok) {
    const detail = audit?.error ?? auditError?.message;
    return NextResponse.json({
      error: detail
        ? `Akun berhasil dihapus, tetapi pencatatan audit gagal: ${detail.slice(0, 240)}`
        : "Akun berhasil dihapus, tetapi pencatatan riwayat keamanan gagal. Hubungi Super Admin.",
      partial: true,
    }, { status: 500 });
  }

  return NextResponse.json({
    ok: true,
    message: photoCleanupFailed
      ? "Akun dihapus dan dicatat, tetapi foto profil belum berhasil dibersihkan."
      : "Akun berhasil dihapus dan dicatat pada riwayat keamanan.",
  });
}
