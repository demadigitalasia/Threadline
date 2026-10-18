import {
  BadRequestException,
  ConflictException,
  Injectable,
  Logger,
  ServiceUnavailableException,
  UnauthorizedException,
} from "@nestjs/common";
import { randomBytes, randomUUID } from "node:crypto";
import bcrypt from "bcryptjs";
import nodemailer from "nodemailer";
import { PrismaService } from "../prisma/prisma.service";
import { decryptSecret, encryptSecret, hashToken, newTotpSecret, otpAuthUrl, verifyTotp } from "./crypto";

const SESSION_COOKIE = "threadline_session";
const SESSION_TTL_MS = 1000 * 60 * 60 * 24 * 14;
const CODE_TTL_MS = 1000 * 60 * 60;

type UserRow = { id: string; email: string; encrypted_password: string; email_confirmed_at: Date | null; role: string; is_active: boolean; registration_status: string };
export type AuthIdentity = { id: string; email: string; role: string; aal: "aal1" | "aal2"; isActive: boolean };

@Injectable()
export class AuthService {
  private readonly logger = new Logger(AuthService.name);
  constructor(private readonly prisma: PrismaService) {}

  private async service<T>(work: (tx: any) => Promise<T>): Promise<T> {
    return this.prisma.$transaction(async (tx) => {
      await tx.$executeRawUnsafe("SET LOCAL ROLE service_role");
      await tx.$queryRaw`SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true)`;
      await tx.$queryRaw`SELECT set_config('request.jwt.claim.sub', '', true)`;
      return work(tx);
    });
  }

  async resolve(cookieHeader?: string): Promise<AuthIdentity | null> {
    const token = this.readCookie(cookieHeader, SESSION_COOKIE);
    if (!token) return null;
    return this.service(async (tx) => {
      const rows = await tx.$queryRaw`
        SELECT s.user_id::text AS id, u.email, s.assurance_level AS aal, p.role, p.is_active
        FROM public.threadline_sessions s
        JOIN auth.users u ON u.id = s.user_id
        JOIN public.profiles p ON p.id = s.user_id
        WHERE s.token_hash = ${hashToken(token)} AND s.revoked_at IS NULL AND s.expires_at > now()
          AND (p.is_active OR p.registration_status = 'pending')
      ` as Array<{ id: string; email: string; aal: "aal1" | "aal2"; role: string; is_active: boolean }>;
      const row = rows[0];
      return row ? { id: row.id, email: row.email, role: row.role, aal: row.aal, isActive: row.is_active } : null;
    });
  }

  async signIn(emailInput: string, password: string) {
    const email = emailInput.trim().toLowerCase();
    const row = await this.service(async (tx) => {
      const rows = await tx.$queryRaw`
        SELECT u.id::text, u.email, u.encrypted_password, u.email_confirmed_at, p.role, p.is_active, p.registration_status
        FROM auth.users u JOIN public.profiles p ON p.id = u.id
        WHERE lower(u.email) = ${email}
        LIMIT 1
      ` as UserRow[];
      return rows[0] ?? null;
    });
    if (!row || !(await bcrypt.compare(password, row.encrypted_password))) throw new UnauthorizedException({ code: "INVALID_CREDENTIALS", message: "Email atau kata sandi salah" });
    if (!row.email_confirmed_at) throw new UnauthorizedException({ code: "EMAIL_UNVERIFIED", message: "Verifikasi email terlebih dahulu" });
    if (!row.is_active && row.registration_status !== "pending") throw new UnauthorizedException({ code: "ACCOUNT_INACTIVE", message: "Akun tidak aktif" });

    // Super Admin sign-in uses the same password-only flow; MFA is not required.
    const aal: "aal1" = "aal1";

    const token = randomBytes(32).toString("base64url");
    await this.service(async (tx) => {
      await tx.$executeRaw`INSERT INTO public.threadline_sessions(user_id, token_hash, assurance_level, expires_at)
        VALUES (${row.id}::uuid, ${hashToken(token)}, ${aal}, ${new Date(Date.now() + SESSION_TTL_MS)})`;
    });
    return { token, user: this.toUser(row) };
  }

