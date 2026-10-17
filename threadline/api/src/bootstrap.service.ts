import { Injectable, Logger, OnModuleInit } from "@nestjs/common";
import { randomUUID } from "node:crypto";
import bcrypt from "bcryptjs";
import { PrismaService } from "./prisma/prisma.service";

@Injectable()
export class BootstrapService implements OnModuleInit {
  private readonly logger = new Logger(BootstrapService.name);
  constructor(private readonly prisma: PrismaService) {}

  async onModuleInit() {
    const email = process.env.INITIAL_SUPER_ADMIN_EMAIL?.trim().toLowerCase();
    const password = process.env.INITIAL_SUPER_ADMIN_PASSWORD;
    if (!email || !password) return;
    if (!/^\S+@\S+\.\S+$/.test(email) || password.length < 12) throw new Error("Initial Super Admin bootstrap credentials are invalid");
    const name = process.env.INITIAL_SUPER_ADMIN_NAME?.trim() || "Threadline Super Admin";
    const passwordHash = await bcrypt.hash(password, 12);
    await this.prisma.$transaction(async (tx) => {
      await tx.$executeRawUnsafe("SET LOCAL ROLE service_role");
      await tx.$queryRaw`SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true)`;
      const active = await tx.$queryRaw`SELECT 1 FROM public.profiles WHERE role = 'super_admin' AND is_active LIMIT 1` as unknown[];
      if (active.length) return;
      const existing = await tx.$queryRaw`SELECT id::text FROM auth.users WHERE lower(email) = ${email} LIMIT 1` as Array<{ id: string }>;
      const id = existing[0]?.id ?? randomUUID();
      if (existing[0]) {
        await tx.$executeRaw`UPDATE auth.users SET email_confirmed_at = COALESCE(email_confirmed_at, now()),
          encrypted_password = ${passwordHash}, updated_at = now() WHERE id = ${id}::uuid`;
      } else {
        await tx.$executeRaw`INSERT INTO auth.users(id, email, encrypted_password, email_confirmed_at, raw_user_meta_data)
          VALUES (${id}::uuid, ${email}, ${passwordHash}, now(), ${JSON.stringify({ name })}::jsonb)`;
      }
      const result = await tx.$queryRaw`SELECT public.promote_super_admin(${id}::uuid, 'Initial account provisioning', ${name}) AS result` as Array<{ result: { ok?: boolean; error?: string } }>;
      if (!result[0]?.result?.ok) throw new Error(result[0]?.result?.error ?? "Could not provision initial Super Admin");
      await tx.$executeRaw`UPDATE public.profiles SET registration_status = 'approved' WHERE id = ${id}::uuid`;
      this.logger.warn(`Created the initial Super Admin account ${email}. Remove INITIAL_SUPER_ADMIN_* from the deployment environment now.`);
    });
  }
}
