import { BadRequestException, Body, ConflictException, Controller, Delete, ForbiddenException, Param, Patch, Post, Req, NotFoundException } from "@nestjs/common";
import type { Request } from "express";
import { randomUUID } from "node:crypto";
import bcrypt from "bcryptjs";
import { AuthService, type AuthIdentity } from "../auth/auth.service";
import { PrismaService } from "../prisma/prisma.service";
import { StorageService } from "../storage/storage.service";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ACCOUNT_ROLES = new Set(["admin", "finance", "freelance"]);

@Controller()
export class AdminController {
  constructor(private readonly auth: AuthService, private readonly prisma: PrismaService, private readonly storage: StorageService) {}

  @Post("super-admin/accounts")
  async createAccount(@Req() req: Request, @Body() input: { name?: string; email?: string; role?: string; password?: string; reason?: string } = {}) {
    const actor = await this.superAdmin(req);
    const name = input.name?.trim() ?? "";
    const email = input.email?.trim().toLowerCase() ?? "";
    const role = input.role ?? "";
    const password = input.password ?? "";
    const reason = input.reason?.trim() ?? "";
    if (name.length < 3 || name.length > 100) throw new BadRequestException("Nama harus terdiri dari 3–100 karakter.");
    if (!/^\S+@\S+\.\S+$/.test(email) || email.length > 254) throw new BadRequestException("Email tidak valid.");
    if (!ACCOUNT_ROLES.has(role)) throw new BadRequestException("Role akun tidak valid.");
    if (password.length < 8 || password.length > 128) throw new BadRequestException("Kata sandi harus berisi 8–128 karakter.");
    this.checkReason(reason);
    const id = randomUUID();
    const passwordHash = await bcrypt.hash(password, 12);
    try {
      await this.withService(actor, async (tx) => {
        await tx.$executeRaw`INSERT INTO auth.users(id, email, encrypted_password, email_confirmed_at, raw_user_meta_data)
          VALUES (${id}::uuid, ${email}, ${passwordHash}, now(), ${JSON.stringify({ name })}::jsonb)`;
        const rows = await tx.$queryRaw`SELECT public.set_created_account_role(${id}::uuid, ${role}, ${actor.id}::uuid, ${reason}) AS result` as Array<{ result: { ok?: boolean; error?: string } }>;
        if (!rows[0]?.result?.ok) throw new ConflictException(rows[0]?.result?.error ?? "Akun belum dapat diaktifkan.");
      });
    } catch (error) {
      if ((error as { code?: string }).code === "23505") throw new ConflictException("Email atau nama tersebut sudah digunakan akun lain.");
      throw error;
    }
    return { ok: true, message: `Akun ${email} berhasil dibuat tanpa mengirim undangan.` };
  }

  @Patch("super-admin/accounts/:profileId")
  async updateAccount(@Req() req: Request, @Param("profileId") profileId: string, @Body() input: {
    name?: string; whatsapp?: string; email?: string; password?: string; confirmPassword?: string; reason?: string;
  } = {}) {
    const actor = await this.superAdmin(req);
    this.checkUuid(profileId);
    const name = input.name?.trim() ?? "";
    const whatsapp = input.whatsapp?.trim() ?? "";
    const email = input.email?.trim().toLowerCase() ?? "";
    const password = input.password ?? "";
    const reason = input.reason?.trim() ?? "";
    if (name.length < 3 || name.length > 100) throw new BadRequestException("Nama harus terdiri dari 3–100 karakter.");
    if (whatsapp && !/^\+?[0-9(). -]{8,24}$/.test(whatsapp)) throw new BadRequestException("Nomor WhatsApp tidak valid.");
    if (!/^\S+@\S+\.\S+$/.test(email) || email.length > 254) throw new BadRequestException("Email tidak valid.");
    if (password && (password.length < 8 || password.length > 128)) throw new BadRequestException("Kata sandi baru harus berisi 8–128 karakter.");
    if (password && password !== input.confirmPassword) throw new BadRequestException("Konfirmasi kata sandi tidak sama.");
    this.checkReason(reason);
    const passwordHash = password ? await bcrypt.hash(password, 12) : null;
    let changed = false;
    try {
      await this.withService(actor, async (tx) => {
        const users = await tx.$queryRaw`SELECT email FROM auth.users WHERE id = ${profileId}::uuid FOR UPDATE` as Array<{ email: string }>;
        const profiles = await tx.$queryRaw`SELECT id::text FROM public.profiles WHERE id = ${profileId}::uuid` as Array<{ id: string }>;
        if (!users[0] || !profiles[0]) throw new NotFoundException("Akun tidak ditemukan.");
        const targetEmail = users[0].email;
        const emailChanged = targetEmail.toLowerCase() !== email;
        const passwordChanged = Boolean(passwordHash);
        if (emailChanged) {
          const duplicates = await tx.$queryRaw`SELECT 1 FROM auth.users WHERE lower(email) = ${email} AND id <> ${profileId}::uuid` as unknown[];
          if (duplicates.length) throw new ConflictException("Email tersebut sudah dipakai akun lain.");
        }
        if (emailChanged || passwordChanged) {
          await tx.$executeRaw`UPDATE auth.users SET
            email = ${emailChanged ? email : targetEmail},
            email_confirmed_at = CASE WHEN ${emailChanged} THEN now() ELSE email_confirmed_at END,
            encrypted_password = COALESCE(${passwordHash}, encrypted_password), updated_at = now()
            WHERE id = ${profileId}::uuid`;
        }
        const result = await tx.$queryRaw`SELECT public.update_managed_account(
          ${profileId}::uuid, ${actor.id}::uuid, ${name}, ${whatsapp}, ${targetEmail}, ${emailChanged}, ${passwordChanged}, ${reason}
        ) AS result` as Array<{ result: { ok?: boolean; error?: string; changed?: boolean } }>;
        if (!result[0]?.result?.ok) throw new ConflictException(result[0]?.result?.error ?? "Perubahan akun belum tersimpan.");
        changed = Boolean(result[0].result.changed || emailChanged || passwordChanged);
      });
    } catch (error) {
      if ((error as { code?: string }).code === "23505") throw new ConflictException("Email atau nama tersebut sudah digunakan akun lain.");
      throw error;
    }
    return { ok: true, message: changed ? "Data akun berhasil diperbarui dan dicatat." : "Tidak ada perubahan pada akun." };
  }

