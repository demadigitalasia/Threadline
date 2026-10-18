import bcrypt from "bcryptjs";
import { PrismaPg } from "@prisma/adapter-pg";
import { PrismaClient } from "../generated/prisma/client";

async function main() {
  if (process.env.CONFIRM_SUPER_ADMIN_PASSWORD_SYNC !== "yes") {
    throw new Error("Set CONFIRM_SUPER_ADMIN_PASSWORD_SYNC=yes for this one-time password sync");
  }

  const email = process.env.INITIAL_SUPER_ADMIN_EMAIL?.trim().toLowerCase();
  const password = process.env.INITIAL_SUPER_ADMIN_PASSWORD;
  const connectionString = process.env.DATABASE_URL;
  if (!email || !password || !connectionString) {
    throw new Error("The configured Super Admin email, password, and database connection are required");
  }
  if (!/^\S+@\S+\.\S+$/.test(email) || password.length < 12 || password.length > 128) {
    throw new Error("The configured Super Admin credentials are invalid");
  }

  const prisma = new PrismaClient({ adapter: new PrismaPg({ connectionString }) });
  try {
    await prisma.$connect();
    await prisma.$transaction(async (tx: any) => {
      await tx.$executeRawUnsafe("SET LOCAL ROLE service_role");
      await tx.$queryRaw`SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true)`;
      const users = await tx.$queryRaw`
        SELECT u.id::text AS id
        FROM auth.users u
        JOIN public.profiles p ON p.id = u.id
        WHERE lower(u.email) = ${email} AND p.role = 'super_admin' AND p.is_active
        FOR UPDATE OF u
      ` as Array<{ id: string }>;
      if (users.length !== 1) throw new Error("No unique active Super Admin matches the configured email");

      const passwordHash = await bcrypt.hash(password, 12);
      await tx.$executeRaw`
        UPDATE auth.users SET encrypted_password = ${passwordHash}, updated_at = now()
        WHERE id = ${users[0].id}::uuid
      `;
      await tx.$executeRaw`
        UPDATE public.threadline_sessions SET revoked_at = now()
        WHERE user_id = ${users[0].id}::uuid AND revoked_at IS NULL
      `;
    });
    console.info("Password synchronized for the configured active Super Admin; existing sessions were revoked.");
  } finally {
    await prisma.$disconnect();
  }
}

main().catch(() => {
  console.error("Password synchronization did not complete. Check configuration and account eligibility.");
  process.exitCode = 1;
});
