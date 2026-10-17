import { BadRequestException, Body, Controller, Param, Post, Req, UnauthorizedException } from "@nestjs/common";
import type { Request } from "express";
import { AuthService } from "../auth/auth.service";
import { PrismaService } from "../prisma/prisma.service";

const ALLOWED = new Set([
  "touch_freelancer_presence", "set_freelancer_offline", "set_freelancer_availability",
  "manage_profile_access", "set_freelancer_payment_schedule", "finance_freelancer_bank_account",
  "finance_monthly_payment_report", "finance_monthly_jobs", "finance_unpaid_jobs",
  "finance_payment_history", "finance_payment_audit_log", "record_freelancer_payment",
  "void_freelancer_payment", "finance_log_payment_proof_view",
  "pending_freelancer_registrations", "managed_account_directory", "super_admin_audit_log",
  "finance_freelancer_payment_settings", "create_job", "assign_job", "transition_job",
  "review_submission", "reserve_upload", "release_upload_reservation", "submit_preview",
  "finish_job", "update_app_settings", "cancel_job", "delete_job", "update_job_fields",
  "is_super_admin",
]);
const RETURNS_ROWS = new Set([
  "finance_monthly_payment_report", "finance_monthly_jobs", "finance_unpaid_jobs",
  "finance_payment_history", "finance_payment_audit_log", "pending_freelancer_registrations",
  "managed_account_directory", "super_admin_audit_log", "finance_freelancer_payment_settings",
  "finance_freelancer_bank_account",
]);
const PARAM = /^p_[a-z][a-z0-9_]*$/;
const JSON_ARGS = new Set(["p_allocations"]);

@Controller("rpc")
export class RpcController {
  constructor(private readonly auth: AuthService, private readonly prisma: PrismaService) {}

  @Post(":name")
  async call(@Req() req: Request, @Param("name") name: string, @Body() body: { args?: Record<string, unknown> }) {
    const identity = await this.auth.resolve(req.headers.cookie);
    if (!identity) throw new UnauthorizedException("Sesi tidak valid");
    if (!ALLOWED.has(name)) throw new BadRequestException("Fungsi tidak diizinkan");
    const args = body?.args ?? {};
    if (!args || typeof args !== "object" || Array.isArray(args)) throw new BadRequestException("Argumen RPC tidak valid");
    const names = Object.keys(args);
    if (names.length > 12 || names.some((key) => !PARAM.test(key))) throw new BadRequestException("Nama argumen tidak diizinkan");
    const claims = JSON.stringify({ sub: identity.id, role: "authenticated", aal: identity.aal });
    return this.prisma.$transaction(async (tx) => {
      await tx.$executeRawUnsafe("SET LOCAL ROLE authenticated");
      await tx.$queryRaw`SELECT set_config('request.jwt.claim.sub', ${identity.id}, true)`;
      await tx.$queryRaw`SELECT set_config('request.jwt.claims', ${claims}, true)`;
      const parameters = names.map((key, index) => `${key} => $${index + 1}`).join(", ");
      const statement = RETURNS_ROWS.has(name)
        ? `SELECT * FROM public.${name}(${parameters})`
        : `SELECT public.${name}(${parameters}) AS result`;
      const result = await tx.$queryRawUnsafe(statement, ...names.map((key) =>
        JSON_ARGS.has(key) ? JSON.stringify(args[key]) : args[key],
      )) as Array<Record<string, unknown>>;
      if (RETURNS_ROWS.has(name)) return { data: result, error: null };
      return { data: result[0]?.result ?? null, error: null };
    });
  }
}
