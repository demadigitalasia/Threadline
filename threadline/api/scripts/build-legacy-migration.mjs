import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const source = resolve(root, "database/legacy-migrations");
const output = resolve(root, "api/prisma/migrations/20261018000000_threadline/migration.sql");

const compatibility = `-- Standalone PostgreSQL compatibility layer replacing Supabase Auth/Storage.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
DO $$ BEGIN CREATE ROLE anon NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE authenticated NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE service_role NOLOGIN BYPASSRLS; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER ROLE service_role BYPASSRLS;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS storage;

CREATE TABLE IF NOT EXISTS auth.users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text UNIQUE,
  encrypted_password text NOT NULL DEFAULT '',
  email_confirmed_at timestamptz,
  raw_user_meta_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  banned_until timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS auth_users_email_lower_unique ON auth.users (lower(email)) WHERE email IS NOT NULL;
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT nullif(coalesce(current_setting('request.jwt.claim.sub', true), current_setting('app.user_id', true)), '')::uuid
$$;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb)
$$;
GRANT USAGE ON SCHEMA auth TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON auth.users TO service_role;
GRANT EXECUTE ON FUNCTION auth.uid(), auth.jwt() TO authenticated, service_role;

CREATE TABLE IF NOT EXISTS storage.buckets (
  id text PRIMARY KEY,
  name text NOT NULL,
  public boolean NOT NULL DEFAULT false,
  file_size_limit bigint,
  allowed_mime_types text[]
);
CREATE TABLE IF NOT EXISTS storage.objects (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id text NOT NULL REFERENCES storage.buckets(id) ON DELETE CASCADE,
  name text NOT NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(bucket_id, name)
);
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
CREATE OR REPLACE FUNCTION storage.foldername(p_name text) RETURNS text[]
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN array_length(parts, 1) > 1 THEN parts[1:array_length(parts, 1) - 1] ELSE ARRAY[]::text[] END
  FROM (SELECT string_to_array(p_name, '/') AS parts) s
$$;
GRANT USAGE ON SCHEMA storage TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON storage.buckets, storage.objects TO authenticated, service_role;

CREATE TABLE IF NOT EXISTS public.threadline_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  token_hash bytea NOT NULL UNIQUE,
  assurance_level text NOT NULL DEFAULT 'aal1' CHECK (assurance_level IN ('aal1','aal2')),
  password_reset_available boolean NOT NULL DEFAULT false,
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS threadline_sessions_user_idx ON public.threadline_sessions(user_id, expires_at);
CREATE TABLE IF NOT EXISTS public.threadline_auth_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  purpose text NOT NULL CHECK (purpose IN ('verify_email','password_reset','auth_code')),
  token_hash bytea NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.threadline_mfa_factors (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  secret_ciphertext text NOT NULL,
  confirmed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.threadline_upload_intents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  bucket_id text NOT NULL,
  object_path text NOT NULL,
  staging_key text NOT NULL UNIQUE,
  size_bytes bigint NOT NULL,
  content_type text NOT NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','processing','complete','failed')),
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(bucket_id, object_path)
);
CREATE INDEX IF NOT EXISTS threadline_upload_intents_expiry_idx ON public.threadline_upload_intents(expires_at);
ALTER TABLE public.threadline_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.threadline_auth_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.threadline_mfa_factors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.threadline_upload_intents ENABLE ROW LEVEL SECURITY;

`;

const files = (await readdir(source)).filter((name) => name.endsWith(".sql")).sort();
const chunks = [compatibility];
const sourceSql = [];
for (const name of files) {
  let sql = await readFile(resolve(source, name), "utf8");
  // Realtime is replaced by the API's authenticated SSE invalidation stream.
  sql = sql.replace(/-- ============ REALTIME ============\s*do \$\$[\s\S]*?\$\$;\s*/m, "");
  sourceSql.push(sql);
  chunks.push(`\n-- Source migration: ${name}\n`, sql);
}
chunks.push(`
-- Recreate Supabase's baseline SQL privileges, then replay source grant/revoke
-- statements in migration order so explicit restrictions remain in force.
GRANT USAGE ON SCHEMA public, auth, storage TO authenticated, service_role;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO authenticated, service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated, service_role;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO service_role;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO service_role;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA storage TO service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA storage TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA storage TO authenticated;
GRANT SELECT ON storage.buckets TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON storage.objects TO authenticated;
GRANT ALL PRIVILEGES ON public.threadline_sessions, public.threadline_auth_tokens, public.threadline_mfa_factors,
  public.threadline_upload_intents TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON auth.users TO service_role;
`);

for (const sql of sourceSql) {
  for (const statement of sql.match(/^\s*(?:GRANT|REVOKE)\b[\s\S]*?;/gim) ?? []) {
    chunks.push(`\n-- Preserve a source migration privilege rule.\n${statement.trim()}\n`);
  }
}

chunks.push(`
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'threadline_app') THEN
    EXECUTE 'GRANT authenticated, service_role TO threadline_app';
  END IF;
END $$;
`);

await mkdir(dirname(output), { recursive: true });
await writeFile(output, chunks.join(""));
console.log(`Wrote ${output} from ${files.length} Supabase schema migrations.`);
