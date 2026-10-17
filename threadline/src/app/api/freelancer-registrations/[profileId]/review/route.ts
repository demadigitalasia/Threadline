import { NextResponse } from "next/server";
import { createServiceRoleClient, hasSameOrigin, requireRegistrationReviewer } from "@/lib/supabase/super-admin";

export async function POST(
  request: Request,
  context: { params: Promise<{ profileId: string }> },
) {
  if (!hasSameOrigin(request)) return NextResponse.json({ error: "Permintaan lintas situs ditolak." }, { status: 403 });
  const reviewer = await requireRegistrationReviewer();
  if (!reviewer) return NextResponse.json({ error: "Akses Admin atau Super Admin diperlukan." }, { status: 403 });

  const { profileId } = await context.params;
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(profileId)) {
    return NextResponse.json({ error: "ID pendaftar tidak valid." }, { status: 400 });
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "Data keputusan tidak valid." }, { status: 400 });
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return NextResponse.json({ error: "Data keputusan tidak valid." }, { status: 400 });
  }
  const input = body as { decision?: unknown; reason?: unknown };
  if (input.decision !== "approve" && input.decision !== "reject") {
    return NextResponse.json({ error: "Pilih setujui atau tolak." }, { status: 400 });
  }
  const decision = input.decision;
  const submittedReason = typeof input.reason === "string" ? input.reason.trim() : "";
  if (decision === "reject" && !submittedReason) {
    return NextResponse.json({ error: "Catatan penolakan wajib diisi." }, { status: 400 });
  }
  if (submittedReason.length > 500) return NextResponse.json({ error: "Catatan keputusan maksimal 500 karakter." }, { status: 400 });
  const reason = submittedReason || `Disetujui oleh ${reviewer.profile.name}.`;

  const admin = createServiceRoleClient();
  if (!admin) return NextResponse.json({ error: "Persetujuan pendaftaran belum dikonfigurasi di server." }, { status: 503 });

  const { data: target, error: targetError } = await admin
    .from("profiles")
    .select("id,role,is_active,registration_status")
    .eq("id", profileId)
    .maybeSingle();
  if (targetError) return NextResponse.json({ error: "Data pendaftar tidak dapat dibaca." }, { status: 502 });
  if (!target || target.role !== "freelance" || target.is_active || target.registration_status !== "pending") {
    return NextResponse.json({ error: "Pendaftaran ini sudah tidak menunggu keputusan." }, { status: 409 });
  }

  const { data, error } = await admin.rpc("review_freelancer_registration", {
    p_target: profileId,
    p_approve: decision === "approve",
    p_actor: reviewer.user.id,
    p_reason: reason,
  });
  const result = data as { ok?: boolean; error?: string } | null;
  if (error || !result?.ok) {
    return NextResponse.json({ error: result?.error ?? "Keputusan belum tersimpan. Silakan muat ulang dan coba lagi." }, { status: 409 });
  }

  return NextResponse.json({ ok: true, message: decision === "approve" ? "Pendaftaran disetujui." : "Pendaftaran ditolak." });
}
