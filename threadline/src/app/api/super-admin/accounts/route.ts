import { NextResponse } from "next/server";
import { requireSuperAdmin, createServiceRoleClient, hasSameOrigin } from "@/lib/supabase/super-admin";

const ALLOWED_ROLES = new Set(["admin", "finance", "freelance"]);

export async function POST(request: Request) {
  if (!hasSameOrigin(request)) return NextResponse.json({ error: "Permintaan lintas situs ditolak." }, { status: 403 });
  const access = await requireSuperAdmin();
  if (!access) return NextResponse.json({ error: "Akses Super Admin diperlukan." }, { status: 403 });

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "Data akun tidak valid." }, { status: 400 });
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return NextResponse.json({ error: "Data akun tidak valid." }, { status: 400 });
  }
  const input = body as { name?: unknown; email?: unknown; role?: unknown; password?: unknown; reason?: unknown };

  const name = typeof input.name === "string" ? input.name.trim() : "";
  const email = typeof input.email === "string" ? input.email.trim().toLowerCase() : "";
  const role = typeof input.role === "string" ? input.role : "";
  const password = typeof input.password === "string" ? input.password : "";
  const reason = typeof input.reason === "string" ? input.reason.trim() : "";

  if (name.length < 3 || name.length > 100) return NextResponse.json({ error: "Nama harus terdiri dari 3–100 karakter." }, { status: 400 });
  if (!/^\S+@\S+\.\S+$/.test(email) || email.length > 254) return NextResponse.json({ error: "Email tidak valid." }, { status: 400 });
  if (!ALLOWED_ROLES.has(role)) return NextResponse.json({ error: "Role akun tidak valid." }, { status: 400 });
  if (password.length < 8 || password.length > 128) return NextResponse.json({ error: "Kata sandi harus berisi 8–128 karakter." }, { status: 400 });
  if (!reason || reason.length > 500) return NextResponse.json({ error: "Alasan pembuatan akun wajib diisi (maksimal 500 karakter)." }, { status: 400 });

  const admin = createServiceRoleClient();
  if (!admin) return NextResponse.json({ error: "Fitur pembuatan akun belum dikonfigurasi di server." }, { status: 503 });

  const { data, error } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { name },
  });
  if (error || !data.user) {
    if (/already (registered|exists)|already been registered/i.test(error?.message ?? "")) {
      return NextResponse.json({ error: "Email tersebut sudah memiliki akun." }, { status: 409 });
    }
    return NextResponse.json({ error: "Akun belum dapat dibuat. Periksa data lalu coba lagi." }, { status: 400 });
  }

  const { data: roleResult, error: roleError } = await admin.rpc("set_created_account_role", {
    p_target: data.user.id,
    p_new_role: role,
    p_actor: access.user.id,
    p_reason: reason,
  });
  const assignedRole = roleResult as { ok?: boolean; error?: string } | null;
  if (roleError || !assignedRole?.ok) {
    const { error: rollbackError } = await admin.auth.admin.deleteUser(data.user.id);
    if (rollbackError) {
      return NextResponse.json({ error: "Akun Auth sudah dibuat, tetapi role gagal ditetapkan dan pembersihan otomatis juga gagal. Akun masih nonaktif; hubungi operator sistem." }, { status: 500 });
    }
    return NextResponse.json({ error: `Akun gagal disiapkan dan telah dibatalkan. ${roleError?.message ?? assignedRole?.error ?? ""}`.trim() }, { status: 500 });
  }

  return NextResponse.json({ ok: true, message: `Akun ${email} berhasil dibuat tanpa mengirim undangan.` }, { status: 201 });
}
