import { NextResponse } from "next/server";
import { createClient as createSupabaseClient } from "@supabase/supabase-js";
import { requireSuperAdmin, createServiceRoleClient, getAuthRedirectUrl, hasSameOrigin } from "@/lib/supabase/super-admin";

type Action = "password_reset" | "resend_verification" | "revoke_sessions";

export async function POST(
  request: Request,
  context: { params: Promise<{ profileId: string }> },
) {
  if (!hasSameOrigin(request)) return NextResponse.json({ error: "Permintaan lintas situs ditolak." }, { status: 403 });
  const access = await requireSuperAdmin();
  if (!access) return NextResponse.json({ error: "Akses Super Admin diperlukan." }, { status: 403 });
  const { profileId } = await context.params;
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(profileId)) {
    return NextResponse.json({ error: "ID akun tidak valid." }, { status: 400 });
  }

  let input: { action?: unknown; reason?: unknown };
  try {
    input = await request.json();
  } catch {
    return NextResponse.json({ error: "Data tindakan tidak valid." }, { status: 400 });
  }
  const action = input.action as Action;
  const reason = typeof input.reason === "string" ? input.reason.trim() : "";
  if (!["password_reset", "resend_verification", "revoke_sessions"].includes(action)) {
    return NextResponse.json({ error: "Tindakan akun tidak dikenal." }, { status: 400 });
  }
  if (!reason) return NextResponse.json({ error: "Alasan tindakan wajib diisi." }, { status: 400 });

  const admin = createServiceRoleClient();
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const publishableKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  if (!admin || !url || !publishableKey) {
    return NextResponse.json({ error: "Aksi akun belum dikonfigurasi di environment server." }, { status: 503 });
  }
  const { data: userResult, error: userError } = await admin.auth.admin.getUserById(profileId);
  const target = userResult.user;
  if (userError || !target?.email) return NextResponse.json({ error: "Akun tidak ditemukan atau tidak memiliki email." }, { status: 404 });

  let eventType: string;
  if (action === "password_reset") {
    const publicClient = createSupabaseClient(url, publishableKey, {
      auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
    });
    const { error } = await publicClient.auth.resetPasswordForEmail(target.email, {
      redirectTo: getAuthRedirectUrl("/reset-password", request.url),
    });
    if (error) return NextResponse.json({ error: error.message }, { status: 502 });
    eventType = "password_reset_email_sent";
  } else if (action === "resend_verification") {
    if (target.email_confirmed_at) return NextResponse.json({ error: "Email akun ini sudah terverifikasi." }, { status: 409 });
    const publicClient = createSupabaseClient(url, publishableKey, {
      auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
    });
    const { error } = await publicClient.auth.resend({
      type: "signup",
      email: target.email,
      options: { emailRedirectTo: getAuthRedirectUrl("/verifikasi-email", request.url) },
    });
    if (error) return NextResponse.json({ error: error.message }, { status: 502 });
    eventType = "verification_email_sent";
  } else {
    const { error } = await admin.auth.admin.signOut(profileId, "global");
    if (error) return NextResponse.json({ error: error.message }, { status: 502 });
    eventType = "sessions_revoked";
  }

  const { data: auditResult, error: auditError } = await admin.rpc("record_super_admin_user_action", {
    p_target: profileId,
    p_actor: access.user.id,
    p_event_type: eventType,
    p_reason: reason,
  });
  const audit = auditResult as { ok?: boolean } | null;
  if (auditError || !audit?.ok) {
    return NextResponse.json({ error: "Tindakan berhasil, tetapi pencatatan audit gagal. Hubungi operator sistem." }, { status: 500 });
  }
  return NextResponse.json({ ok: true, message: "Tindakan akun berhasil." });
}