  async beginMfaEnrollment(emailInput: string, password: string) {
    const email = emailInput.trim().toLowerCase();
    const row = await this.findForPassword(email, password);
    if (row.role !== "super_admin") throw new UnauthorizedException("MFA khusus akun Super Admin");
    if (!row.is_active || !row.email_confirmed_at) throw new UnauthorizedException("Akun Super Admin tidak aktif atau belum terverifikasi");
    const existing = await this.service(async (tx) => tx.$queryRaw`SELECT confirmed_at FROM public.threadline_mfa_factors WHERE user_id = ${row.id}::uuid` as Array<{ confirmed_at: Date | null }>);
    if (existing[0]?.confirmed_at) throw new ConflictException("Autentikator sudah aktif");
    const secret = newTotpSecret();
    await this.service(async (tx) => {
      await tx.$executeRaw`INSERT INTO public.threadline_mfa_factors(user_id, secret_ciphertext, confirmed_at)
        VALUES (${row.id}::uuid, ${encryptSecret(secret)}, NULL)
        ON CONFLICT (user_id) DO UPDATE SET secret_ciphertext = EXCLUDED.secret_ciphertext, confirmed_at = NULL`;
    });
    return { secret, otpauthUrl: otpAuthUrl(secret, row.email) };
  }

  async confirmMfaEnrollment(emailInput: string, password: string, otp: string) {
    const row = await this.findForPassword(emailInput.trim().toLowerCase(), password);
    if (row.role !== "super_admin") throw new UnauthorizedException("MFA khusus akun Super Admin");
    if (!row.is_active || !row.email_confirmed_at) throw new UnauthorizedException("Akun Super Admin tidak aktif atau belum terverifikasi");
    const factors = await this.service(async (tx) => tx.$queryRaw`SELECT secret_ciphertext FROM public.threadline_mfa_factors WHERE user_id = ${row.id}::uuid AND confirmed_at IS NULL` as Array<{ secret_ciphertext: string }>);
    if (!factors[0] || !verifyTotp(decryptSecret(factors[0].secret_ciphertext), otp)) throw new BadRequestException("Kode autentikator tidak valid");
    await this.service(async (tx) => tx.$executeRaw`UPDATE public.threadline_mfa_factors SET confirmed_at = now() WHERE user_id = ${row.id}::uuid`);
    return this.signIn(row.email, password);
  }

  async signOut(cookieHeader?: string) {
    const token = this.readCookie(cookieHeader, SESSION_COOKIE);
    if (token) await this.service(async (tx) => tx.$executeRaw`UPDATE public.threadline_sessions SET revoked_at = now() WHERE token_hash = ${hashToken(token)} AND revoked_at IS NULL`);
  }

  async user(cookieHeader?: string) {
    const identity = await this.resolve(cookieHeader);
    if (!identity) return null;
    return this.service(async (tx) => {
      const rows = await tx.$queryRaw`SELECT id::text, email, email_confirmed_at FROM auth.users WHERE id = ${identity.id}::uuid` as Array<{ id: string; email: string; email_confirmed_at: Date | null }>;
      return rows[0] ? { ...rows[0], email_confirmed_at: rows[0].email_confirmed_at?.toISOString() ?? null } : null;
    });
  }

  async signUp(emailInput: string, password: string, metadata: { name?: string; whatsapp?: string }, frontendUrl: string) {
    const email = emailInput.trim().toLowerCase();
    const name = metadata.name?.trim() ?? "";
    const whatsapp = metadata.whatsapp?.trim() ?? "";
    if (!/^\S+@\S+\.\S+$/.test(email) || email.length > 254 || password.length < 8 || password.length > 128
      || name.length < 3 || name.length > 100 || (whatsapp && !/^\+?[0-9(). -]{8,24}$/.test(whatsapp))) {
      throw new BadRequestException("Data pendaftaran tidak valid");
    }
    if (!process.env.SMTP_HOST || !process.env.SMTP_FROM) throw new ServiceUnavailableException("Email belum dikonfigurasi pada server");
    const userId = randomUUID();
    const passwordHash = await bcrypt.hash(password, 12);
    const created = await this.service(async (tx) => {
      const rows = await tx.$queryRaw`INSERT INTO auth.users(id, email, encrypted_password, raw_user_meta_data)
        VALUES (${userId}::uuid, ${email}, ${passwordHash}, ${JSON.stringify({ name })}::jsonb)
        ON CONFLICT DO NOTHING RETURNING id::text` as Array<{ id: string }>;
      if (!rows[0]) return false;
      if (whatsapp) await tx.$executeRaw`INSERT INTO public.profile_contacts(profile_id, whatsapp)
        VALUES (${userId}::uuid, ${whatsapp}) ON CONFLICT (profile_id) DO UPDATE SET whatsapp = EXCLUDED.whatsapp`;
      return true;
    });
    if (!created) {
      const pending = await this.service(async (tx) => tx.$queryRaw`SELECT id::text FROM auth.users
        WHERE lower(email) = ${email} AND email_confirmed_at IS NULL LIMIT 1` as Array<{ id: string }>);
      if (pending[0]) {
        try { await this.sendOneTimeLink(email, pending[0].id, "verify_email", frontendUrl, "/verifikasi-email"); }
        catch (error) { if (!(error instanceof ServiceUnavailableException)) throw error; }
      }
      return { accepted: true };
    }
    try {
      await this.sendOneTimeLink(email, userId, "verify_email", frontendUrl, "/verifikasi-email");
    } catch (error) {
      await this.service(async (tx) => {
        await tx.$executeRaw`DELETE FROM auth.users WHERE id = ${userId}::uuid`;
      });
      if (!(error instanceof ServiceUnavailableException)) throw error;
    }
    return { accepted: true };
  }

