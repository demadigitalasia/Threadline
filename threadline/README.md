# Threadline

Threadline uses a Next.js frontend, a NestJS API, PostgreSQL managed with Prisma, and one private Cloudflare R2 bucket. The browser talks to Next.js on the same origin; Next.js forwards API requests over the private Compose network. The API enforces PostgreSQL row policies and issues short lived R2 URLs. R2 credentials stay in the API container.

## Run with Docker Compose

1. Copy `.env.example` to `.env` and fill in database passwords, the R2 endpoint and credentials, and an MFA encryption key.
2. Create a private R2 bucket named `threadline-private` (or set another `R2_BUCKET`) and an R2 API token limited to that bucket.
3. Set the bucket CORS rule to the deployed frontend origin. Permit `PUT` and `GET`, and the `content-type` header. Add an R2 lifecycle rule to expire the `__pending/` prefix after one day. Uploads land there first, then the API verifies and moves them to their final private key.
4. Optionally set `INITIAL_SUPER_ADMIN_EMAIL`, `INITIAL_SUPER_ADMIN_NAME`, and a password of at least 12 characters for the first boot. The API provisions that account once when no active Super Admin exists. Remove those variables after the account is created. On first sign-in, the account must enroll an authenticator.
5. Set `FRONTEND_URL` to the HTTPS URL Coolify serves, then deploy `compose.yaml`. PostgreSQL stays on the private database network; Coolify should expose only `web`.

The first API start applies the checked-in Prisma migration. It creates the PostgreSQL schema from the existing domain SQL, adds PostgreSQL functions and row level security, and creates a restricted runtime database role. The migration source files are retained under `database/legacy-migrations` for traceability; Supabase is not part of the runtime stack.

Prisma manages the schema migration and PostgreSQL connection. Existing transactional job, finance, and access rules remain in PostgreSQL functions and row level security, called by the NestJS API with the authenticated database role.

SMTP settings are needed for freelancer verification and password reset email. Registration reports a configuration error if SMTP is missing; public reset and resend requests keep a generic response so they do not disclose whether an email belongs to an account. No link is sent until SMTP works.

## Required deployment settings

- `POSTGRES_PASSWORD` and `THREADLINE_APP_PASSWORD`: use distinct, long, URL safe random values.
- `R2_ENDPOINT`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, and `R2_SECRET_ACCESS_KEY`: use the S3 API endpoint and a bucket scoped token. Do not make the bucket public.
- `MFA_ENCRYPTION_KEY`: base64 encoding of 32 random bytes. Keep a protected backup; changing it prevents decrypting enrolled authenticator secrets.
- `FRONTEND_URL`: the exact HTTPS origin, including the temporary `sslip.io` hostname if that is what Coolify serves.
- `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_FROM`: set these before allowing account registration or password reset.

## Database notes

The initial migration reproduces the existing job, finance, account, and audit SQL behavior and substitutes small `auth` and `storage` metadata schemas for the old managed services. Files themselves are stored under logical prefixes in R2; database rows remain the authority for access. Upload URLs expire after fifteen minutes and use temporary staging keys. Download links expire after fifteen minutes.

This creates a new PostgreSQL database. It does not copy live rows or file objects from an existing Supabase deployment; use a separately reviewed data export/import before switching traffic if that deployment contains user data.