  @Post("super-admin/accounts/:profileId/actions")
  async accountAction(@Req() req: Request, @Param("profileId") profileId: string, @Body() input: { action?: string; reason?: string } = {}) {
    const actor = await this.superAdmin(req);
    this.checkUuid(profileId);
    const reason = input.reason?.trim() ?? "";
    this.checkReason(reason);
    const rows = await this.withService(actor, async (tx) => tx.$queryRaw`SELECT email, email_confirmed_at FROM auth.users WHERE id = ${profileId}::uuid` as Array<{ email: string; email_confirmed_at: Date | null }>);
    const target = rows[0];
    if (!target?.email) throw new NotFoundException("Akun tidak ditemukan atau tidak memiliki email.");
    let eventType: string;
    if (input.action === "password_reset") {
      await this.auth.requestPasswordReset(target.email, process.env.FRONTEND_URL ?? "http://localhost:3000", true);
      eventType = "password_reset_email_sent";
    } else if (input.action === "resend_verification") {
      if (target.email_confirmed_at) throw new ConflictException("Email akun ini sudah terverifikasi.");
      await this.auth.resendVerification(target.email, process.env.FRONTEND_URL ?? "http://localhost:3000", true);
      eventType = "verification_email_sent";
    } else if (input.action === "revoke_sessions") {
      await this.withService(actor, async (tx) => tx.$executeRaw`UPDATE public.threadline_sessions SET revoked_at = now() WHERE user_id = ${profileId}::uuid AND revoked_at IS NULL`);
      eventType = "sessions_revoked";
    } else throw new BadRequestException("Tindakan akun tidak dikenal.");
    const audit = await this.withService(actor, async (tx) => tx.$queryRaw`SELECT public.record_super_admin_user_action(
      ${profileId}::uuid, ${actor.id}::uuid, ${eventType}, ${reason}
    ) AS result` as Array<{ result: { ok?: boolean; error?: string } }>);
    if (!audit[0]?.result?.ok) throw new ConflictException("Tindakan dilakukan, tetapi pencatatan audit gagal.");
    return { ok: true, message: "Tindakan akun berhasil." };
  }