  async requestPasswordReset(emailInput: string, frontendUrl: string, strictDelivery = false) {
    if (!process.env.SMTP_HOST || !process.env.SMTP_FROM) {
      if (strictDelivery) throw new ServiceUnavailableException("Email belum dikonfigurasi pada server");
      return { accepted: true };
    }
    const email = emailInput.trim().toLowerCase();
    const rows = await this.service(async (tx) => tx.$queryRaw`SELECT id::text FROM auth.users WHERE lower(email) = ${email} AND email_confirmed_at IS NOT NULL` as Array<{ id: string }>);
    if (rows[0]) {
      try { await this.sendOneTimeLink(email, rows[0].id, "password_reset", frontendUrl, "/reset-password"); }
      catch (error) { if (strictDelivery || !(error instanceof ServiceUnavailableException)) throw error; }
    }
    return { accepted: true };
  }

  async exchangeCode(code: string) {
    if (!code || code.length > 256) throw new BadRequestException("Tautan tidak valid");
    const tokenHash = hashToken(code);
    const token = await this.service(async (tx) => {
      const rows = await tx.$queryRaw`SELECT t.id::text, t.user_id::text, t.purpose, u.email
        FROM public.threadline_auth_tokens t JOIN auth.users u ON u.id = t.user_id
        WHERE t.token_hash = ${tokenHash} AND t.consumed_at IS NULL AND t.expires_at > now()
        FOR UPDATE OF t` as Array<{ id: string; user_id: string; purpose: string; email: string }>;
      const row = rows[0];
      if (!row) return null;
      await tx.$executeRaw`UPDATE public.threadline_auth_tokens SET consumed_at = now() WHERE id = ${row.id}::uuid`;
      if (row.purpose === "verify_email") await tx.$executeRaw`UPDATE auth.users SET email_confirmed_at = now(), updated_at = now() WHERE id = ${row.user_id}::uuid`;
      return row;
    });
    if (!token) throw new UnauthorizedException("Tautan tidak valid atau sudah kedaluwarsa");
    const sessionToken = randomBytes(32).toString("base64url");
    await this.service(async (tx) => tx.$executeRaw`INSERT INTO public.threadline_sessions(user_id, token_hash, expires_at, password_reset_available)
      VALUES (${token.user_id}::uuid, ${hashToken(sessionToken)}, ${new Date(Date.now() + SESSION_TTL_MS)}, ${token.purpose === "password_reset"})`);
    return { token: sessionToken, purpose: token.purpose, user: { email: token.email } };
  }

  async updatePassword(cookieHeader: string | undefined, password: string) {
    if (password.length < 8 || password.length > 128) throw new BadRequestException("Kata sandi harus berisi 8–128 karakter");
    const token = this.readCookie(cookieHeader, SESSION_COOKIE);
    if (!token) throw new UnauthorizedException();
    const hash = await bcrypt.hash(password, 12);
    const updated = await this.service(async (tx) => {
      const rows = await tx.$queryRaw`SELECT s.user_id::text AS user_id FROM public.threadline_sessions s
        JOIN public.profiles p ON p.id = s.user_id
        WHERE s.token_hash = ${hashToken(token)} AND s.revoked_at IS NULL AND s.expires_at > now()
          AND s.password_reset_available AND (p.is_active OR p.registration_status = 'pending')
        FOR UPDATE OF s` as Array<{ user_id: string }>;
      if (!rows[0]) return false;
      await tx.$executeRaw`UPDATE auth.users SET encrypted_password = ${hash}, updated_at = now() WHERE id = ${rows[0].user_id}::uuid`;
      await tx.$executeRaw`UPDATE public.threadline_sessions SET password_reset_available = false WHERE token_hash = ${hashToken(token)}`;
      await tx.$executeRaw`UPDATE public.threadline_sessions SET revoked_at = now()
        WHERE user_id = ${rows[0].user_id}::uuid AND token_hash <> ${hashToken(token)} AND revoked_at IS NULL`;
      return true;
    });
    if (!updated) throw new UnauthorizedException("Gunakan tautan reset kata sandi yang masih berlaku");
    return { updated: true };
  }

  async resendVerification(emailInput: string, frontendUrl: string, strictDelivery = false) {
    if (!process.env.SMTP_HOST || !process.env.SMTP_FROM) {
      if (strictDelivery) throw new ServiceUnavailableException("Email belum dikonfigurasi pada server");
      return { accepted: true };
    }
    const email = emailInput.trim().toLowerCase();
    const rows = await this.service(async (tx) => tx.$queryRaw`SELECT id::text FROM auth.users WHERE lower(email) = ${email} AND email_confirmed_at IS NULL` as Array<{ id: string }>);
    if (rows[0]) {
      try { await this.sendOneTimeLink(email, rows[0].id, "verify_email", frontendUrl, "/verifikasi-email"); }
      catch (error) { if (strictDelivery || !(error instanceof ServiceUnavailableException)) throw error; }
    }
    return { accepted: true };
  }

  setSessionCookie(token: string, secure: boolean): string {
    const expires = new Date(Date.now() + SESSION_TTL_MS).toUTCString();
    return `${SESSION_COOKIE}=${encodeURIComponent(token)}; Path=/; HttpOnly; SameSite=Lax; Expires=${expires}${secure ? "; Secure" : ""}`;
  }

  clearSessionCookie(secure: boolean): string {
    return `${SESSION_COOKIE}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0${secure ? "; Secure" : ""}`;
  }

  getCookieName() { return SESSION_COOKIE; }

  private async findForPassword(email: string, password: string): Promise<UserRow> {
    const rows = await this.service(async (tx) => tx.$queryRaw`SELECT u.id::text, u.email, u.encrypted_password, u.email_confirmed_at, p.role, p.is_active, p.registration_status
      FROM auth.users u JOIN public.profiles p ON p.id = u.id WHERE lower(u.email) = ${email} LIMIT 1` as UserRow[]);
    const row = rows[0];
    if (!row || !(await bcrypt.compare(password, row.encrypted_password))) throw new UnauthorizedException("Email atau kata sandi salah");
    return row;
  }

  private async sendOneTimeLink(email: string, userId: string, purpose: "verify_email" | "password_reset", frontendUrl: string, path: string) {
    const host = process.env.SMTP_HOST;
    const from = process.env.SMTP_FROM;
    if (!host || !from) throw new ServiceUnavailableException("Email belum dikonfigurasi pada server");
    const code = randomBytes(32).toString("base64url");
    await this.service(async (tx) => {
      await tx.$executeRaw`UPDATE public.threadline_auth_tokens SET consumed_at = now() WHERE user_id = ${userId}::uuid AND purpose = ${purpose} AND consumed_at IS NULL`;
      await tx.$executeRaw`INSERT INTO public.threadline_auth_tokens(user_id, purpose, token_hash, expires_at)
        VALUES (${userId}::uuid, ${purpose}, ${hashToken(code)}, ${new Date(Date.now() + CODE_TTL_MS)})`;
    });
    const url = new URL(path, frontendUrl);
    url.searchParams.set("code", code);
    const transport = nodemailer.createTransport({
      host,
      port: Number(process.env.SMTP_PORT ?? 587),
      secure: process.env.SMTP_SECURE === "true",
      auth: process.env.SMTP_USER ? { user: process.env.SMTP_USER, pass: process.env.SMTP_PASSWORD ?? "" } : undefined,
    });
    const subject = purpose === "verify_email" ? "Verifikasi email Threadline" : "Reset kata sandi Threadline";
    try {
      await transport.sendMail({ from, to: email, subject, text: `${subject}: ${url.toString()}` });
    } catch (error) {
      await this.service(async (tx) => tx.$executeRaw`UPDATE public.threadline_auth_tokens SET consumed_at = now()
        WHERE token_hash = ${hashToken(code)} AND consumed_at IS NULL`);
      this.logger.error(`Could not send ${purpose} email: ${error instanceof Error ? error.message : "unknown SMTP error"}`);
      throw new ServiceUnavailableException("Email tidak dapat dikirim saat ini");
    }
  }

  private readCookie(header: string | undefined, name: string): string | null {
    const part = header?.split(";").map((piece) => piece.trim()).find((piece) => piece.startsWith(`${name}=`));
    return part ? decodeURIComponent(part.slice(name.length + 1)) : null;
  }

  private toUser(row: UserRow) {
    return { id: row.id, email: row.email, email_confirmed_at: row.email_confirmed_at?.toISOString() ?? null };
  }
}