  @Delete("managed-accounts/:profileId")
  async deleteAccount(@Req() req: Request, @Param("profileId") profileId: string, @Body() input: { confirmation?: string; reason?: string } = {}) {
    const actor = await this.superAdmin(req);
    this.checkUuid(profileId);
    if (profileId === actor.id) throw new ConflictException("Anda tidak dapat menghapus akun yang sedang digunakan.");
    const reason = input.reason?.trim() ?? "";
    const confirmation = input.confirmation?.trim().toLowerCase() ?? "";
    this.checkReason(reason);
    let targetEmail = "";
    let targetName = "";
    let avatarPath: string | null = null;
    try {
      await this.withService(actor, async (tx) => {
        const rows = await tx.$queryRaw`SELECT u.email, p.name, p.role, p.avatar_path
          FROM auth.users u JOIN public.profiles p ON p.id = u.id WHERE p.id = ${profileId}::uuid FOR UPDATE OF p` as Array<{ email: string; name: string; role: string; avatar_path: string | null }>;
        const target = rows[0];
        if (!target?.email) throw new NotFoundException("Akun tidak ditemukan.");
        if (target.role === "super_admin") throw new ForbiddenException("Akun Super Admin dilindungi dan tidak dapat dihapus dari menu ini.");
        if (confirmation !== target.email.toLowerCase()) throw new BadRequestException("Ketik email akun dengan benar untuk mengonfirmasi penghapusan.");
        const approved = await tx.$queryRaw`SELECT 1 FROM public.jobs WHERE approved_for_profile_id = ${profileId}::uuid LIMIT 1` as unknown[];
        if (approved.length) throw new ConflictException("Akun masih tercatat pada pekerjaan yang sudah ACC. Nonaktifkan akses akun agar riwayat pekerjaan tetap utuh.");
        targetEmail = target.email;
        targetName = target.name;
        avatarPath = target.avatar_path;
        await tx.$executeRaw`DELETE FROM auth.users WHERE id = ${profileId}::uuid`;
        const audit = await tx.$queryRaw`SELECT public.record_managed_account_deletion(
          ${profileId}::uuid, ${actor.id}::uuid, ${target.name}, ${target.email}, ${reason}
        ) AS result` as Array<{ result: { ok?: boolean; error?: string } }>;
        if (!audit[0]?.result?.ok) throw new ConflictException(audit[0]?.result?.error ?? "Penghapusan belum tercatat.");
      });
    } catch (error) {
      if ((error as { code?: string }).code === "23503") throw new ConflictException("Akun masih digunakan oleh data lain. Nonaktifkan akses untuk mempertahankan riwayat.");
      throw error;
    }
    let photoCleanupFailed = false;
    if (avatarPath) photoCleanupFailed = !(await this.storage.removeAsService("profile-photos", avatarPath));
    return {
      ok: true,
      message: photoCleanupFailed ? "Akun dihapus dan dicatat, tetapi foto profil belum berhasil dibersihkan." : "Akun berhasil dihapus dan dicatat pada riwayat keamanan.",
    };
  }

  @Post("freelancer-registrations/:profileId/review")
  async reviewRegistration(@Req() req: Request, @Param("profileId") profileId: string, @Body() input: { decision?: string; reason?: string } = {}) {
    const actor = await this.auth.resolve(req.headers.cookie);
    if (!actor || !actor.isActive || !["admin", "super_admin"].includes(actor.role) || (actor.role === "super_admin" && actor.aal !== "aal2")) {
      throw new ForbiddenException("Akses Admin atau Super Admin diperlukan.");
    }
    this.checkUuid(profileId);
    if (input.decision !== "approve" && input.decision !== "reject") throw new BadRequestException("Pilih setujui atau tolak.");
    const submittedReason = input.reason?.trim() ?? "";
    if (input.decision === "reject" && !submittedReason) throw new BadRequestException("Catatan penolakan wajib diisi.");
    if (submittedReason.length > 500) throw new BadRequestException("Catatan keputusan maksimal 500 karakter.");
    const reason = submittedReason || "Disetujui oleh Admin.";
    const result = await this.withService(actor, async (tx) => tx.$queryRaw`SELECT public.review_freelancer_registration(
      ${profileId}::uuid, ${input.decision === "approve"}, ${actor.id}::uuid, ${reason}
    ) AS result` as Array<{ result: { ok?: boolean; error?: string } }>);
    if (!result[0]?.result?.ok) throw new ConflictException(result[0]?.result?.error ?? "Keputusan belum tersimpan.");
    return { ok: true, message: input.decision === "approve" ? "Pendaftaran disetujui." : "Pendaftaran ditolak." };
  }

  private async superAdmin(req: Request): Promise<AuthIdentity> {
    const actor = await this.auth.resolve(req.headers.cookie);
    if (!actor || !actor.isActive || actor.role !== "super_admin" || actor.aal !== "aal2") throw new ForbiddenException("Akses Super Admin dengan autentikator diperlukan.");
    return actor;
  }

  private async withService<T>(identity: AuthIdentity, work: (tx: any) => Promise<T>): Promise<T> {
    return this.prisma.$transaction(async (tx) => {
      await tx.$executeRawUnsafe("SET LOCAL ROLE service_role");
      const claims = JSON.stringify({ sub: identity.id, role: "service_role", aal: identity.aal });
      await tx.$queryRaw`SELECT set_config('request.jwt.claim.sub', ${identity.id}, true)`;
      await tx.$queryRaw`SELECT set_config('request.jwt.claims', ${claims}, true)`;
      return work(tx);
    });
  }

  private async withUser<T>(identity: AuthIdentity, work: (tx: any) => Promise<T>): Promise<T> {
    return this.prisma.$transaction(async (tx) => {
      await tx.$executeRawUnsafe("SET LOCAL ROLE authenticated");
      const claims = JSON.stringify({ sub: identity.id, role: "authenticated", aal: identity.aal });
      await tx.$queryRaw`SELECT set_config('request.jwt.claim.sub', ${identity.id}, true)`;
      await tx.$queryRaw`SELECT set_config('request.jwt.claims', ${claims}, true)`;
      return work(tx);
    });
  }

  private checkUuid(id: string) { if (!UUID.test(id)) throw new BadRequestException("ID akun tidak valid."); }
  private checkReason(reason: string) { if (!reason || reason.length > 500) throw new BadRequestException("Alasan wajib diisi (maksimal 500 karakter)."); }
}
