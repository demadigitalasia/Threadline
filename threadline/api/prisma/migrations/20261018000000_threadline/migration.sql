-- Standalone PostgreSQL compatibility layer replacing Supabase Auth/Storage.
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


-- Source migration: 20251017000000_threadline_core.sql
-- Threadline core schema — backend real (MVP3).
-- Dijalankan pada Supabase self-hosted (PostgreSQL 17 bundle) maupun Supabase CLI lokal.
-- Kontrak: TECHNICAL-CONTRACT.md §2-§5. RLS adalah penjaga akhir; UI tidak dipercaya.

-- ============ ENUMS ============
do $$ begin
  create type job_status as enum ('Belum Ditugaskan','Antre','Dikerjakan','MintaACC','Revisi','ACC','Dibatalkan');
exception when duplicate_object then null; end $$;

do $$ begin
  create type job_priority as enum ('normal','express');
exception when duplicate_object then null; end $$;

do $$ begin
  create type job_type as enum ('Fullprint','Printing Depan Saja','Jersey + Celana','Jaket');
exception when duplicate_object then null; end $$;

do $$ begin
  create type submission_decision as enum ('pending','approved','revision_requested');
exception when duplicate_object then null; end $$;

do $$ begin
  create type upload_state as enum ('active','committed','released','expired');
exception when duplicate_object then null; end $$;

-- ============ TABLES ============
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null unique,
  role text not null default 'freelance' check (role in ('admin','freelance')),
  last_seen timestamptz not null default now()
);

create table if not exists public.profile_role_events (
  id uuid primary key default gen_random_uuid(),
  target_profile_id uuid not null references public.profiles(id) on delete cascade,
  old_role text not null,
  new_role text not null check (new_role in ('admin','freelance')),
  actor_profile_id uuid references public.profiles(id) on delete set null,
  actor_label text not null,
  reason text not null,
  created_at timestamptz not null default now()
);

create sequence if not exists public.threadline_job_seq start 1001;

create table if not exists public.jobs (
  id text primary key check (id ~ '^JRS-[0-9]+$'),
  tim text not null,
  jenis job_type not null,
  qty integer not null check (qty >= 1),
  deadline timestamptz not null,
  fee bigint not null check (fee >= 0),
  approved_fee bigint check (approved_fee is null or approved_fee >= 0),
  approved_for_profile_id uuid references public.profiles(id) on delete restrict,
  assignee_profile_id uuid references public.profiles(id) on delete set null,
  status job_status not null default 'Belum Ditugaskan',
  priority job_priority not null default 'normal',
  brief text not null default '-',
  ref text,
  current_submission_id uuid,
  approved_submission_id uuid,
  created_at timestamptz not null default now(),
  antre_since timestamptz,
  cancelled_at timestamptz,
  cancelled_by_profile_id uuid references public.profiles(id) on delete set null,
  cancellation_reason text,
  revision integer not null default 1,
  constraint jobs_cancel_fields check (
    (status = 'Dibatalkan' and cancelled_at is not null and cancellation_reason is not null)
    or (status <> 'Dibatalkan')
  ),
  constraint jobs_active_have_assignee check (
    (status in ('Antre','Dikerjakan','MintaACC','Revisi') and assignee_profile_id is not null)
    or (status not in ('Antre','Dikerjakan','MintaACC','Revisi'))
  )
);

create table if not exists public.job_files (
  id uuid primary key default gen_random_uuid(),
  job_id text not null references public.jobs(id) on delete cascade,
  name text not null,
  path text not null,
  file_kind text not null check (file_kind in ('PDF','CDR','PNG','JPEG')),
  size_bytes bigint not null check (size_bytes > 0 and size_bytes <= 1073741824),
  uploaded_by_profile_id uuid references public.profiles(id) on delete set null,
  uploaded_at timestamptz not null default now(),
  expired_at timestamptz,
  constraint job_files_path_unique unique (path)
);
create index if not exists job_files_job_idx on public.job_files(job_id);

create table if not exists public.job_upload_reservations (
  id uuid primary key default gen_random_uuid(),
  job_id text not null references public.jobs(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  size_bytes bigint not null check (size_bytes > 0 and size_bytes <= 1073741824),
  state upload_state not null default 'active',
  expires_at timestamptz not null default (now() + interval '1 hour'),
  created_at timestamptz not null default now()
);
create index if not exists reservations_job_idx on public.job_upload_reservations(job_id);

create table if not exists public.job_submissions (
  id uuid primary key default gen_random_uuid(),
  job_id text not null references public.jobs(id) on delete cascade,
  version integer not null check (version >= 1),
  submitted_by_profile_id uuid references public.profiles(id) on delete set null,
  submitted_at timestamptz not null default now(),
  note text,
  decision submission_decision not null default 'pending',
  review_note text,
  reviewed_by_profile_id uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  constraint job_submissions_version_unique unique (job_id, version)
);

create table if not exists public.job_submission_files (
  submission_id uuid not null references public.job_submissions(id) on delete cascade,
  job_file_id uuid not null references public.job_files(id) on delete restrict,
  primary key (submission_id, job_file_id)
);

create table if not exists public.job_events (
  id uuid primary key default gen_random_uuid(),
  job_id text not null references public.jobs(id) on delete cascade,
  actor_profile_id uuid references public.profiles(id) on delete set null,
  event_type text not null,
  from_status job_status,
  to_status job_status,
  reason text,
  details jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index if not exists job_events_job_idx on public.job_events(job_id);

create table if not exists public.app_settings (
  id integer primary key check (id = 1),
  urgency_sla_hours numeric not null default 3 check (urgency_sla_hours > 0 and urgency_sla_hours <= 72),
  updated_at timestamptz not null default now(),
  updated_by_profile_id uuid references public.profiles(id) on delete set null
);
insert into public.app_settings(id) values (1) on conflict (id) do nothing;

create table if not exists public.chat_threads (
  id uuid primary key default gen_random_uuid(),
  freelance_profile_id uuid not null unique references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.chat_threads(id) on delete cascade,
  sender_profile_id uuid references public.profiles(id) on delete set null,
  text varchar(500) not null check (char_length(text) >= 1 and char_length(text) <= 500),
  created_at timestamptz not null default now()
);
create index if not exists chat_messages_thread_idx on public.chat_messages(thread_id);

-- FK jobs -> submissions (setelah kedua tabel ada) + guard satu-job
alter table public.jobs
  add constraint jobs_current_sub_fk foreign key (current_submission_id) references public.job_submissions(id) on delete set null not valid,
  add constraint jobs_approved_sub_fk foreign key (approved_submission_id) references public.job_submissions(id) on delete set null not valid;

create or replace function public.check_submission_job() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_job text;
begin
  select s.job_id into v_job from public.job_submissions s where s.id = NEW.current_submission_id;
  if v_job is not null and v_job <> NEW.id then
    raise exception 'FORBIDDEN: submission milik job lain';
  end if;
  select s.job_id into v_job from public.job_submissions s where s.id = NEW.approved_submission_id;
  if v_job is not null and v_job <> NEW.id then
    raise exception 'FORBIDDEN: submission milik job lain';
  end if;
  return NEW;
end $$;
drop trigger if exists trg_jobs_sub_job on public.jobs;
create trigger trg_jobs_sub_job before insert or update on public.jobs
  for each row execute function public.check_submission_job();

-- ============ HELPERS ============
create or replace function public.my_uid() returns uuid
language sql stable security definer set search_path = public as
$$ select auth.uid() $$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
$$;

create or replace function public.is_service_role() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((auth.jwt() ->> 'role'), 'service_role') = 'service_role'
$$;
-- ============ TRIGGERS ============
-- Profil + thread otomatis saat user Auth dibuat (role awal freelance).
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare v_name text;
begin
  v_name := coalesce(nullif(NEW.raw_user_meta_data ->> 'name', ''), split_part(NEW.email, '@', 1));
  insert into public.profiles(id, name, role) values (NEW.id, v_name, 'freelance')
  on conflict (id) do nothing;
  insert into public.chat_threads(freelance_profile_id)
  values (NEW.id) on conflict do nothing;
  return NEW;
exception when unique_violation then
  -- nama bentrok: tambah suffix pendek
  insert into public.profiles(id, name, role)
  values (NEW.id, v_name || '-' || substr(md5(NEW.id::text), 1, 4), 'freelance')
  on conflict (id) do nothing;
  insert into public.chat_threads(freelance_profile_id)
  values (NEW.id) on conflict do nothing;
  return NEW;
end $$;
drop trigger if exists trg_auth_new_user on auth.users;
create trigger trg_auth_new_user after insert on auth.users
  for each row execute function public.handle_new_user();

-- Role hanya berubah via service_role (operator). Klien biasa ditolak.
create or replace function public.guard_profile_role() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if NEW.role is distinct from OLD.role and not public.is_service_role() then
    raise exception 'FORBIDDEN: role hanya via operator';
  end if;
  return NEW;
end $$;
drop trigger if exists trg_guard_role on public.profiles;
create trigger trg_guard_role before update on public.profiles
  for each row execute function public.guard_profile_role();

-- ============ RLS ============
alter table public.profiles enable row level security;
alter table public.profile_role_events enable row level security;
alter table public.jobs enable row level security;
alter table public.job_files enable row level security;
alter table public.job_upload_reservations enable row level security;
alter table public.job_submissions enable row level security;
alter table public.job_submission_files enable row level security;
alter table public.job_events enable row level security;
alter table public.app_settings enable row level security;
alter table public.chat_threads enable row level security;
alter table public.chat_messages enable row level security;

-- profiles: admin semua; freelance miliknya + admin lain (lawan bicara); antar-freelance tersembunyi
create policy prof_admin_all on public.profiles for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy prof_self_select on public.profiles for select to authenticated using (id = public.my_uid());
create policy prof_self_update on public.profiles for update to authenticated
  using (id = public.my_uid()) with check (id = public.my_uid());
create policy prof_admin_names on public.profiles for select to authenticated using (role = 'admin');

-- role events: baca sesuai visibilitas profil; tulis hanya service_role (tanpa policy insert)
create policy pre_admin on public.profile_role_events for select to authenticated using (public.is_admin());
create policy pre_self on public.profile_role_events for select to authenticated using (target_profile_id = public.my_uid());

-- jobs: admin penuh; freelance hanya yang ditugaskan; insert/update/delete langsung hanya admin
-- (freelance mutasi lewat RPC; trigger membekukan field ACC)
create policy jobs_admin_all on public.jobs for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy jobs_freelance_read on public.jobs for select to authenticated
  using (assignee_profile_id = public.my_uid());

create or replace function public.guard_job_approved() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_service_role() then return NEW; end if;
  if OLD.status = 'ACC' and (
    NEW.status is distinct from OLD.status or
    NEW.approved_fee is distinct from OLD.approved_fee or
    NEW.approved_for_profile_id is distinct from OLD.approved_for_profile_id or
    NEW.approved_submission_id is distinct from OLD.approved_submission_id or
    NEW.assignee_profile_id is distinct from OLD.assignee_profile_id
  ) then
    raise exception 'FORBIDDEN: job ACC terkunci';
  end if;
  if OLD.status = 'Dibatalkan' and NEW.status is distinct from OLD.status then
    raise exception 'FORBIDDEN: job Dibatalkan terminal';
  end if;
  return NEW;
end $$;
drop trigger if exists trg_guard_approved on public.jobs;
create trigger trg_guard_approved before update on public.jobs
  for each row execute function public.guard_job_approved();

-- job_files: admin kelola (trigger kunci yang terikat); freelance baca+tambah di job miliknya
create policy jf_admin_all on public.job_files for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy jf_free_read on public.job_files for select to authenticated
  using (exists (select 1 from public.jobs j where j.id = job_id and j.assignee_profile_id = public.my_uid()));
create policy jf_free_insert on public.job_files for insert to authenticated
  with check (exists (select 1 from public.jobs j where j.id = job_id and j.assignee_profile_id = public.my_uid()));

-- reservations: pemilik + admin (baca); tulis via RPC (tanpa policy insert/update client)
create policy res_admin on public.job_upload_reservations for select to authenticated using (public.is_admin());
create policy res_owner on public.job_upload_reservations for select to authenticated using (profile_id = public.my_uid());
-- submissions: visibilitas mengikuti job; tulis hanya via RPC
create policy sub_admin on public.job_submissions for select to authenticated using (public.is_admin());
create policy sub_free on public.job_submissions for select to authenticated
  using (exists (select 1 from public.jobs j where j.id = job_id and j.assignee_profile_id = public.my_uid()));

create policy subl_admin on public.job_submission_files for select to authenticated using (public.is_admin());
create policy subl_free on public.job_submission_files for select to authenticated
  using (exists (select 1 from public.job_submissions s join public.jobs j on j.id = s.job_id
                 where s.id = submission_id and j.assignee_profile_id = public.my_uid()));

-- events: visibilitas mengikuti job; klien hanya boleh insert komentar timeline
create policy ev_admin on public.job_events for select to authenticated using (public.is_admin());
create policy ev_free on public.job_events for select to authenticated
  using (exists (select 1 from public.jobs j where j.id = job_id and j.assignee_profile_id = public.my_uid()));
create policy ev_comment on public.job_events for insert to authenticated
  with check (event_type = 'comment'
    and (public.is_admin()
      or exists (select 1 from public.jobs j where j.id = job_id and j.assignee_profile_id = public.my_uid())));

-- settings: semua baca; ubah hanya admin
create policy set_read on public.app_settings for select to authenticated using (true);
create policy set_admin on public.app_settings for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- threads: admin semua; freelance miliknya (ada sejak akun dibuat)
create policy th_admin on public.chat_threads for select to authenticated using (public.is_admin());
create policy th_free on public.chat_threads for select to authenticated using (freelance_profile_id = public.my_uid());

-- messages: admin semua; freelance thread miliknya; pengirim = sesi (payload tak dipercaya)
create policy msg_admin on public.chat_messages for select to authenticated using (public.is_admin());
create policy msg_free_read on public.chat_messages for select to authenticated
  using (exists (select 1 from public.chat_threads t where t.id = thread_id and t.freelance_profile_id = public.my_uid()));
create policy msg_send on public.chat_messages for insert to authenticated
  with check (sender_profile_id = public.my_uid()
    and (public.is_admin()
      or exists (select 1 from public.chat_threads t where t.id = thread_id and t.freelance_profile_id = public.my_uid())));

-- ============ STORAGE (bucket privat job-files) ============
insert into storage.buckets(id, name, public, file_size_limit)
values ('job-files', 'job-files', false, 1073741824)
on conflict (id) do update set public = false, file_size_limit = 1073741824;

create policy sto_admin_read on storage.objects for select to authenticated
  using (bucket_id = 'job-files' and public.is_admin());
create policy sto_free_read on storage.objects for select to authenticated
  using (bucket_id = 'job-files'
    and exists (select 1 from public.jobs j
                where j.id = split_part(name, '/', 1) and j.assignee_profile_id = public.my_uid()));
create policy sto_admin_write on storage.objects for insert to authenticated
  with check (bucket_id = 'job-files' and public.is_admin());
create policy sto_free_write on storage.objects for insert to authenticated
  with check (bucket_id = 'job-files'
    and exists (select 1 from public.jobs j
                where j.id = split_part(name, '/', 1) and j.assignee_profile_id = public.my_uid()));
create policy sto_admin_mod on storage.objects for update to authenticated
  using (bucket_id = 'job-files' and public.is_admin()) with check (bucket_id = 'job-files');
create policy sto_admin_del on storage.objects for delete to authenticated
  using (bucket_id = 'job-files' and public.is_admin());
-- ============ RPC ATOMIK ============
-- create_job (admin)
create or replace function public.create_job(
  p_tim text, p_jenis job_type, p_qty int, p_deadline timestamptz,
  p_fee bigint, p_priority job_priority, p_brief text, p_ref text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id text;
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'Hanya Admin'); end if;
  if p_qty < 1 then return jsonb_build_object('ok', false, 'error', 'Qty minimal 1'); end if;
  if p_fee < 0 then return jsonb_build_object('ok', false, 'error', 'Fee tidak valid'); end if;
  v_id := 'JRS-' || nextval('public.threadline_job_seq')::text;
  insert into public.jobs(id, tim, jenis, qty, deadline, fee, priority, brief, ref)
  values (v_id, nullif(trim(p_tim), ''), p_jenis, p_qty, p_deadline, p_fee, p_priority, nullif(trim(p_brief), ''));
  insert into public.job_events(job_id, actor_profile_id, event_type, to_status)
  values (v_id, public.my_uid(), 'create', 'Belum Ditugaskan');
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- assign_job (admin): cek presence+kapasitas atomik, serialize per target
create or replace function public.assign_job(
  p_job text, p_target uuid, p_reason text, p_expected_rev int
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype; v_t public.profiles%rowtype; v_active int;
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'Hanya Admin'); end if;
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.status in ('ACC','Dibatalkan') then return jsonb_build_object('ok', false, 'error', 'Job terminal'); end if;
  if v_job.status = 'MintaACC' then return jsonb_build_object('ok', false, 'error', 'MintaACC harus diputuskan dulu'); end if;
  select * into v_t from public.profiles where id = p_target;
  if not found or v_t.role <> 'freelance' then return jsonb_build_object('ok', false, 'error', 'Target bukan Freelance'); end if;
  perform pg_advisory_xact_lock(hashtext('assign:' || p_target::text)::bigint);
  if now() - v_t.last_seen >= interval '90 seconds' and not (v_job.assignee_profile_id = p_target and v_job.status = 'Antre') then
    return jsonb_build_object('ok', false, 'error', 'Freelance offline');
  end if;
  select count(*) into v_active from public.jobs
    where assignee_profile_id = p_target and status in ('Antre','Dikerjakan','MintaACC','Revisi') and id <> p_job;
  if v_active >= 4 then return jsonb_build_object('ok', false, 'error', 'Freelance penuh'); end if;
  if v_job.assignee_profile_id is not null and v_job.assignee_profile_id <> p_target
     and v_job.status in ('Dikerjakan','Revisi') and nullif(trim(coalesce(p_reason,'')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Pengalihan Dikerjakan/Revisi wajib alasan');
  end if;
  if v_job.assignee_profile_id is null then
    update public.jobs set assignee_profile_id = p_target, status = 'Antre',
      antre_since = now(), revision = revision + 1 where id = p_job;
    insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, reason)
    values (p_job, public.my_uid(), 'assign', v_job.status, 'Antre', nullif(trim(coalesce(p_reason,'')), ''));
  else
    update public.jobs set assignee_profile_id = p_target,
      antre_since = case when v_job.status = 'Antre' then now() else antre_since end,
      revision = revision + 1 where id = p_job;
    insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, reason)
    values (p_job, public.my_uid(), 'reassign', v_job.status, v_job.status, nullif(trim(coalesce(p_reason,'')), ''));
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- transition_job: Antre<->Dikerjakan dsb (ACC/Revisi lewat review_submission)
create or replace function public.transition_job(
  p_job text, p_to job_status, p_reason text, p_expected_rev int
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype; v_admin boolean;
begin
  v_admin := public.is_admin();
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.status in ('ACC','Dibatalkan') then return jsonb_build_object('ok', false, 'error', 'Job terminal'); end if;
  if not v_admin and v_job.assignee_profile_id is distinct from public.my_uid() then
    return jsonb_build_object('ok', false, 'error', 'Bukan job milikmu');
  end if;
  if p_to in ('ACC','Revisi','MintaACC') then
    return jsonb_build_object('ok', false, 'error', 'Gunakan alur pengajuan/review');
  end if;
  if not ((v_job.status = 'Antre' and p_to = 'Dikerjakan')
       or (v_job.status = 'Revisi' and p_to = 'Dikerjakan')) then
    return jsonb_build_object('ok', false, 'error', 'Transisi tidak diizinkan');
  end if;
  update public.jobs set status = p_to, revision = revision + 1 where id = p_job;
  insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, reason)
  values (p_job, public.my_uid(), 'status', v_job.status, p_to, nullif(trim(coalesce(p_reason,'')), ''));
  return jsonb_build_object('ok', true);
end $$;

-- submit_for_acc: kunci daftar file + MintaACC atomik
create or replace function public.submit_for_acc(
  p_job text, p_file_ids uuid[], p_note text, p_expected_rev int
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype; v_sub uuid; v_ver int; v_f uuid;
begin
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if not public.is_admin() and v_job.assignee_profile_id is distinct from public.my_uid() then
    return jsonb_build_object('ok', false, 'error', 'Bukan job milikmu');
  end if;
  if v_job.status not in ('Dikerjakan','Revisi') then
    return jsonb_build_object('ok', false, 'error', 'Submission hanya dari Dikerjakan/Revisi');
  end if;
  if coalesce(array_length(p_file_ids, 1), 0) < 1 then
    return jsonb_build_object('ok', false, 'error', 'Pilih >=1 file');
  end if;
  foreach v_f in array p_file_ids loop
    if not exists (select 1 from public.job_files f where f.id = v_f and f.job_id = p_job) then
      return jsonb_build_object('ok', false, 'error', 'File tidak valid');
    end if;
  end loop;
  select coalesce(max(version), 0) + 1 into v_ver from public.job_submissions where job_id = p_job;
  v_sub := gen_random_uuid();
  insert into public.job_submissions(id, job_id, version, submitted_by_profile_id, note)
  values (v_sub, p_job, v_ver, public.my_uid(), nullif(trim(coalesce(p_note,'')), ''));
  insert into public.job_submission_files(submission_id, job_file_id)
  select v_sub, unnest(p_file_ids);
  update public.jobs set status = 'MintaACC', current_submission_id = v_sub, revision = revision + 1 where id = p_job;
  insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status)
  values (p_job, public.my_uid(), 'submit', v_job.status, 'MintaACC');
  return jsonb_build_object('ok', true, 'submission_id', v_sub);
end $$;
-- review_submission (admin): ACC membekukan fee+penerima+versi; Revisi wajib alasan
create or replace function public.review_submission(
  p_submission uuid, p_decision text, p_review_note text, p_expected_rev int
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_sub public.job_submissions%rowtype; v_job public.jobs%rowtype;
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'Hanya Admin'); end if;
  select * into v_sub from public.job_submissions where id = p_submission;
  if not found then return jsonb_build_object('ok', false, 'error', 'Submission tidak ditemukan'); end if;
  select * into v_job from public.jobs where id = v_sub.job_id for update;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.status <> 'MintaACC' or v_job.current_submission_id is distinct from p_submission or v_sub.decision <> 'pending' then
    return jsonb_build_object('ok', false, 'error', 'Bukan pengajuan aktif');
  end if;
  if p_decision = 'approved' then
    update public.job_submissions set decision = 'approved', reviewed_by_profile_id = public.my_uid(), reviewed_at = now() where id = p_submission;
    update public.jobs set status = 'ACC', approved_fee = fee, approved_for_profile_id = assignee_profile_id,
      approved_submission_id = p_submission, revision = revision + 1 where id = v_job.id;
    insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status)
    values (v_job.id, public.my_uid(), 'approve', 'MintaACC', 'ACC');
  elsif p_decision = 'revision' then
    if nullif(trim(coalesce(p_review_note,'')), '') is null then
      return jsonb_build_object('ok', false, 'error', 'Revisi wajib alasan');
    end if;
    update public.job_submissions set decision = 'revision_requested', review_note = trim(p_review_note),
      reviewed_by_profile_id = public.my_uid(), reviewed_at = now() where id = p_submission;
    update public.jobs set status = 'Revisi', revision = revision + 1 where id = v_job.id;
    insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, reason)
    values (v_job.id, public.my_uid(), 'request_revision', 'MintaACC', 'Revisi', trim(p_review_note));
  else
    return jsonb_build_object('ok', false, 'error', 'Keputusan tidak dikenal');
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- cancel_job (admin): nonterminal + alasan wajib
create or replace function public.cancel_job(p_job text, p_reason text, p_expected_rev int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype;
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'Hanya Admin'); end if;
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.status in ('ACC','Dibatalkan') then return jsonb_build_object('ok', false, 'error', 'Job sudah terminal'); end if;
  if nullif(trim(coalesce(p_reason,'')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Alasan wajib');
  end if;
  update public.jobs set status = 'Dibatalkan', cancelled_at = now(),
    cancelled_by_profile_id = public.my_uid(), cancellation_reason = trim(p_reason), revision = revision + 1
    where id = p_job;
  insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, reason)
  values (p_job, public.my_uid(), 'cancel', v_job.status, 'Dibatalkan', trim(p_reason));
  return jsonb_build_object('ok', true);
end $$;

-- delete_job (admin): hanya Belum Ditugaskan tanpa aktivitas/file
create or replace function public.delete_job(p_job text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype;
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'Hanya Admin'); end if;
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.status <> 'Belum Ditugaskan' then return jsonb_build_object('ok', false, 'error', 'Hanya Belum Ditugaskan'); end if;
  if exists (select 1 from public.job_events where job_id = p_job)
     or exists (select 1 from public.job_submissions where job_id = p_job)
     or exists (select 1 from public.job_files where job_id = p_job) then
    return jsonb_build_object('ok', false, 'error', 'Ada aktivitas/file');
  end if;
  delete from public.jobs where id = p_job;
  return jsonb_build_object('ok', true);
end $$;

-- update_job_fields (admin): edit nonterminal; approved_* tak tersentuh
create or replace function public.update_job_fields(
  p_job text, p_expected_rev int, p_tim text, p_jenis job_type, p_qty int,
  p_deadline timestamptz, p_fee bigint, p_priority job_priority, p_brief text, p_ref text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype;
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'Hanya Admin'); end if;
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.status in ('ACC','Dibatalkan') then return jsonb_build_object('ok', false, 'error', 'Job terminal terkunci'); end if;
  update public.jobs set
    tim = coalesce(nullif(trim(p_tim), ''), tim),
    jenis = coalesce(p_jenis, jenis),
    qty = coalesce(p_qty, qty),
    deadline = coalesce(p_deadline, deadline),
    fee = coalesce(p_fee, fee),
    priority = coalesce(p_priority, priority),
    brief = coalesce(nullif(trim(p_brief), ''), brief),
    ref = coalesce(p_ref, ref),
    revision = revision + 1
    where id = p_job;
  return jsonb_build_object('ok', true);
end $$;

-- reserve_upload: kunci anggaran atomik per job (1 GiB/file, 10 GiB total)
create or replace function public.reserve_upload(p_job text, p_size bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype; v_total bigint; v_r uuid; v_admin boolean;
begin
  v_admin := public.is_admin();
  select * into v_job from public.jobs where id = p_job;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.status in ('ACC','Dibatalkan') then return jsonb_build_object('ok', false, 'error', 'Job terminal'); end if;
  if not v_admin and v_job.assignee_profile_id is distinct from public.my_uid() then
    return jsonb_build_object('ok', false, 'error', 'Bukan job milikmu');
  end if;
  if p_size <= 0 or p_size > 1073741824 then
    return jsonb_build_object('ok', false, 'error', 'Maks 1 GiB per file');
  end if;
  perform pg_advisory_xact_lock(hashtext(p_job)::bigint);
  delete from public.job_upload_reservations where job_id = p_job and state = 'active' and expires_at <= now();
  select coalesce(sum(size_bytes), 0) into v_total from public.job_files
    where job_id = p_job and expired_at is null;
  select v_total + coalesce(sum(size_bytes), 0) into v_total from public.job_upload_reservations
    where job_id = p_job and state = 'active' and expires_at > now();
  if v_total + p_size > 10737418240 then
    return jsonb_build_object('ok', false, 'error', 'Total melebihi 10 GiB per job');
  end if;
  insert into public.job_upload_reservations(job_id, profile_id, size_bytes)
  values (p_job, public.my_uid(), p_size) returning id into v_r;
  return jsonb_build_object('ok', true, 'reservation_id', v_r);
end $$;

create or replace function public.release_upload_reservation(p_reservation uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  update public.job_upload_reservations set state = 'released'
    where id = p_reservation and profile_id = public.my_uid() and state = 'active';
  return jsonb_build_object('ok', true);
end $$;

-- promote_admin: HANYA service_role (operator proyek). UI tidak pernah memanggil.
create or replace function public.promote_admin(p_target uuid, p_reason text, p_actor_label text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_old text;
begin
  if not public.is_service_role() then
    return jsonb_build_object('ok', false, 'error', 'Hanya operator');
  end if;
  select role into v_old from public.profiles where id = p_target;
  if not found then return jsonb_build_object('ok', false, 'error', 'Profil tidak ditemukan'); end if;
  update public.profiles set role = 'admin' where id = p_target;
  insert into public.profile_role_events(target_profile_id, old_role, new_role, actor_profile_id, actor_label, reason)
  values (p_target, v_old, 'admin', null, coalesce(p_actor_label, 'operator'), coalesce(p_reason, 'promosi awal'));
  return jsonb_build_object('ok', true);
end $$;


-- Source migration: 20251017000001_file_reservation_link.sql
-- Kaitan eksplisit reservation -> file agar commit kuota tepat sasaran,
-- plus backstop kuota untuk insert langsung tanpa reservation.

alter table public.job_files
  add column if not exists reservation_id uuid references public.job_upload_reservations(id) on delete set null;

drop trigger if exists trg_job_files_guard on public.job_files;
drop function if exists public.guard_job_file();

create or replace function public.guard_job_file() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_locked boolean;
  v_res uuid;
  v_total bigint;
begin
  if TG_OP = 'DELETE' then
    if public.is_service_role() then return OLD; end if;
    select exists (select 1 from public.job_submission_files b where b.job_file_id = OLD.id) into v_locked;
    if v_locked then
      raise exception 'FILE_LOCKED: file terikat submission';
    end if;
    return OLD;
  end if;

  if TG_OP = 'INSERT' then
    if public.is_service_role() then return NEW; end if;
    perform pg_advisory_xact_lock(hashtext(NEW.job_id)::bigint);
    if NEW.reservation_id is not null then
      select r.id into v_res from public.job_upload_reservations r
        where r.id = NEW.reservation_id and r.job_id = NEW.job_id
          and r.profile_id = public.my_uid() and r.state = 'active' and r.expires_at > now();
      if v_res is null then
        raise exception 'FORBIDDEN: reservation tidak valid';
      end if;
      update public.job_upload_reservations set state = 'committed' where id = v_res;
    else
      -- insert tanpa reservation: cek kuota penuh sebagai backstop
      select coalesce(sum(f.size_bytes),0) into v_total
        from public.job_files f where f.job_id = NEW.job_id and f.expired_at is null;
      select v_total + coalesce(sum(r.size_bytes),0) into v_total
        from public.job_upload_reservations r
        where r.job_id = NEW.job_id and r.state = 'active' and r.expires_at > now();
      if v_total + NEW.size_bytes > 10737418240 then
        raise exception 'QUOTA_EXCEEDED: total melebihi 10 GiB per job';
      end if;
    end if;
    return NEW;
  end if;

  -- UPDATE
  if NEW.expired_at is distinct from OLD.expired_at and not public.is_service_role() then
    raise exception 'FORBIDDEN: expired_at hanya oleh retensi';
  end if;
  if public.is_service_role() then return NEW; end if;
  select exists (select 1 from public.job_submission_files b where b.job_file_id = NEW.id) into v_locked;
  if v_locked then
    raise exception 'FILE_LOCKED: file terikat submission';
  end if;
  return NEW;
end $$;

create trigger trg_job_files_guard
  before insert or update or delete on public.job_files
  for each row execute function public.guard_job_file();

-- Source migration: 20251017000002_grants_and_kind.sql
-- Hak akses tabel/fungsi untuk peran aplikasi.
-- Tanpa ini RLS pun tak bisa dievaluasi (permission denied).

grant usage on schema public to anon, authenticated;

grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;

grant all privileges on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;

alter default privileges in schema public grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema public grant usage, select on sequences to authenticated;
alter default privileges in schema public grant all on tables to service_role;

-- RPC data: cabut dari PUBLIC/anon, buka hanya untuk authenticated (+service_role di atas).
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('create_job','assign_job','transition_job','submit_for_acc','review_submission',
        'cancel_job','delete_job','update_job_fields','reserve_upload','release_upload_reservation','promote_admin')
  loop
    execute 'revoke all on function ' || f.sig || ' from public, anon';
    execute 'grant execute on function ' || f.sig || ' to authenticated, service_role';
  end loop;
end $$;

-- Validasi jenis file dari EKSTENSI NAMA di server (nilai file_kind klien tak dipercaya).
create or replace function public.validate_job_file_kind() returns trigger
language plpgsql security definer set search_path = public as $$
declare ext text;
begin
  ext := lower(split_part(NEW.name, '.', array_length(string_to_array(NEW.name, '.'), 1)));
  if ext = 'jpg' then ext := 'jpeg'; end if;
  if ext not in ('pdf','cdr','png','jpeg') then
    raise exception 'INVALID_TYPE: hanya PDF/CDR/PNG/JPEG';
  end if;
  if upper(ext) <> NEW.file_kind then
    raise exception 'INVALID_TYPE: file_kind tidak cocok ekstensi';
  end if;
  return NEW;
end $$;
drop trigger if exists trg_validate_kind on public.job_files;
create trigger trg_validate_kind before insert on public.job_files
  for each row execute function public.validate_job_file_kind();

-- Source migration: 20251017000003_fix_create_job.sql
-- Perbaikan create_job: values kekurangan p_ref (9 kolom, 8 values).

create or replace function public.create_job(
  p_tim text, p_jenis job_type, p_qty int, p_deadline timestamptz,
  p_fee bigint, p_priority job_priority, p_brief text, p_ref text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id text;
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'Hanya Admin'); end if;
  if p_qty < 1 then return jsonb_build_object('ok', false, 'error', 'Qty minimal 1'); end if;
  if p_fee < 0 then return jsonb_build_object('ok', false, 'error', 'Fee tidak valid'); end if;
  v_id := 'JRS-' || nextval('public.threadline_job_seq')::text;
  insert into public.jobs(id, tim, jenis, qty, deadline, fee, priority, brief, ref)
  values (v_id, nullif(trim(p_tim), ''), p_jenis, p_qty, p_deadline, p_fee, p_priority,
    nullif(trim(p_brief), ''), nullif(trim(coalesce(p_ref, '')), ''));
  insert into public.job_events(job_id, actor_profile_id, event_type, to_status)
  values (v_id, public.my_uid(), 'create', 'Belum Ditugaskan');
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- Source migration: 20251017000004_capacity_setting.sql
-- D-26: batas job aktif menjadi pengaturan global (default 4, 1-20), diubah Admin.

alter table public.app_settings
  add column if not exists max_active_jobs integer not null default 4
  check (max_active_jobs >= 1 and max_active_jobs <= 20);

create or replace function public.assign_job(
  p_job text, p_target uuid, p_reason text, p_expected_rev int
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype; v_t public.profiles%rowtype; v_active int; v_max int;
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'Hanya Admin'); end if;
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.status in ('ACC','Dibatalkan') then return jsonb_build_object('ok', false, 'error', 'Job terminal'); end if;
  if v_job.status = 'MintaACC' then return jsonb_build_object('ok', false, 'error', 'MintaACC harus diputuskan dulu'); end if;
  select * into v_t from public.profiles where id = p_target;
  if not found or v_t.role <> 'freelance' then return jsonb_build_object('ok', false, 'error', 'Target bukan Freelance'); end if;
  select coalesce(max(max_active_jobs), 4) into v_max from public.app_settings where id = 1;
  perform pg_advisory_xact_lock(hashtext('assign:' || p_target::text)::bigint);
  if now() - v_t.last_seen >= interval '90 seconds' and not (v_job.assignee_profile_id = p_target and v_job.status = 'Antre') then
    return jsonb_build_object('ok', false, 'error', 'Freelance offline');
  end if;
  select count(*) into v_active from public.jobs
    where assignee_profile_id = p_target and status in ('Antre','Dikerjakan','MintaACC','Revisi') and id <> p_job;
  if v_active >= v_max then
    return jsonb_build_object('ok', false, 'error', 'Freelance penuh (batas ' || v_max || ' job aktif)');
  end if;
  if v_job.assignee_profile_id is not null and v_job.assignee_profile_id <> p_target
     and v_job.status in ('Dikerjakan','Revisi') and nullif(trim(coalesce(p_reason,'')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Pengalihan Dikerjakan/Revisi wajib alasan');
  end if;
  if v_job.assignee_profile_id is null then
    update public.jobs set assignee_profile_id = p_target, status = 'Antre',
      antre_since = now(), revision = revision + 1 where id = p_job;
    insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, reason)
    values (p_job, public.my_uid(), 'assign', v_job.status, 'Antre', nullif(trim(coalesce(p_reason,'')), ''));
  else
    update public.jobs set assignee_profile_id = p_target,
      antre_since = case when v_job.status = 'Antre' then now() else antre_since end,
      revision = revision + 1 where id = p_job;
    insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, reason)
    values (p_job, public.my_uid(), 'reassign', v_job.status, v_job.status, nullif(trim(coalesce(p_reason,'')), ''));
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- Source migration: 20261017000000_role_hierarchy.sql
-- Threadline role hierarchy and account access management.
-- Super Admin > Finance > Admin > Freelance. Authorization is enforced here,
-- not only by hiding client-side navigation.

alter table public.profiles
  add column if not exists is_active boolean not null default true;

alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('super_admin', 'finance', 'admin', 'freelance'));

alter table public.profile_role_events
  add column if not exists old_active boolean not null default true,
  add column if not exists new_active boolean not null default true;
alter table public.profile_role_events drop constraint if exists profile_role_events_new_role_check;
alter table public.profile_role_events add constraint profile_role_events_new_role_check
  check (new_role in ('super_admin', 'finance', 'admin', 'freelance'));

-- Disabled profiles keep access to their own profile row so the UI can explain
-- the state, but active-only identity is returned to data access/RPC checks.
create or replace function public.my_uid() returns uuid
language sql stable security definer set search_path = public, auth as $$
  select case when exists (
    select 1 from public.profiles p where p.id = auth.uid() and p.is_active
  ) then auth.uid() else null end
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.is_active and p.role in ('admin', 'super_admin')
  )
$$;

create or replace function public.is_super_admin() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.is_active and p.role = 'super_admin'
  )
$$;

create or replace function public.is_finance() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.is_active and p.role = 'finance'
  )
$$;

create or replace function public.is_freelance() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.is_active and p.role = 'freelance'
  )
$$;

create or replace function public.guard_profile_role() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (NEW.role is distinct from OLD.role or NEW.is_active is distinct from OLD.is_active)
     and not public.is_service_role()
     and not (
       current_setting('threadline.allow_profile_access_update', true) = 'on'
       and public.is_super_admin()
     ) then
    raise exception 'FORBIDDEN: perubahan role/akses hanya oleh Super Admin';
  end if;
  return NEW;
end $$;

-- Replace broad/old policies so Finance never inherits Freelance access after
-- a role change, and only sees approved jobs needed for fee reconciliation.
drop policy if exists prof_admin_all on public.profiles;
drop policy if exists prof_self_select on public.profiles;
drop policy if exists prof_self_update on public.profiles;
drop policy if exists prof_admin_names on public.profiles;
drop policy if exists prof_admin_update on public.profiles;
drop policy if exists prof_finance_recipients on public.profiles;
create policy prof_admin_select on public.profiles for select to authenticated using (public.is_admin());
create policy prof_self_select on public.profiles for select to authenticated
  using (id = auth.uid());
create policy prof_self_update on public.profiles for update to authenticated
  using (id = public.my_uid()) with check (id = public.my_uid());
create policy prof_freelance_admin_names on public.profiles for select to authenticated
  using (public.is_freelance() and role in ('admin', 'super_admin'));

-- Finance needs recipient labels for the fee recap, not presence or account
-- state. Return only identifiers and names for profiles tied to ACC jobs.
create or replace function public.finance_acc_recipients()
returns table(profile_id uuid, profile_name text)
language sql stable security definer set search_path = public as $$
  select distinct p.id, p.name
  from public.profiles p
  join public.jobs j on coalesce(j.approved_for_profile_id, j.assignee_profile_id) = p.id
  where public.is_finance() and j.status = 'ACC'
$$;

-- The recap needs only an approval timestamp, not access to raw job events.
create or replace function public.finance_acc_approval_times()
returns table(job_id text, approved_at timestamptz)
language sql stable security definer set search_path = public as $$
  select e.job_id, max(e.created_at)
  from public.job_events e
  join public.jobs j on j.id = e.job_id
  where public.is_finance() and j.status = 'ACC' and e.event_type = 'approve'
  group by e.job_id
$$;

drop policy if exists pre_admin on public.profile_role_events;
drop policy if exists pre_self on public.profile_role_events;
create policy pre_super_admin on public.profile_role_events for select to authenticated
  using (public.is_super_admin());

drop policy if exists jobs_admin_all on public.jobs;
drop policy if exists jobs_freelance_read on public.jobs;
create policy jobs_admin_all on public.jobs for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy jobs_freelance_read on public.jobs for select to authenticated
  using (public.is_freelance() and assignee_profile_id = public.my_uid());
create policy jobs_finance_acc_read on public.jobs for select to authenticated
  using (public.is_finance() and status = 'ACC');

drop policy if exists jf_admin_all on public.job_files;
drop policy if exists jf_free_read on public.job_files;
drop policy if exists jf_free_insert on public.job_files;
create policy jf_admin_all on public.job_files for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy jf_free_read on public.job_files for select to authenticated
  using (public.is_freelance() and exists (
    select 1 from public.jobs j where j.id = job_id and j.assignee_profile_id = public.my_uid()
  ));
create policy jf_free_insert on public.job_files for insert to authenticated
  with check (public.is_freelance() and exists (
    select 1 from public.jobs j where j.id = job_id and j.assignee_profile_id = public.my_uid()
  ));

drop policy if exists res_admin on public.job_upload_reservations;
drop policy if exists res_owner on public.job_upload_reservations;
create policy res_admin on public.job_upload_reservations for select to authenticated using (public.is_admin());
create policy res_owner on public.job_upload_reservations for select to authenticated
  using (public.is_freelance() and profile_id = public.my_uid());

drop policy if exists sub_admin on public.job_submissions;
drop policy if exists sub_free on public.job_submissions;
create policy sub_admin on public.job_submissions for select to authenticated using (public.is_admin());
create policy sub_free on public.job_submissions for select to authenticated
  using (public.is_freelance() and exists (
    select 1 from public.jobs j where j.id = job_id and j.assignee_profile_id = public.my_uid()
  ));

drop policy if exists subl_admin on public.job_submission_files;
drop policy if exists subl_free on public.job_submission_files;
create policy subl_admin on public.job_submission_files for select to authenticated using (public.is_admin());
create policy subl_free on public.job_submission_files for select to authenticated
  using (public.is_freelance() and exists (
    select 1 from public.job_submissions s join public.jobs j on j.id = s.job_id
    where s.id = submission_id and j.assignee_profile_id = public.my_uid()
  ));

drop policy if exists ev_admin on public.job_events;
drop policy if exists ev_free on public.job_events;
drop policy if exists ev_comment on public.job_events;
drop policy if exists ev_finance_approve on public.job_events;
create policy ev_admin on public.job_events for select to authenticated using (public.is_admin());
create policy ev_free on public.job_events for select to authenticated
  using (public.is_freelance() and exists (
    select 1 from public.jobs j where j.id = job_id and j.assignee_profile_id = public.my_uid()
  ));
create policy ev_comment on public.job_events for insert to authenticated
  with check (event_type = 'comment' and (
    public.is_admin() or (public.is_freelance() and exists (
      select 1 from public.jobs j where j.id = job_id and j.assignee_profile_id = public.my_uid()
    ))
  ));

drop policy if exists set_read on public.app_settings;
create policy set_read on public.app_settings for select to authenticated
  using (public.is_admin() or public.is_freelance());

drop policy if exists th_admin on public.chat_threads;
drop policy if exists th_free on public.chat_threads;
create policy th_admin on public.chat_threads for select to authenticated using (public.is_admin());
create policy th_free on public.chat_threads for select to authenticated
  using (public.is_freelance() and freelance_profile_id = public.my_uid());

drop policy if exists msg_admin on public.chat_messages;
drop policy if exists msg_free_read on public.chat_messages;
drop policy if exists msg_send on public.chat_messages;
create policy msg_admin on public.chat_messages for select to authenticated using (public.is_admin());
create policy msg_free_read on public.chat_messages for select to authenticated
  using (public.is_freelance() and exists (
    select 1 from public.chat_threads t where t.id = thread_id and t.freelance_profile_id = public.my_uid()
  ));
create policy msg_send on public.chat_messages for insert to authenticated
  with check (sender_profile_id = public.my_uid() and (
    public.is_admin() or (public.is_freelance() and exists (
      select 1 from public.chat_threads t where t.id = thread_id and t.freelance_profile_id = public.my_uid()
    ))
  ));

drop policy if exists sto_admin_read on storage.objects;
drop policy if exists sto_free_read on storage.objects;
drop policy if exists sto_admin_write on storage.objects;
drop policy if exists sto_free_write on storage.objects;
drop policy if exists sto_admin_mod on storage.objects;
drop policy if exists sto_admin_del on storage.objects;
create policy sto_admin_read on storage.objects for select to authenticated
  using (bucket_id = 'job-files' and public.is_admin());
create policy sto_free_read on storage.objects for select to authenticated
  using (bucket_id = 'job-files' and public.is_freelance() and exists (
    select 1 from public.jobs j where j.id = split_part(name, '/', 1) and j.assignee_profile_id = public.my_uid()
  ));
create policy sto_admin_write on storage.objects for insert to authenticated
  with check (bucket_id = 'job-files' and public.is_admin());
create policy sto_free_write on storage.objects for insert to authenticated
  with check (bucket_id = 'job-files' and public.is_freelance() and exists (
    select 1 from public.jobs j where j.id = split_part(name, '/', 1) and j.assignee_profile_id = public.my_uid()
  ));
create policy sto_admin_mod on storage.objects for update to authenticated
  using (bucket_id = 'job-files' and public.is_admin()) with check (bucket_id = 'job-files' and public.is_admin());
create policy sto_admin_del on storage.objects for delete to authenticated
  using (bucket_id = 'job-files' and public.is_admin());

create or replace function public.transition_job(
  p_job text, p_to job_status, p_reason text, p_expected_rev int
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype; v_admin boolean;
begin
  v_admin := public.is_admin();
  if not v_admin and not public.is_freelance() then
    return jsonb_build_object('ok', false, 'error', 'Role ini tidak dapat mengubah status job');
  end if;
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.status in ('ACC','Dibatalkan') then return jsonb_build_object('ok', false, 'error', 'Job terminal'); end if;
  if not v_admin and v_job.assignee_profile_id is distinct from public.my_uid() then
    return jsonb_build_object('ok', false, 'error', 'Bukan job milikmu');
  end if;
  if p_to in ('ACC','Revisi','MintaACC') then
    return jsonb_build_object('ok', false, 'error', 'Gunakan alur pengajuan/review');
  end if;
  if not ((v_job.status = 'Antre' and p_to = 'Dikerjakan')
       or (v_job.status = 'Revisi' and p_to = 'Dikerjakan')) then
    return jsonb_build_object('ok', false, 'error', 'Transisi tidak diizinkan');
  end if;
  update public.jobs set status = p_to, revision = revision + 1 where id = p_job;
  insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, reason)
  values (p_job, public.my_uid(), 'status', v_job.status, p_to, nullif(trim(coalesce(p_reason,'')), ''));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.submit_for_acc(
  p_job text, p_file_ids uuid[], p_note text, p_expected_rev int
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype; v_sub uuid; v_ver int; v_f uuid;
begin
  if not public.is_freelance() then
    return jsonb_build_object('ok', false, 'error', 'Hanya Freelance yang dapat mengirim hasil');
  end if;
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.assignee_profile_id is distinct from public.my_uid() then
    return jsonb_build_object('ok', false, 'error', 'Bukan job milikmu');
  end if;
  if v_job.status not in ('Dikerjakan','Revisi') then
    return jsonb_build_object('ok', false, 'error', 'Submission hanya dari Dikerjakan/Revisi');
  end if;
  if coalesce(array_length(p_file_ids, 1), 0) < 1 then
    return jsonb_build_object('ok', false, 'error', 'Pilih >=1 file');
  end if;
  foreach v_f in array p_file_ids loop
    if not exists (select 1 from public.job_files f where f.id = v_f and f.job_id = p_job) then
      return jsonb_build_object('ok', false, 'error', 'File tidak valid');
    end if;
  end loop;
  select coalesce(max(version), 0) + 1 into v_ver from public.job_submissions where job_id = p_job;
  v_sub := gen_random_uuid();
  insert into public.job_submissions(id, job_id, version, submitted_by_profile_id, note)
  values (v_sub, p_job, v_ver, public.my_uid(), nullif(trim(coalesce(p_note,'')), ''));
  insert into public.job_submission_files(submission_id, job_file_id)
  select v_sub, unnest(p_file_ids);
  update public.jobs set status = 'MintaACC', current_submission_id = v_sub, revision = revision + 1 where id = p_job;
  insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status)
  values (p_job, public.my_uid(), 'submit', v_job.status, 'MintaACC');
  return jsonb_build_object('ok', true, 'submission_id', v_sub);
end $$;

create or replace function public.reserve_upload(p_job text, p_size bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype; v_total bigint; v_r uuid; v_admin boolean;
begin
  v_admin := public.is_admin();
  if not v_admin and not public.is_freelance() then
    return jsonb_build_object('ok', false, 'error', 'Role ini tidak dapat mengunggah file');
  end if;
  select * into v_job from public.jobs where id = p_job;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.status in ('ACC','Dibatalkan') then return jsonb_build_object('ok', false, 'error', 'Job terminal'); end if;
  if not v_admin and v_job.assignee_profile_id is distinct from public.my_uid() then
    return jsonb_build_object('ok', false, 'error', 'Bukan job milikmu');
  end if;
  if p_size <= 0 or p_size > 1073741824 then
    return jsonb_build_object('ok', false, 'error', 'Maks 1 GiB per file');
  end if;
  perform pg_advisory_xact_lock(hashtext(p_job)::bigint);
  delete from public.job_upload_reservations where job_id = p_job and state = 'active' and expires_at <= now();
  select coalesce(sum(size_bytes), 0) into v_total from public.job_files
    where job_id = p_job and expired_at is null;
  select v_total + coalesce(sum(size_bytes), 0) into v_total from public.job_upload_reservations
    where job_id = p_job and state = 'active' and expires_at > now();
  if v_total + p_size > 10737418240 then
    return jsonb_build_object('ok', false, 'error', 'Total melebihi 10 GiB per job');
  end if;
  insert into public.job_upload_reservations(job_id, profile_id, size_bytes)
  values (p_job, public.my_uid(), p_size) returning id into v_r;
  return jsonb_build_object('ok', true, 'reservation_id', v_r);
end $$;

create or replace function public.release_upload_reservation(p_reservation uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_freelance() and not public.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'Role ini tidak dapat mengubah reservation');
  end if;
  update public.job_upload_reservations set state = 'released'
    where id = p_reservation and profile_id = public.my_uid() and state = 'active';
  return jsonb_build_object('ok', true);
end $$;

-- Keep role/active changes behind one audited RPC and serialize the last-
-- Super-Admin check so two concurrent changes cannot remove the final account.
create or replace function public.manage_profile_access(
  p_target uuid, p_new_role text, p_new_active boolean, p_reason text
) returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare
  v_old_role text;
  v_old_active boolean;
  v_actor_label text;
  v_other_super_admins integer;
begin
  if not public.is_super_admin() then
    return jsonb_build_object('ok', false, 'error', 'Hanya Super Admin');
  end if;
  if p_new_role not in ('super_admin', 'finance', 'admin', 'freelance') then
    return jsonb_build_object('ok', false, 'error', 'Role tidak dikenal');
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Alasan perubahan wajib diisi');
  end if;
  perform pg_advisory_xact_lock(hashtext('threadline-super-admin-access')::bigint);
  select role, is_active into v_old_role, v_old_active
  from public.profiles where id = p_target for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Profil tidak ditemukan'); end if;
  if p_target = auth.uid() and (v_old_role <> p_new_role or v_old_active <> p_new_active) then
    return jsonb_build_object('ok', false, 'error', 'Super Admin tidak dapat mengubah role atau akses akunnya sendiri');
  end if;
  if v_old_role = p_new_role and v_old_active = p_new_active then
    return jsonb_build_object('ok', true, 'changed', false);
  end if;

  if v_old_role = 'super_admin' and v_old_active
     and (p_new_role <> 'super_admin' or not p_new_active) then
    select count(*) into v_other_super_admins from public.profiles
    where role = 'super_admin' and is_active and id <> p_target;
    if v_other_super_admins = 0 then
      return jsonb_build_object('ok', false, 'error', 'Super Admin aktif terakhir tidak dapat diturunkan atau dinonaktifkan');
    end if;
  end if;

  select name into v_actor_label from public.profiles where id = auth.uid();
  perform set_config('threadline.allow_profile_access_update', 'on', true);
  update public.profiles set role = p_new_role, is_active = p_new_active where id = p_target;
  insert into public.profile_role_events(
    target_profile_id, old_role, new_role, old_active, new_active,
    actor_profile_id, actor_label, reason
  ) values (
    p_target, v_old_role, p_new_role, v_old_active, p_new_active,
    auth.uid(), coalesce(v_actor_label, 'Super Admin'), trim(p_reason)
  );
  return jsonb_build_object('ok', true, 'changed', true);
end $$;

-- Bootstrap entry point for the trusted deployment operator. After the first
-- Super Admin is created, ordinary role changes go through manage_profile_access.
create or replace function public.promote_super_admin(p_target uuid, p_reason text, p_actor_label text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_old_role text; v_old_active boolean;
begin
  if not public.is_service_role() then
    return jsonb_build_object('ok', false, 'error', 'Hanya operator tepercaya');
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Alasan wajib diisi');
  end if;
  select role, is_active into v_old_role, v_old_active from public.profiles where id = p_target;
  if not found then return jsonb_build_object('ok', false, 'error', 'Profil tidak ditemukan'); end if;
  update public.profiles set role = 'super_admin', is_active = true where id = p_target;
  insert into public.profile_role_events(
    target_profile_id, old_role, new_role, old_active, new_active,
    actor_profile_id, actor_label, reason
  ) values (
    p_target, v_old_role, 'super_admin', v_old_active, true,
    null, coalesce(nullif(trim(p_actor_label), ''), 'operator'), trim(p_reason)
  );
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.manage_profile_access(uuid, text, boolean, text) from public, anon;
grant execute on function public.manage_profile_access(uuid, text, boolean, text) to authenticated, service_role;
revoke all on function public.finance_acc_recipients() from public, anon;
grant execute on function public.finance_acc_recipients() to authenticated;
revoke all on function public.finance_acc_approval_times() from public, anon;
grant execute on function public.finance_acc_approval_times() to authenticated;
revoke all on function public.promote_super_admin(uuid, text, text) from public, anon, authenticated;
grant execute on function public.promote_super_admin(uuid, text, text) to service_role;

-- Source migration: 20261017000001_super_admin_controls.sql
-- Super Admin controls: require MFA for privileged access, provide an account
-- directory and audit log, and route shared settings changes through one RPC.

create table if not exists public.admin_audit_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null,
  target_profile_id uuid,
  target_label text not null,
  actor_profile_id uuid,
  actor_label text not null,
  before_data jsonb not null default '{}',
  after_data jsonb not null default '{}',
  reason text not null,
  created_at timestamptz not null default now()
);
create index if not exists admin_audit_events_created_idx
  on public.admin_audit_events(created_at desc);
create index if not exists admin_audit_events_target_idx
  on public.admin_audit_events(target_profile_id, created_at desc);
alter table public.admin_audit_events enable row level security;
revoke all on public.admin_audit_events from public, anon;
revoke insert, update, delete on public.admin_audit_events from authenticated;
grant select on public.admin_audit_events to authenticated;
grant all on public.admin_audit_events to service_role;
drop policy if exists admin_audit_super_admin_read on public.admin_audit_events;
create policy admin_audit_super_admin_read on public.admin_audit_events
  for select to authenticated using (public.is_super_admin());

-- All Super Admin access in the data layer requires a verified second factor.
create or replace function public.is_super_admin() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select coalesce(auth.jwt() ->> 'aal', '') = 'aal2' and exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.is_active and p.role = 'super_admin'
  )
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.is_active and p.role = 'admin'
  ) or public.is_super_admin()
$$;

create or replace function public.super_admin_account_directory()
returns table(
  profile_id uuid,
  name text,
  role text,
  is_active boolean,
  last_seen timestamptz,
  email text,
  email_confirmed_at timestamptz
)
language sql stable security definer set search_path = public, auth as $$
  select p.id, p.name, p.role, p.is_active, p.last_seen, u.email, u.email_confirmed_at
  from public.profiles p
  join auth.users u on u.id = p.id
  where public.is_super_admin()
  order by p.name, p.id
$$;

create or replace function public.super_admin_audit_log()
returns table(
  id uuid,
  event_type text,
  target_profile_id uuid,
  target_label text,
  actor_profile_id uuid,
  actor_label text,
  before_data jsonb,
  after_data jsonb,
  reason text,
  created_at timestamptz
)
language sql stable security definer set search_path = public as $$
  select e.id, e.event_type, e.target_profile_id, e.target_label,
    e.actor_profile_id, e.actor_label, e.before_data, e.after_data,
    e.reason, e.created_at
  from public.admin_audit_events e
  where public.is_super_admin()
  order by e.created_at desc
  limit 500
$$;

create or replace function public.update_app_settings(
  p_sla_hours integer,
  p_max_active_jobs integer,
  p_reason text
) returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare
  v_old public.app_settings%rowtype;
  v_actor_label text;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'Hanya Admin atau Super Admin');
  end if;
  if p_sla_hours is not null and (p_sla_hours < 1 or p_sla_hours > 72) then
    return jsonb_build_object('ok', false, 'error', 'SLA harus 1-72 jam');
  end if;
  if p_max_active_jobs is not null and (p_max_active_jobs < 1 or p_max_active_jobs > 20) then
    return jsonb_build_object('ok', false, 'error', 'Batas job harus 1-20');
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Alasan perubahan wajib diisi');
  end if;

  select * into v_old from public.app_settings where id = 1 for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Pengaturan belum tersedia'); end if;
  if coalesce(p_sla_hours, v_old.urgency_sla_hours) = v_old.urgency_sla_hours
     and coalesce(p_max_active_jobs, v_old.max_active_jobs) = v_old.max_active_jobs then
    return jsonb_build_object('ok', true, 'changed', false);
  end if;
  select p.name into v_actor_label from public.profiles p where p.id = auth.uid();

  update public.app_settings set
    urgency_sla_hours = coalesce(p_sla_hours, v_old.urgency_sla_hours),
    max_active_jobs = coalesce(p_max_active_jobs, v_old.max_active_jobs),
    updated_at = now(),
    updated_by_profile_id = auth.uid()
  where id = 1;

  insert into public.admin_audit_events(
    event_type, target_label, actor_profile_id, actor_label,
    before_data, after_data, reason
  ) values (
    'settings_updated', 'Pengaturan bersama', auth.uid(), coalesce(v_actor_label, 'Admin'),
    jsonb_build_object('sla_hours', v_old.urgency_sla_hours, 'max_active_jobs', v_old.max_active_jobs),
    jsonb_build_object('sla_hours', coalesce(p_sla_hours, v_old.urgency_sla_hours), 'max_active_jobs', coalesce(p_max_active_jobs, v_old.max_active_jobs)),
    trim(p_reason)
  );
  return jsonb_build_object('ok', true, 'changed', true);
end $$;

-- This service-role-only function is called only after an authenticated
-- Super Admin has sent an Auth invitation from the server.
create or replace function public.set_invited_account_role(
  p_target uuid,
  p_new_role text,
  p_actor uuid,
  p_reason text
) returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare
  v_old_role text;
  v_old_active boolean;
  v_target_label text;
  v_actor_label text;
begin
  if not public.is_service_role() then
    return jsonb_build_object('ok', false, 'error', 'Hanya server tepercaya');
  end if;
  if p_new_role not in ('admin', 'finance', 'freelance') then
    return jsonb_build_object('ok', false, 'error', 'Role undangan tidak dikenal');
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Alasan wajib diisi');
  end if;
  select role, is_active, name into v_old_role, v_old_active, v_target_label
  from public.profiles where id = p_target for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Profil undangan belum tersedia'); end if;
  select name into v_actor_label from public.profiles where id = p_actor and role = 'super_admin' and is_active;
  if v_actor_label is null then return jsonb_build_object('ok', false, 'error', 'Pelaku undangan tidak valid'); end if;

  update public.profiles set role = p_new_role, is_active = true where id = p_target;
  insert into public.profile_role_events(
    target_profile_id, old_role, new_role, old_active, new_active,
    actor_profile_id, actor_label, reason
  ) values (
    p_target, v_old_role, p_new_role, v_old_active, true,
    p_actor, v_actor_label, trim(p_reason)
  );
  insert into public.admin_audit_events(
    event_type, target_profile_id, target_label, actor_profile_id, actor_label,
    before_data, after_data, reason
  ) values (
    'account_invited', p_target, v_target_label, p_actor, v_actor_label,
    jsonb_build_object('role', v_old_role, 'is_active', v_old_active),
    jsonb_build_object('role', p_new_role, 'is_active', true, 'invitation_sent', true),
    trim(p_reason)
  );
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.record_super_admin_user_action(
  p_target uuid,
  p_actor uuid,
  p_event_type text,
  p_reason text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_target_label text; v_actor_label text;
begin
  if not public.is_service_role() then
    return jsonb_build_object('ok', false, 'error', 'Hanya server tepercaya');
  end if;
  if p_event_type not in ('password_reset_email_sent', 'verification_email_sent', 'sessions_revoked') then
    return jsonb_build_object('ok', false, 'error', 'Tindakan tidak dikenal');
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Alasan wajib diisi');
  end if;
  select name into v_target_label from public.profiles where id = p_target;
  if v_target_label is null then return jsonb_build_object('ok', false, 'error', 'Profil tidak ditemukan'); end if;
  select name into v_actor_label from public.profiles where id = p_actor and role = 'super_admin' and is_active;
  if v_actor_label is null then return jsonb_build_object('ok', false, 'error', 'Pelaku tidak valid'); end if;
  insert into public.admin_audit_events(
    event_type, target_profile_id, target_label, actor_profile_id, actor_label, reason
  ) values (p_event_type, p_target, v_target_label, p_actor, v_actor_label, trim(p_reason));
  return jsonb_build_object('ok', true);
end $$;

-- Role changes keep the established role-event ledger and also appear in the
-- consolidated audit screen used by Super Admins.
create or replace function public.manage_profile_access(
  p_target uuid, p_new_role text, p_new_active boolean, p_reason text
) returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare
  v_old_role text;
  v_old_active boolean;
  v_actor_label text;
  v_target_label text;
  v_other_super_admins integer;
begin
  if not public.is_super_admin() then
    return jsonb_build_object('ok', false, 'error', 'Hanya Super Admin dengan MFA');
  end if;
  if p_new_role not in ('super_admin', 'finance', 'admin', 'freelance') then
    return jsonb_build_object('ok', false, 'error', 'Role tidak dikenal');
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Alasan perubahan wajib diisi');
  end if;
  perform pg_advisory_xact_lock(hashtext('threadline-super-admin-access')::bigint);
  select role, is_active, name into v_old_role, v_old_active, v_target_label
  from public.profiles where id = p_target for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Profil tidak ditemukan'); end if;
  if p_target = auth.uid() and (v_old_role <> p_new_role or v_old_active <> p_new_active) then
    return jsonb_build_object('ok', false, 'error', 'Super Admin tidak dapat mengubah role atau akses akunnya sendiri');
  end if;
  if v_old_role = p_new_role and v_old_active = p_new_active then
    return jsonb_build_object('ok', true, 'changed', false);
  end if;

  if v_old_role = 'super_admin' and v_old_active
     and (p_new_role <> 'super_admin' or not p_new_active) then
    select count(*) into v_other_super_admins from public.profiles
    where role = 'super_admin' and is_active and id <> p_target;
    if v_other_super_admins = 0 then
      return jsonb_build_object('ok', false, 'error', 'Super Admin aktif terakhir tidak dapat diturunkan atau dinonaktifkan');
    end if;
  end if;

  select name into v_actor_label from public.profiles where id = auth.uid();
  perform set_config('threadline.allow_profile_access_update', 'on', true);
  update public.profiles set role = p_new_role, is_active = p_new_active where id = p_target;
  insert into public.profile_role_events(
    target_profile_id, old_role, new_role, old_active, new_active,
    actor_profile_id, actor_label, reason
  ) values (
    p_target, v_old_role, p_new_role, v_old_active, p_new_active,
    auth.uid(), coalesce(v_actor_label, 'Super Admin'), trim(p_reason)
  );
  insert into public.admin_audit_events(
    event_type, target_profile_id, target_label, actor_profile_id, actor_label,
    before_data, after_data, reason
  ) values (
    'account_access_changed', p_target, v_target_label, auth.uid(), coalesce(v_actor_label, 'Super Admin'),
    jsonb_build_object('role', v_old_role, 'is_active', v_old_active),
    jsonb_build_object('role', p_new_role, 'is_active', p_new_active), trim(p_reason)
  );
  return jsonb_build_object('ok', true, 'changed', true);
end $$;

create or replace function public.promote_super_admin(p_target uuid, p_reason text, p_actor_label text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_old_role text; v_old_active boolean; v_target_label text;
begin
  if not public.is_service_role() then
    return jsonb_build_object('ok', false, 'error', 'Hanya operator tepercaya');
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Alasan wajib diisi');
  end if;
  select role, is_active, name into v_old_role, v_old_active, v_target_label
  from public.profiles where id = p_target;
  if not found then return jsonb_build_object('ok', false, 'error', 'Profil tidak ditemukan'); end if;
  update public.profiles set role = 'super_admin', is_active = true where id = p_target;
  insert into public.profile_role_events(
    target_profile_id, old_role, new_role, old_active, new_active,
    actor_profile_id, actor_label, reason
  ) values (
    p_target, v_old_role, 'super_admin', v_old_active, true,
    null, coalesce(nullif(trim(p_actor_label), ''), 'operator'), trim(p_reason)
  );
  insert into public.admin_audit_events(
    event_type, target_profile_id, target_label, actor_label,
    before_data, after_data, reason
  ) values (
    'account_access_changed', p_target, v_target_label,
    coalesce(nullif(trim(p_actor_label), ''), 'operator'),
    jsonb_build_object('role', v_old_role, 'is_active', v_old_active),
    jsonb_build_object('role', 'super_admin', 'is_active', true), trim(p_reason)
  );
  return jsonb_build_object('ok', true);
end $$;

-- Shared settings can only be changed through the audited RPC.
drop policy if exists set_admin on public.app_settings;
revoke update on public.app_settings from public, anon, authenticated;
grant select on public.app_settings to authenticated;

revoke all on function public.super_admin_account_directory() from public, anon;
grant execute on function public.super_admin_account_directory() to authenticated, service_role;
revoke all on function public.super_admin_audit_log() from public, anon;
grant execute on function public.super_admin_audit_log() to authenticated, service_role;
revoke all on function public.update_app_settings(integer, integer, text) from public, anon;
grant execute on function public.update_app_settings(integer, integer, text) to authenticated, service_role;
revoke all on function public.set_invited_account_role(uuid, text, uuid, text) from public, anon, authenticated;
grant execute on function public.set_invited_account_role(uuid, text, uuid, text) to service_role;
revoke all on function public.record_super_admin_user_action(uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function public.record_super_admin_user_action(uuid, uuid, text, text) to service_role;
revoke all on function public.manage_profile_access(uuid, text, boolean, text) from public, anon;
grant execute on function public.manage_profile_access(uuid, text, boolean, text) to authenticated, service_role;
revoke all on function public.promote_super_admin(uuid, text, text) from public, anon, authenticated;
grant execute on function public.promote_super_admin(uuid, text, text) to service_role;

-- Source migration: 20261017000002_super_admin_authenticator_optional.sql
-- TOTP remains available as an optional Supabase Auth factor, but is no longer
-- required to access Super Admin data or operations.
create or replace function public.is_super_admin() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.is_active and p.role = 'super_admin'
  )
$$;

-- Source migration: 20261017000003_trd_job_codes.sql
-- New jobs use TRD- followed by at least four digits. Keep existing JRS IDs
-- valid so historical job references, audit events, and stored file paths remain intact.
alter table public.jobs
  drop constraint if exists jobs_id_check;

alter table public.jobs
  add constraint jobs_id_format_check
  check (id ~ '^TRD-[0-9]{4,}$' or id ~ '^JRS-[0-9]+$');

create or replace function public.create_job(
  p_tim text, p_jenis job_type, p_qty int, p_deadline timestamptz,
  p_fee bigint, p_priority job_priority, p_brief text, p_ref text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id text;
  v_number bigint;
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'Hanya Admin'); end if;
  if p_qty < 1 then return jsonb_build_object('ok', false, 'error', 'Qty minimal 1'); end if;
  if p_fee < 0 then return jsonb_build_object('ok', false, 'error', 'Fee tidak valid'); end if;

  v_number := nextval('public.threadline_job_seq');
  v_id := 'TRD-' || lpad(v_number::text, greatest(4, length(v_number::text)), '0');

  insert into public.jobs(id, tim, jenis, qty, deadline, fee, priority, brief, ref)
  values (v_id, nullif(trim(p_tim), ''), p_jenis, p_qty, p_deadline, p_fee, p_priority,
    nullif(trim(p_brief), ''), nullif(trim(coalesce(p_ref, '')), ''));
  insert into public.job_events(job_id, actor_profile_id, event_type, to_status)
  values (v_id, public.my_uid(), 'create', 'Belum Ditugaskan');
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- Source migration: 20261017000004_reference_files_and_formats.sql
-- Pisahkan file referensi dari hasil kerja dan perluas format file yang didukung.
alter table public.job_files
  add column if not exists file_role text not null default 'result';

alter table public.job_files
  drop constraint if exists job_files_file_kind_check;

alter table public.job_files
  add constraint job_files_file_kind_allowed_check
  check (file_kind in ('PDF','CDR','PNG','JPEG','SVG','DOCX','XLSX','PPTX','AI','PSD'));

alter table public.job_files
  drop constraint if exists job_files_file_role_check;

alter table public.job_files
  add constraint job_files_file_role_check
  check (file_role in ('reference','result'));

-- Validasi ekstensi dan label jenis tetap dilakukan oleh database.
create or replace function public.validate_job_file_kind() returns trigger
language plpgsql security definer set search_path = public as $$
declare ext text;
begin
  ext := lower(split_part(NEW.name, '.', array_length(string_to_array(NEW.name, '.'), 1)));
  if ext = 'jpg' then ext := 'jpeg'; end if;
  if ext not in ('pdf','cdr','png','jpeg','svg','docx','xlsx','pptx','ai','psd') then
    raise exception 'INVALID_TYPE: format file tidak didukung';
  end if;
  if upper(ext) <> NEW.file_kind then
    raise exception 'INVALID_TYPE: file_kind tidak cocok ekstensi';
  end if;
  if NEW.file_role = 'reference' and not public.is_admin() then
    raise exception 'REFERENCE_ADMIN_ONLY: hanya Admin yang dapat mengunggah file referensi';
  end if;
  return NEW;
end $$;

-- Pertahanan database: hanya file hasil yang dapat dikunci dalam pengajuan ACC.
create or replace function public.submit_for_acc(
  p_job text, p_file_ids uuid[], p_note text, p_expected_rev int
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype; v_sub uuid; v_ver int; v_f uuid;
begin
  if not public.is_freelance() then
    return jsonb_build_object('ok', false, 'error', 'Hanya Freelance yang dapat mengirim hasil');
  end if;
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.assignee_profile_id is distinct from public.my_uid() then
    return jsonb_build_object('ok', false, 'error', 'Bukan job milikmu');
  end if;
  if v_job.status not in ('Dikerjakan','Revisi') then
    return jsonb_build_object('ok', false, 'error', 'Submission hanya dari Dikerjakan/Revisi');
  end if;
  if coalesce(array_length(p_file_ids, 1), 0) < 1 then
    return jsonb_build_object('ok', false, 'error', 'Pilih >=1 file');
  end if;
  foreach v_f in array p_file_ids loop
    if not exists (
      select 1 from public.job_files f
      where f.id = v_f and f.job_id = p_job and f.file_role = 'result' and f.expired_at is null
    ) then
      return jsonb_build_object('ok', false, 'error', 'Pilih file hasil yang masih aktif');
    end if;
  end loop;
  select coalesce(max(version), 0) + 1 into v_ver from public.job_submissions where job_id = p_job;
  v_sub := gen_random_uuid();
  insert into public.job_submissions(id, job_id, version, submitted_by_profile_id, note)
  values (v_sub, p_job, v_ver, public.my_uid(), nullif(trim(coalesce(p_note,'')), ''));
  insert into public.job_submission_files(submission_id, job_file_id)
  select v_sub, unnest(p_file_ids);
  update public.jobs set status = 'MintaACC', current_submission_id = v_sub, revision = revision + 1 where id = p_job;
  insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status)
  values (p_job, public.my_uid(), 'submit', v_job.status, 'MintaACC');
  return jsonb_build_object('ok', true, 'submission_id', v_sub);
end $$;

-- Source migration: 20261017000005_freelance_whatsapp.sql
-- Keep freelancer contact details separate from profile names so other
-- freelancers cannot read phone numbers through the profiles table policies.
create table if not exists public.profile_contacts (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  whatsapp text not null check (nullif(btrim(whatsapp), '') is not null),
  updated_at timestamptz not null default now()
);
alter table public.profile_contacts enable row level security;
revoke all on public.profile_contacts from public, anon, authenticated;
grant select on public.profile_contacts to authenticated;
drop policy if exists profile_contacts_admin_select on public.profile_contacts;
create policy profile_contacts_admin_select on public.profile_contacts
  for select to authenticated using (public.is_admin());
drop policy if exists profile_contacts_self_select on public.profile_contacts;
create policy profile_contacts_self_select on public.profile_contacts
  for select to authenticated using (profile_id = public.my_uid());

-- Keep the signup metadata on the profile row so admins can contact freelancers.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare
  v_name text;
  v_whatsapp text;
begin
  v_name := coalesce(
    nullif(btrim(NEW.raw_user_meta_data ->> 'name'), ''),
    split_part(NEW.email, '@', 1)
  );
  v_whatsapp := nullif(btrim(NEW.raw_user_meta_data ->> 'whatsapp'), '');

  insert into public.profiles(id, name, role)
  values (NEW.id, v_name, 'freelance')
  on conflict (id) do nothing;

  if v_whatsapp is not null then
    insert into public.profile_contacts(profile_id, whatsapp)
    values (NEW.id, v_whatsapp) on conflict (profile_id) do nothing;
  end if;

  insert into public.chat_threads(freelance_profile_id)
  values (NEW.id) on conflict do nothing;
  return NEW;
exception when unique_violation then
  -- Preserve the submitted name while resolving a duplicate profile name.
  insert into public.profiles(id, name, role)
  values (NEW.id, v_name || '-' || substr(md5(NEW.id::text), 1, 4), 'freelance')
  on conflict (id) do nothing;
  if v_whatsapp is not null then
    insert into public.profile_contacts(profile_id, whatsapp)
    values (NEW.id, v_whatsapp) on conflict (profile_id) do nothing;
  end if;
  insert into public.chat_threads(freelance_profile_id)
  values (NEW.id) on conflict do nothing;
  return NEW;
end $$;

-- Source migration: 20261017000006_freelancer_registration_review.sql
-- Public freelancer registrations are held until an Admin or Super Admin
-- reviews them. Existing accounts remain approved by default.
alter table public.profiles
  add column if not exists registration_status text not null default 'approved',
  add column if not exists registration_requested_at timestamptz not null default now(),
  add column if not exists registration_reviewed_at timestamptz,
  add column if not exists registration_reviewed_by_profile_id uuid references public.profiles(id) on delete set null,
  add column if not exists registration_review_reason text;

alter table public.profiles
  drop constraint if exists profiles_registration_status_check;
alter table public.profiles
  add constraint profiles_registration_status_check
  check (registration_status in ('pending', 'approved', 'rejected'));

create index if not exists profiles_pending_freelancer_registrations_idx
  on public.profiles(registration_requested_at asc)
  where role = 'freelance' and registration_status = 'pending';

-- Registration decisions are written only by trusted server-side functions.
create or replace function public.guard_registration_review_fields()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (
    new.registration_status is distinct from old.registration_status or
    new.registration_requested_at is distinct from old.registration_requested_at or
    new.registration_reviewed_at is distinct from old.registration_reviewed_at or
    new.registration_reviewed_by_profile_id is distinct from old.registration_reviewed_by_profile_id or
    new.registration_review_reason is distinct from old.registration_review_reason
  ) and not public.is_service_role() then
    raise exception 'FORBIDDEN: keputusan pendaftaran hanya dapat diubah oleh server';
  end if;
  return new;
end $$;

drop trigger if exists trg_guard_registration_review_fields on public.profiles;
create trigger trg_guard_registration_review_fields
  before update on public.profiles
  for each row execute function public.guard_registration_review_fields();

-- New Auth users are pending and inactive from the moment their profile exists.
-- Invited accounts are activated separately by set_invited_account_role().
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare
  v_name text;
  v_whatsapp text;
begin
  v_name := coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'name'), ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    'Freelancer'
  );
  v_whatsapp := nullif(btrim(new.raw_user_meta_data ->> 'whatsapp'), '');

  insert into public.profiles(
    id, name, role, is_active, registration_status, registration_requested_at
  ) values (
    new.id, v_name, 'freelance', false, 'pending', now()
  ) on conflict (id) do nothing;

  if v_whatsapp is not null then
    insert into public.profile_contacts(profile_id, whatsapp)
    values (new.id, v_whatsapp) on conflict (profile_id) do nothing;
  end if;

  insert into public.chat_threads(freelance_profile_id)
  values (new.id) on conflict do nothing;
  return new;
exception when unique_violation then
  insert into public.profiles(
    id, name, role, is_active, registration_status, registration_requested_at
  ) values (
    new.id, v_name || '-' || substr(md5(new.id::text), 1, 4), 'freelance', false, 'pending', now()
  ) on conflict (id) do nothing;
  if v_whatsapp is not null then
    insert into public.profile_contacts(profile_id, whatsapp)
    values (new.id, v_whatsapp) on conflict (profile_id) do nothing;
  end if;
  insert into public.chat_threads(freelance_profile_id)
  values (new.id) on conflict do nothing;
  return new;
end $$;

-- Invitation-based accounts are not public registrations and remain immediately
-- usable after the invitee confirms their invitation email.
create or replace function public.set_invited_account_role(
  p_target uuid,
  p_new_role text,
  p_actor uuid,
  p_reason text
) returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare
  v_old_role text;
  v_old_active boolean;
  v_target_label text;
  v_actor_label text;
begin
  if not public.is_service_role() then
    return jsonb_build_object('ok', false, 'error', 'Hanya server tepercaya');
  end if;
  if p_new_role not in ('admin', 'finance', 'freelance') then
    return jsonb_build_object('ok', false, 'error', 'Role undangan tidak dikenal');
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Alasan wajib diisi');
  end if;
  select role, is_active, name into v_old_role, v_old_active, v_target_label
  from public.profiles where id = p_target for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Profil undangan belum tersedia'); end if;
  select name into v_actor_label from public.profiles where id = p_actor and role = 'super_admin' and is_active;
  if v_actor_label is null then return jsonb_build_object('ok', false, 'error', 'Pelaku undangan tidak valid'); end if;

  update public.profiles set
    role = p_new_role,
    is_active = true,
    registration_status = 'approved',
    registration_reviewed_at = now(),
    registration_reviewed_by_profile_id = p_actor,
    registration_review_reason = 'Akun dibuat melalui undangan Admin.'
  where id = p_target;
  insert into public.profile_role_events(
    target_profile_id, old_role, new_role, old_active, new_active,
    actor_profile_id, actor_label, reason
  ) values (
    p_target, v_old_role, p_new_role, v_old_active, true,
    p_actor, v_actor_label, trim(p_reason)
  );
  insert into public.admin_audit_events(
    event_type, target_profile_id, target_label, actor_profile_id, actor_label,
    before_data, after_data, reason
  ) values (
    'account_invited', p_target, v_target_label, p_actor, v_actor_label,
    jsonb_build_object('role', v_old_role, 'is_active', v_old_active),
    jsonb_build_object('role', p_new_role, 'is_active', true, 'invitation_sent', true),
    trim(p_reason)
  );
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.pending_freelancer_registrations()
returns table(
  profile_id uuid,
  name text,
  email text,
  whatsapp text,
  requested_at timestamptz
)
language sql stable security definer set search_path = public, auth as $$
  select p.id, p.name, u.email, c.whatsapp, p.registration_requested_at
  from public.profiles p
  join auth.users u on u.id = p.id
  left join public.profile_contacts c on c.profile_id = p.id
  where p.role = 'freelance'
    and p.registration_status = 'pending'
    and not p.is_active
    and exists (
      select 1 from public.profiles reviewer
      where reviewer.id = auth.uid() and reviewer.is_active
        and reviewer.role in ('admin', 'super_admin')
    )
  order by p.registration_requested_at asc, p.name asc
$$;

create or replace function public.review_freelancer_registration(
  p_target uuid,
  p_approve boolean,
  p_actor uuid,
  p_reason text
) returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare
  v_target public.profiles%rowtype;
  v_actor_label text;
  v_new_status text;
begin
  if not public.is_service_role() then
    return jsonb_build_object('ok', false, 'error', 'Hanya server tepercaya');
  end if;
  if p_approve is null then
    return jsonb_build_object('ok', false, 'error', 'Keputusan pendaftaran tidak valid');
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Catatan keputusan wajib diisi');
  end if;

  select * into v_target from public.profiles where id = p_target for update;
  if not found or v_target.role <> 'freelance'
     or v_target.registration_status <> 'pending' or v_target.is_active then
    return jsonb_build_object('ok', false, 'error', 'Pendaftaran tidak lagi menunggu keputusan');
  end if;

  select name into v_actor_label from public.profiles
  where id = p_actor and is_active and role in ('admin', 'super_admin');
  if v_actor_label is null then
    return jsonb_build_object('ok', false, 'error', 'Admin yang meninjau tidak valid');
  end if;

  v_new_status := case when p_approve then 'approved' else 'rejected' end;
  update public.profiles set
    registration_status = v_new_status,
    is_active = p_approve,
    registration_reviewed_at = now(),
    registration_reviewed_by_profile_id = p_actor,
    registration_review_reason = trim(p_reason)
  where id = p_target;

  insert into public.admin_audit_events(
    event_type, target_profile_id, target_label, actor_profile_id, actor_label,
    before_data, after_data, reason
  ) values (
    case when p_approve then 'freelancer_registration_approved' else 'freelancer_registration_rejected' end,
    p_target, v_target.name, p_actor, v_actor_label,
    jsonb_build_object('registration_status', 'pending', 'is_active', false),
    jsonb_build_object('registration_status', v_new_status, 'is_active', p_approve),
    trim(p_reason)
  );
  return jsonb_build_object('ok', true, 'registration_status', v_new_status);
end $$;

revoke all on function public.pending_freelancer_registrations() from public, anon;
grant execute on function public.pending_freelancer_registrations() to authenticated, service_role;
revoke all on function public.review_freelancer_registration(uuid, boolean, uuid, text) from public, anon, authenticated;
grant execute on function public.review_freelancer_registration(uuid, boolean, uuid, text) to service_role;
revoke all on function public.set_invited_account_role(uuid, text, uuid, text) from public, anon, authenticated;
grant execute on function public.set_invited_account_role(uuid, text, uuid, text) to service_role;

-- Source migration: 20261017000007_freelancer_bank_accounts.sql
-- Approved freelancers must provide a bank account before using operations.
-- Payout details are kept separately from the public profile and contact data.
create table if not exists public.freelancer_bank_accounts (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  bank_name text not null,
  account_number text not null,
  account_holder text not null,
  updated_at timestamptz not null default now(),
  constraint freelancer_bank_accounts_bank_name_check check (
    char_length(btrim(bank_name)) between 2 and 80
    and regexp_replace(lower(bank_name), '[^a-z0-9]+', ' ', 'g') !~
      '(^| )(go ?pay|ovo|dana|shopee ?pay|link ?aja|doku|sakuku|i ?saku|astra ?pay|motion ?pay|paytren|uangku)( |$)'
  ),
  constraint freelancer_bank_accounts_number_check check (account_number ~ '^[0-9]{5,30}$'),
  constraint freelancer_bank_accounts_holder_check check (char_length(btrim(account_holder)) between 2 and 100)
);

alter table public.freelancer_bank_accounts enable row level security;
revoke all on public.freelancer_bank_accounts from public, anon, authenticated;
grant select, insert, update on public.freelancer_bank_accounts to authenticated;

drop policy if exists freelancer_bank_accounts_admin_read on public.freelancer_bank_accounts;
create policy freelancer_bank_accounts_admin_read
  on public.freelancer_bank_accounts for select to authenticated
  using (public.is_admin());

drop policy if exists freelancer_bank_accounts_owner_read on public.freelancer_bank_accounts;
create policy freelancer_bank_accounts_owner_read
  on public.freelancer_bank_accounts for select to authenticated
  using (
    profile_id = auth.uid()
    and exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'freelance'
        and p.is_active and p.registration_status = 'approved'
    )
  );

drop policy if exists freelancer_bank_accounts_owner_insert on public.freelancer_bank_accounts;
create policy freelancer_bank_accounts_owner_insert
  on public.freelancer_bank_accounts for insert to authenticated
  with check (
    profile_id = auth.uid()
    and exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'freelance'
        and p.is_active and p.registration_status = 'approved'
    )
  );

drop policy if exists freelancer_bank_accounts_owner_update on public.freelancer_bank_accounts;
create policy freelancer_bank_accounts_owner_update
  on public.freelancer_bank_accounts for update to authenticated
  using (
    profile_id = auth.uid()
    and exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'freelance'
        and p.is_active and p.registration_status = 'approved'
    )
  )
  with check (
    profile_id = auth.uid()
    and exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'freelance'
        and p.is_active and p.registration_status = 'approved'
    )
  );

-- RLS policies across the app use is_freelance() for operational access.
-- Requiring saved bank details here prevents skipping the form via direct requests.
create or replace function public.is_freelance() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (
    select 1 from public.profiles p
    join public.freelancer_bank_accounts b on b.profile_id = p.id
    where p.id = auth.uid() and p.is_active and p.role = 'freelance'
      and p.registration_status = 'approved'
  )
$$;

-- Source migration: 20261017000008_freelancer_availability.sql
-- Availability is a freelancer's current check-in intent. Online/offline
-- presence continues to come from the existing last_seen heartbeat.
alter table public.profiles
  add column if not exists availability_status text not null default 'pending',
  add column if not exists availability_updated_at timestamptz not null default now();

alter table public.profiles
  drop constraint if exists profiles_availability_status_check;
alter table public.profiles
  add constraint profiles_availability_status_check
  check (availability_status in ('pending', 'ready', 'unavailable'));

comment on column public.profiles.availability_status is
  'Freelancer check-in intent: pending response, ready to receive work, or unavailable.';
comment on column public.profiles.availability_updated_at is
  'Last time the freelancer changed their check-in availability.';

-- Source migration: 20261017000009_preview_workflow_statuses.sql
-- New workflow states. Keep this migration separate because PostgreSQL enum
-- values cannot be used until the transaction that adds them has committed.
alter type public.job_status add value if not exists 'Preview';
alter type public.job_status add value if not exists 'Finished';

-- Source migration: 20261017000010_preview_workflow.sql
-- Replace final-result approval with preview review, then final CDR delivery.

alter table public.job_submissions
  add column if not exists submission_kind text not null default 'legacy';

alter table public.job_submissions
  drop constraint if exists job_submissions_submission_kind_check;
alter table public.job_submissions
  add constraint job_submissions_submission_kind_check
  check (submission_kind in ('legacy', 'preview'));

-- Historical approvals already completed their old workflow. Preserve those
-- jobs as Finished. Old pending file approvals return to Dikerjakan so the
-- freelancer can submit image previews under the new workflow.
alter table public.jobs drop constraint if exists jobs_active_have_assignee;
drop trigger if exists trg_guard_approved on public.jobs;

update public.jobs set status = 'Finished' where status = 'ACC';
update public.jobs set status = 'Dikerjakan', current_submission_id = null where status = 'MintaACC';
update public.jobs set status = 'Dikerjakan' where status = 'Revisi';

alter table public.jobs
  add constraint jobs_active_have_assignee check (
    (status in ('Antre','Dikerjakan','Preview','ACC','MintaACC','Revisi') and assignee_profile_id is not null)
    or status not in ('Antre','Dikerjakan','Preview','ACC','MintaACC','Revisi')
  );

alter table public.job_files drop constraint if exists job_files_file_role_check;
alter table public.job_files add constraint job_files_file_role_check
  check (file_role in ('reference','result','preview','source'));

create or replace function public.guard_job_approved() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_service_role() then return NEW; end if;
  if OLD.status in ('ACC','Finished') and (
    NEW.approved_fee is distinct from OLD.approved_fee or
    NEW.approved_for_profile_id is distinct from OLD.approved_for_profile_id or
    NEW.approved_submission_id is distinct from OLD.approved_submission_id or
    NEW.assignee_profile_id is distinct from OLD.assignee_profile_id
  ) then
    raise exception 'FORBIDDEN: fee dan penerima yang sudah ACC terkunci';
  end if;
  if OLD.status = 'Finished' and NEW.status is distinct from OLD.status then
    raise exception 'FORBIDDEN: job Finished terminal';
  end if;
  if NEW.status is distinct from OLD.status and NEW.status = 'Finished' and OLD.status <> 'ACC' then
    raise exception 'FORBIDDEN: hanya job ACC yang dapat diselesaikan';
  end if;
  if NEW.status is distinct from OLD.status and NEW.status = 'ACC' and OLD.status <> 'Preview' then
    raise exception 'FORBIDDEN: ACC hanya dapat diberikan setelah review Preview';
  end if;
  if NEW.status is distinct from OLD.status and NEW.status = 'ACC' and not public.is_admin() then
    raise exception 'FORBIDDEN: hanya Admin yang dapat menyetujui preview';
  end if;
  if NEW.status is distinct from OLD.status and NEW.status = 'ACC' and (
    NEW.approved_submission_id is distinct from OLD.current_submission_id or
    NEW.approved_for_profile_id is distinct from OLD.assignee_profile_id or
    NEW.approved_fee is distinct from NEW.fee or
    not exists (
      select 1 from public.job_submissions s
      where s.id = OLD.current_submission_id and s.job_id = OLD.id
        and s.submission_kind = 'preview' and s.decision = 'approved'
        and s.reviewed_by_profile_id is not null
    )
  ) then
    raise exception 'FORBIDDEN: preview belum disetujui oleh Admin';
  end if;
  if NEW.status is distinct from OLD.status and NEW.status = 'Dikerjakan' then
    if OLD.status in ('Antre','Revisi') and public.is_freelance()
      and OLD.assignee_profile_id = public.my_uid() then
      null;
    elsif OLD.status = 'Preview' and public.is_admin() and exists (
      select 1 from public.job_submissions s
      where s.id = OLD.current_submission_id and s.job_id = OLD.id
        and s.submission_kind = 'preview' and s.decision = 'revision_requested'
        and s.reviewed_by_profile_id is not null
    ) then
      null;
    else
      raise exception 'FORBIDDEN: hanya freelancer yang memulai atau Admin yang meminta revisi';
    end if;
  end if;
  if NEW.status = 'Preview' and OLD.status = 'Dikerjakan' and (
    not public.is_freelance() or OLD.assignee_profile_id is distinct from public.my_uid() or
    not exists (
      select 1 from public.job_submissions s
      where s.id = NEW.current_submission_id and s.job_id = OLD.id
        and s.submission_kind = 'preview' and s.decision = 'pending'
    )
  ) then
    raise exception 'FORBIDDEN: preview hanya dapat diajukan oleh freelancer yang ditugaskan';
  end if;
  if NEW.status is distinct from OLD.status and NEW.status = 'Finished' and (not public.is_freelance() or OLD.assignee_profile_id is distinct from public.my_uid()) then
    raise exception 'FORBIDDEN: freelancer yang ditugaskan mengirim file asli';
  end if;
  if OLD.status = 'ACC' and NEW.status = 'Finished' and not exists (
    select 1 from public.job_files f
    where f.job_id = OLD.id and f.file_role = 'source' and f.file_kind = 'CDR'
      and f.uploaded_by_profile_id = OLD.assignee_profile_id and f.expired_at is null
  ) then
    raise exception 'SOURCE_REQUIRED: unggah file asli CDR sebelum Finished';
  end if;
  if OLD.status = 'ACC' and NEW.status is distinct from OLD.status
     and NEW.status not in ('Finished','Dibatalkan') then
    raise exception 'FORBIDDEN: ACC preview hanya dapat diselesaikan atau dibatalkan';
  end if;
  if OLD.status = 'Dibatalkan' and NEW.status is distinct from OLD.status then
    raise exception 'FORBIDDEN: job Dibatalkan terminal';
  end if;
  return NEW;
end $$;
create trigger trg_guard_approved before update on public.jobs
  for each row execute function public.guard_job_approved();

-- Admins can assign/reassign before preview approval. ACC locks the recipient.
create or replace function public.assign_job(
  p_job text, p_target uuid, p_reason text, p_expected_rev int
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype; v_t public.profiles%rowtype; v_active int; v_max int;
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'Hanya Admin'); end if;
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.status in ('ACC','Finished','Dibatalkan') then return jsonb_build_object('ok', false, 'error', 'Penerima job sudah dikunci'); end if;
  if v_job.status in ('Preview','MintaACC') then return jsonb_build_object('ok', false, 'error', 'Tinjau preview sebelum mengalihkan job'); end if;
  select coalesce(max(max_active_jobs), 4) into v_max from public.app_settings where id = 1;
  select * into v_t from public.profiles where id = p_target;
  if not found or v_t.role <> 'freelance' then return jsonb_build_object('ok', false, 'error', 'Target bukan Freelance'); end if;
  perform pg_advisory_xact_lock(hashtext('assign:' || p_target::text)::bigint);
  if now() - v_t.last_seen >= interval '90 seconds' and not (v_job.assignee_profile_id = p_target and v_job.status = 'Antre') then
    return jsonb_build_object('ok', false, 'error', 'Freelance offline');
  end if;
  select count(*) into v_active from public.jobs
    where assignee_profile_id = p_target and status in ('Antre','Dikerjakan','Preview','ACC','MintaACC','Revisi') and id <> p_job;
  if v_active >= v_max then return jsonb_build_object('ok', false, 'error', 'Freelance penuh (batas ' || v_max || ' job aktif)'); end if;
  if v_job.assignee_profile_id is not null and v_job.assignee_profile_id <> p_target
     and v_job.status in ('Dikerjakan','Revisi') and nullif(trim(coalesce(p_reason,'')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Pengalihan Dikerjakan/Revisi wajib alasan');
  end if;
  if v_job.assignee_profile_id is null then
    update public.jobs set assignee_profile_id = p_target, status = 'Antre',
      antre_since = now(), revision = revision + 1 where id = p_job;
    insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, reason)
    values (p_job, public.my_uid(), 'assign', v_job.status, 'Antre', nullif(trim(coalesce(p_reason,'')), ''));
  else
    update public.jobs set assignee_profile_id = p_target,
      antre_since = case when v_job.status = 'Antre' then now() else antre_since end,
      revision = revision + 1 where id = p_job;
    insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, reason)
    values (p_job, public.my_uid(), 'reassign', v_job.status, v_job.status, nullif(trim(coalesce(p_reason,'')), ''));
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.transition_job(
  p_job text, p_to job_status, p_reason text, p_expected_rev int
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype; v_admin boolean;
begin
  v_admin := public.is_admin();
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.status in ('ACC','Finished','Dibatalkan') then return jsonb_build_object('ok', false, 'error', 'Job tidak dapat memulai ulang'); end if;
  if v_admin then return jsonb_build_object('ok', false, 'error', 'Freelancer yang ditugaskan memulai pekerjaan'); end if;
  if v_job.assignee_profile_id is distinct from public.my_uid() then
    return jsonb_build_object('ok', false, 'error', 'Bukan job milikmu');
  end if;
  if p_to <> 'Dikerjakan' or not (v_job.status = 'Antre' or v_job.status = 'Revisi') then
    return jsonb_build_object('ok', false, 'error', 'Gunakan alur preview untuk mengubah tahap ini');
  end if;
  update public.jobs set status = 'Dikerjakan', revision = revision + 1 where id = p_job;
  insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, reason)
  values (p_job, public.my_uid(), 'status', v_job.status, 'Dikerjakan', nullif(trim(coalesce(p_reason,'')), ''));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.submit_preview(
  p_job text, p_file_ids uuid[], p_note text, p_expected_rev int
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype; v_sub uuid; v_ver int; v_file uuid;
begin
  if not public.is_freelance() then return jsonb_build_object('ok', false, 'error', 'Hanya freelancer aktif yang dapat mengirim preview'); end if;
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.assignee_profile_id is distinct from public.my_uid() then return jsonb_build_object('ok', false, 'error', 'Bukan job milikmu'); end if;
  if v_job.status not in ('Dikerjakan','Revisi') then return jsonb_build_object('ok', false, 'error', 'Preview hanya dapat dikirim saat job dikerjakan'); end if;
  if coalesce(array_length(p_file_ids, 1), 0) < 1 then return jsonb_build_object('ok', false, 'error', 'Pilih minimal satu gambar preview'); end if;
  foreach v_file in array p_file_ids loop
    if not exists (
      select 1 from public.job_files f where f.id = v_file and f.job_id = p_job
        and f.file_role = 'preview' and f.file_kind in ('PNG','JPEG','SVG')
        and f.expired_at is null and f.uploaded_by_profile_id = public.my_uid()
    ) then return jsonb_build_object('ok', false, 'error', 'Pilih gambar preview milik Anda yang masih aktif'); end if;
  end loop;
  select coalesce(max(version), 0) + 1 into v_ver from public.job_submissions where job_id = p_job;
  v_sub := gen_random_uuid();
  insert into public.job_submissions(id, job_id, version, submitted_by_profile_id, note, submission_kind)
  values (v_sub, p_job, v_ver, public.my_uid(), nullif(trim(coalesce(p_note,'')), ''), 'preview');
  insert into public.job_submission_files(submission_id, job_file_id) select v_sub, unnest(p_file_ids);
  update public.jobs set status = 'Preview', current_submission_id = v_sub, revision = revision + 1 where id = p_job;
  insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status)
  values (p_job, public.my_uid(), 'preview_submit', v_job.status, 'Preview');
  return jsonb_build_object('ok', true, 'submission_id', v_sub);
end $$;

create or replace function public.review_submission(
  p_submission uuid, p_decision text, p_review_note text, p_expected_rev int
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_sub public.job_submissions%rowtype; v_job public.jobs%rowtype;
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'Hanya Admin'); end if;
  select * into v_sub from public.job_submissions where id = p_submission;
  if not found then return jsonb_build_object('ok', false, 'error', 'Submission tidak ditemukan'); end if;
  select * into v_job from public.jobs where id = v_sub.job_id for update;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.status <> 'Preview' or v_job.current_submission_id is distinct from p_submission
    or v_sub.submission_kind <> 'preview' or v_sub.decision <> 'pending' then
    return jsonb_build_object('ok', false, 'error', 'Preview ini bukan pengajuan aktif');
  end if;
  if p_decision = 'approved' then
    update public.job_submissions set decision = 'approved', reviewed_by_profile_id = public.my_uid(), reviewed_at = now() where id = p_submission;
    update public.jobs set status = 'ACC', approved_fee = fee, approved_for_profile_id = assignee_profile_id,
      approved_submission_id = p_submission, revision = revision + 1 where id = v_job.id;
    insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status)
    values (v_job.id, public.my_uid(), 'preview_approve', 'Preview', 'ACC');
  elsif p_decision = 'revision' then
    if nullif(trim(coalesce(p_review_note,'')), '') is null then return jsonb_build_object('ok', false, 'error', 'Alasan revisi wajib diisi'); end if;
    update public.job_submissions set decision = 'revision_requested', review_note = trim(p_review_note),
      reviewed_by_profile_id = public.my_uid(), reviewed_at = now() where id = p_submission;
    update public.jobs set status = 'Dikerjakan', revision = revision + 1 where id = v_job.id;
    insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, reason)
    values (v_job.id, public.my_uid(), 'preview_revision', 'Preview', 'Dikerjakan', trim(p_review_note));
  else
    return jsonb_build_object('ok', false, 'error', 'Keputusan tidak dikenal');
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.finish_job(p_job text, p_expected_rev int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype; v_final_files jsonb;
begin
  if not public.is_freelance() then return jsonb_build_object('ok', false, 'error', 'Hanya freelancer aktif yang dapat menyelesaikan job'); end if;
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.assignee_profile_id is distinct from public.my_uid() then return jsonb_build_object('ok', false, 'error', 'Bukan job milikmu'); end if;
  if v_job.status <> 'ACC' then return jsonb_build_object('ok', false, 'error', 'Preview harus di-ACC sebelum file asli dikirim'); end if;
  select coalesce(jsonb_agg(id), '[]'::jsonb) into v_final_files from public.job_files
  where job_id = p_job and file_role = 'source' and file_kind = 'CDR'
    and uploaded_by_profile_id = public.my_uid() and expired_at is null;
  if jsonb_array_length(v_final_files) = 0 then return jsonb_build_object('ok', false, 'error', 'Unggah minimal satu file asli CDR terlebih dahulu'); end if;
  update public.jobs set status = 'Finished', revision = revision + 1 where id = p_job;
  insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, details)
  values (p_job, public.my_uid(), 'finish', 'ACC', 'Finished', jsonb_build_object('final_file_ids', v_final_files));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.cancel_job(p_job text, p_reason text, p_expected_rev int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype;
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'Hanya Admin'); end if;
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.status in ('Finished','Dibatalkan') then return jsonb_build_object('ok', false, 'error', 'Job sudah terminal'); end if;
  if nullif(trim(coalesce(p_reason,'')), '') is null then return jsonb_build_object('ok', false, 'error', 'Alasan wajib'); end if;
  update public.jobs set status = 'Dibatalkan', cancelled_at = now(), cancelled_by_profile_id = public.my_uid(),
    cancellation_reason = trim(p_reason), revision = revision + 1 where id = p_job;
  insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, reason)
  values (p_job, public.my_uid(), 'cancel', v_job.status, 'Dibatalkan', trim(p_reason));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.update_job_fields(
  p_job text, p_expected_rev int, p_tim text, p_jenis job_type, p_qty int,
  p_deadline timestamptz, p_fee bigint, p_priority job_priority, p_brief text, p_ref text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype;
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'Hanya Admin'); end if;
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.status in ('ACC','Finished','Dibatalkan') then return jsonb_build_object('ok', false, 'error', 'Job yang sudah ACC tidak dapat diedit'); end if;
  update public.jobs set tim = coalesce(nullif(trim(p_tim), ''), tim), jenis = coalesce(p_jenis, jenis),
    qty = coalesce(p_qty, qty), deadline = coalesce(p_deadline, deadline), fee = coalesce(p_fee, fee),
    priority = coalesce(p_priority, priority), brief = coalesce(nullif(trim(p_brief), ''), brief),
    ref = coalesce(p_ref, ref), revision = revision + 1 where id = p_job;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.reserve_upload(p_job text, p_size bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype; v_total bigint; v_r uuid; v_admin boolean;
begin
  v_admin := public.is_admin();
  if not v_admin and not public.is_freelance() then return jsonb_build_object('ok', false, 'error', 'Role ini tidak dapat mengunggah file'); end if;
  select * into v_job from public.jobs where id = p_job;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.status in ('Finished','Dibatalkan') then return jsonb_build_object('ok', false, 'error', 'Job sudah selesai'); end if;
  if not v_admin and v_job.assignee_profile_id is distinct from public.my_uid() then return jsonb_build_object('ok', false, 'error', 'Bukan job milikmu'); end if;
  if not v_admin and v_job.status not in ('Dikerjakan','Revisi','ACC') then return jsonb_build_object('ok', false, 'error', 'Unggahan tidak tersedia pada tahap ini'); end if;
  if p_size <= 0 or p_size > 1073741824 then return jsonb_build_object('ok', false, 'error', 'Maks 1 GiB per file'); end if;
  perform pg_advisory_xact_lock(hashtext(p_job)::bigint);
  delete from public.job_upload_reservations where job_id = p_job and state = 'active' and expires_at <= now();
  select coalesce(sum(f.size_bytes),0) into v_total from public.job_files f where f.job_id = p_job and f.expired_at is null;
  select v_total + coalesce(sum(r.size_bytes),0) into v_total from public.job_upload_reservations r
    where r.job_id = p_job and r.state = 'active' and r.expires_at > now();
  if v_total + p_size > 10737418240 then return jsonb_build_object('ok', false, 'error', 'Total melebihi 10 GiB per job'); end if;
  insert into public.job_upload_reservations(job_id, profile_id, size_bytes) values (p_job, public.my_uid(), p_size) returning id into v_r;
  return jsonb_build_object('ok', true, 'reservation_id', v_r);
end $$;

create or replace function public.validate_job_file_kind() returns trigger
language plpgsql security definer set search_path = public as $$
declare ext text; v_job public.jobs%rowtype;
begin
  ext := lower(split_part(NEW.name, '.', array_length(string_to_array(NEW.name, '.'), 1)));
  if ext = 'jpg' then ext := 'jpeg'; end if;
  if ext not in ('pdf','cdr','png','jpeg','svg','docx','xlsx','pptx','ai','psd') then raise exception 'INVALID_TYPE: format file tidak didukung'; end if;
  if upper(ext) <> NEW.file_kind then raise exception 'INVALID_TYPE: file_kind tidak cocok ekstensi'; end if;
  select * into v_job from public.jobs where id = NEW.job_id;
  if not found then raise exception 'JOB_NOT_FOUND: job tidak ditemukan'; end if;
  if NEW.file_role = 'reference' then
    if not public.is_admin() then raise exception 'REFERENCE_ADMIN_ONLY: hanya Admin yang dapat mengunggah referensi'; end if;
    if v_job.status in ('Finished','Dibatalkan') then raise exception 'JOB_FINISHED: job sudah selesai'; end if;
  elsif NEW.file_role = 'preview' then
    if not public.is_freelance() or v_job.assignee_profile_id is distinct from public.my_uid()
      or v_job.status not in ('Dikerjakan','Revisi') or NEW.file_kind not in ('PNG','JPEG','SVG') then
      raise exception 'PREVIEW_UPLOAD_INVALID: unggah gambar preview hanya saat job dikerjakan';
    end if;
  elsif NEW.file_role = 'source' then
    if not public.is_freelance() or v_job.assignee_profile_id is distinct from public.my_uid()
      or v_job.status <> 'ACC' or NEW.file_kind <> 'CDR' then
      raise exception 'SOURCE_UPLOAD_INVALID: file asli CDR hanya dapat dikirim setelah preview di-ACC';
    end if;
  else
    raise exception 'FILE_ROLE_INVALID: gunakan referensi, preview, atau file asli';
  end if;
  return NEW;
end $$;

create or replace function public.preserve_finished_source_file() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_service_role() and OLD.file_role = 'source'
    and exists (select 1 from public.jobs j where j.id = OLD.job_id and j.status = 'Finished') then
    raise exception 'FILE_LOCKED: file asli job Finished tidak dapat dihapus';
  end if;
  return OLD;
end $$;
drop trigger if exists trg_preserve_finished_source_file on public.job_files;
create trigger trg_preserve_finished_source_file before delete on public.job_files
  for each row execute function public.preserve_finished_source_file();

-- Finance reporting counts only jobs whose original files have been delivered.
create or replace function public.finance_acc_recipients()
returns table(profile_id uuid, profile_name text)
language sql stable security definer set search_path = public as $$
  select distinct p.id, p.name
  from public.profiles p join public.jobs j on coalesce(j.approved_for_profile_id, j.assignee_profile_id) = p.id
  where public.is_finance() and j.status = 'Finished'
$$;
create or replace function public.finance_acc_approval_times()
returns table(job_id text, approved_at timestamptz)
language sql stable security definer set search_path = public as $$
  select e.job_id, max(e.created_at)
  from public.job_events e join public.jobs j on j.id = e.job_id
  where public.is_finance() and j.status = 'Finished' and e.event_type = 'preview_approve'
  group by e.job_id
$$;
drop policy if exists jobs_finance_acc_read on public.jobs;
create policy jobs_finance_acc_read on public.jobs for select to authenticated
  using (public.is_finance() and status = 'Finished');

-- The old submission endpoint would bypass preview review; disable it.
revoke all on function public.submit_for_acc(text, uuid[], text, int) from public, anon, authenticated;
revoke all on function public.submit_preview(text, uuid[], text, int) from public, anon;
grant execute on function public.submit_preview(text, uuid[], text, int) to authenticated, service_role;
revoke all on function public.finish_job(text, int) from public, anon;
grant execute on function public.finish_job(text, int) to authenticated, service_role;

-- Source migration: 20261017000011_freelancer_compensation.sql
-- Let Finance assign a current compensation scheme to approved freelancers.
-- Per-job compensation follows the job fee frozen when its preview is approved.

create table if not exists public.freelancer_compensation (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  pay_scheme text not null check (pay_scheme in ('per_job', 'daily', 'weekly', 'monthly')),
  amount bigint,
  updated_by_profile_id uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now(),
  constraint freelancer_compensation_amount_check check (
    (pay_scheme = 'per_job' and amount is null)
    or (pay_scheme in ('daily', 'weekly', 'monthly') and amount between 1 and 1000000000000)
  )
);

alter table public.freelancer_compensation enable row level security;
revoke all on public.freelancer_compensation from public, anon, authenticated;
grant all on public.freelancer_compensation to service_role;

create or replace function public.finance_freelancer_compensation()
returns table(
  profile_id uuid,
  profile_name text,
  is_active boolean,
  pay_scheme text,
  amount bigint,
  updated_at timestamptz
)
language sql stable security definer set search_path = public as $$
  select p.id, p.name, p.is_active, c.pay_scheme, c.amount, c.updated_at
  from public.profiles p
  left join public.freelancer_compensation c on c.profile_id = p.id
  where public.is_finance()
    and p.role = 'freelance'
    and p.registration_status = 'approved'
  order by p.name, p.id
$$;
revoke all on function public.finance_freelancer_compensation() from public, anon;
grant execute on function public.finance_freelancer_compensation() to authenticated, service_role;

create or replace function public.set_freelancer_compensation(
  p_profile uuid,
  p_pay_scheme text,
  p_amount bigint
) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  v_profile public.profiles%rowtype;
  v_old public.freelancer_compensation%rowtype;
  v_actor_label text;
  v_before jsonb;
  v_after jsonb;
begin
  if not public.is_finance() then
    return jsonb_build_object('ok', false, 'error', 'Hanya Finance yang dapat mengatur skema upah.');
  end if;

  select * into v_profile from public.profiles where id = p_profile for update;
  if not found or v_profile.role <> 'freelance' or v_profile.registration_status <> 'approved' then
    return jsonb_build_object('ok', false, 'error', 'Freelancer tidak ditemukan atau belum disetujui.');
  end if;

  select * into v_old from public.freelancer_compensation where profile_id = p_profile for update;
  if p_pay_scheme is null then
    if not found then return jsonb_build_object('ok', true, 'changed', false); end if;
    v_before := jsonb_build_object('pay_scheme', v_old.pay_scheme, 'amount', v_old.amount);
    delete from public.freelancer_compensation where profile_id = p_profile;
    v_after := '{}'::jsonb;
  else
    if p_pay_scheme not in ('per_job', 'daily', 'weekly', 'monthly') then
      return jsonb_build_object('ok', false, 'error', 'Skema upah tidak valid.');
    end if;
    if p_pay_scheme = 'per_job' then
      if p_amount is not null then return jsonb_build_object('ok', false, 'error', 'Skema per job mengikuti fee pada setiap job.'); end if;
    elsif p_amount is null or p_amount < 1 or p_amount > 1000000000000 then
      return jsonb_build_object('ok', false, 'error', 'Nominal upah wajib berupa angka bulat lebih dari Rp0.');
    end if;

    if found and v_old.pay_scheme = p_pay_scheme and v_old.amount is not distinct from p_amount then
      return jsonb_build_object('ok', true, 'changed', false);
    end if;

    v_before := case when found
      then jsonb_build_object('pay_scheme', v_old.pay_scheme, 'amount', v_old.amount)
      else '{}'::jsonb end;
    insert into public.freelancer_compensation(profile_id, pay_scheme, amount, updated_by_profile_id, updated_at)
    values (p_profile, p_pay_scheme, p_amount, auth.uid(), now())
    on conflict (profile_id) do update set
      pay_scheme = excluded.pay_scheme,
      amount = excluded.amount,
      updated_by_profile_id = excluded.updated_by_profile_id,
      updated_at = excluded.updated_at;
    v_after := jsonb_build_object('pay_scheme', p_pay_scheme, 'amount', p_amount);
  end if;

  select name into v_actor_label from public.profiles where id = auth.uid();
  insert into public.admin_audit_events(
    event_type, target_profile_id, target_label, actor_profile_id, actor_label,
    before_data, after_data, reason
  ) values (
    'freelancer_compensation_updated', p_profile, v_profile.name, auth.uid(), coalesce(v_actor_label, 'Finance'),
    coalesce(v_before, '{}'::jsonb), coalesce(v_after, '{}'::jsonb), 'Perubahan skema upah freelancer'
  );
  return jsonb_build_object('ok', true, 'changed', true);
end $$;
revoke all on function public.set_freelancer_compensation(uuid, text, bigint) from public, anon;
grant execute on function public.set_freelancer_compensation(uuid, text, bigint) to authenticated, service_role;

-- Source migration: 20261017000012_freelancer_payment_schedule.sql
-- Compensation amounts remain on the job. Finance only configures payout timing
-- and uses the freelancer's validated bank account for manual transfer.

drop function if exists public.finance_freelancer_compensation();
drop function if exists public.set_freelancer_compensation(uuid, text, bigint);

alter table public.freelancer_compensation rename to freelancer_payment_settings;
alter table public.freelancer_payment_settings rename column pay_scheme to payout_frequency;
alter table public.freelancer_payment_settings
  drop constraint if exists freelancer_compensation_amount_check;
alter table public.freelancer_payment_settings
  drop constraint if exists freelancer_compensation_pay_scheme_check;
alter table public.freelancer_payment_settings drop column amount;
alter table public.freelancer_payment_settings
  add constraint freelancer_payment_settings_payout_frequency_check
  check (payout_frequency in ('per_job', 'daily', 'weekly', 'monthly'));
alter table public.freelancer_payment_settings
  add column payout_method text not null default 'bank_transfer'
  check (payout_method = 'bank_transfer');
alter table public.freelancer_payment_settings
  rename constraint freelancer_compensation_pkey to freelancer_payment_settings_pkey;
alter table public.freelancer_payment_settings
  rename constraint freelancer_compensation_profile_id_fkey to freelancer_payment_settings_profile_id_fkey;
alter table public.freelancer_payment_settings
  rename constraint freelancer_compensation_updated_by_profile_id_fkey to freelancer_payment_settings_updated_by_profile_id_fkey;

create or replace function public.finance_freelancer_payment_settings()
returns table(
  profile_id uuid,
  profile_name text,
  is_active boolean,
  payout_frequency text,
  payout_method text,
  bank_name text,
  account_number text,
  account_holder text,
  updated_at timestamptz
)
language sql stable security definer set search_path = public as $$
  select p.id, p.name, p.is_active,
    coalesce(s.payout_frequency, 'per_job'),
    coalesce(s.payout_method, 'bank_transfer'),
    b.bank_name, b.account_number, b.account_holder, s.updated_at
  from public.profiles p
  left join public.freelancer_payment_settings s on s.profile_id = p.id
  left join public.freelancer_bank_accounts b on b.profile_id = p.id
  where public.is_finance()
    and p.role = 'freelance'
    and p.registration_status = 'approved'
  order by p.name, p.id
$$;
revoke all on function public.finance_freelancer_payment_settings() from public, anon;
grant execute on function public.finance_freelancer_payment_settings() to authenticated, service_role;

create or replace function public.set_freelancer_payment_schedule(
  p_profile uuid,
  p_payout_frequency text
) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  v_profile public.profiles%rowtype;
  v_old public.freelancer_payment_settings%rowtype;
  v_actor_label text;
  v_before jsonb;
  v_after jsonb;
begin
  if not public.is_finance() then
    return jsonb_build_object('ok', false, 'error', 'Hanya Finance yang dapat mengatur jadwal pembayaran.');
  end if;

  if p_payout_frequency is null or p_payout_frequency not in ('per_job', 'daily', 'weekly', 'monthly') then
    return jsonb_build_object('ok', false, 'error', 'Jadwal pembayaran tidak valid.');
  end if;

  select * into v_profile from public.profiles where id = p_profile for update;
  if not found or v_profile.role <> 'freelance' or v_profile.registration_status <> 'approved' then
    return jsonb_build_object('ok', false, 'error', 'Freelancer tidak ditemukan atau belum disetujui.');
  end if;

  select * into v_old from public.freelancer_payment_settings where profile_id = p_profile for update;
  if found and v_old.payout_frequency = p_payout_frequency then
    return jsonb_build_object('ok', true, 'changed', false);
  end if;
  v_before := case when found
    then jsonb_build_object('payout_frequency', v_old.payout_frequency, 'payout_method', v_old.payout_method)
    else jsonb_build_object('payout_frequency', 'per_job', 'payout_method', 'bank_transfer') end;

  insert into public.freelancer_payment_settings(
    profile_id, payout_frequency, payout_method, updated_by_profile_id, updated_at
  ) values (p_profile, p_payout_frequency, 'bank_transfer', auth.uid(), now())
  on conflict (profile_id) do update set
    payout_frequency = excluded.payout_frequency,
    payout_method = excluded.payout_method,
    updated_by_profile_id = excluded.updated_by_profile_id,
    updated_at = excluded.updated_at;
  v_after := jsonb_build_object('payout_frequency', p_payout_frequency, 'payout_method', 'bank_transfer');

  select name into v_actor_label from public.profiles where id = auth.uid();
  insert into public.admin_audit_events(
    event_type, target_profile_id, target_label, actor_profile_id, actor_label,
    before_data, after_data, reason
  ) values (
    'freelancer_payment_schedule_updated', p_profile, v_profile.name, auth.uid(), coalesce(v_actor_label, 'Finance'),
    coalesce(v_before, '{}'::jsonb), coalesce(v_after, '{}'::jsonb), 'Perubahan jadwal pembayaran freelancer'
  );
  return jsonb_build_object('ok', true, 'changed', true);
end $$;
revoke all on function public.set_freelancer_payment_schedule(uuid, text) from public, anon;
grant execute on function public.set_freelancer_payment_schedule(uuid, text) to authenticated, service_role;

-- Source migration: 20261017000013_freelancer_profile_photos.sql
-- Freelancers may keep one private profile photo in their own storage folder.
alter table public.profiles
  add column if not exists avatar_path text;

alter table public.profiles
  drop constraint if exists profiles_avatar_path_owner_check;
alter table public.profiles
  add constraint profiles_avatar_path_owner_check
  check (avatar_path is null or avatar_path like id::text || '/%');

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'profile-photos',
  'profile-photos',
  false,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp']::text[]
)
on conflict (id) do nothing;

drop policy if exists profile_photos_read_self on storage.objects;
drop policy if exists profile_photos_upload_self on storage.objects;
drop policy if exists profile_photos_delete_self on storage.objects;

create policy profile_photos_read_self on storage.objects for select to authenticated
  using (
    bucket_id = 'profile-photos'
    and public.is_freelance()
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy profile_photos_upload_self on storage.objects for insert to authenticated
  with check (
    bucket_id = 'profile-photos'
    and public.is_freelance()
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy profile_photos_delete_self on storage.objects for delete to authenticated
  using (
    bucket_id = 'profile-photos'
    and public.is_freelance()
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Source migration: 20261017000014_pending_freelancer_login.sql
-- Freelancer applicants can sign in immediately to see their Admin Review status.
-- Confirm existing pending Auth users too; the review decision remains the access gate.
update auth.users as u
set email_confirmed_at = now(),
    updated_at = now()
from public.profiles as p
where p.id = u.id
  and p.role = 'freelance'
  and p.registration_status = 'pending'
  and p.is_active = false
  and u.email_confirmed_at is null;

-- Keep a pending freelancer's own profile readable for the Admin Review screen,
-- while withholding their identity from operational RLS policies and RPCs.
create or replace function public.my_uid() returns uuid
language sql stable security definer set search_path = public, auth as $$
  select auth.uid()
  where exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.is_active
      and p.registration_status = 'approved'
  )
$$;

drop policy if exists prof_self_select on public.profiles;
create policy prof_self_select on public.profiles
  for select to authenticated using (id = auth.uid());

-- Source migration: 20261017000015_direct_account_creation.sql
-- Create users directly from Super Admin user management without email invites.
create or replace function public.set_created_account_role(
  p_target uuid,
  p_new_role text,
  p_actor uuid,
  p_reason text
) returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare
  v_old_role text;
  v_old_active boolean;
  v_old_registration_status text;
  v_target_label text;
  v_actor_label text;
begin
  if not public.is_service_role() then
    return jsonb_build_object('ok', false, 'error', 'Hanya server tepercaya');
  end if;
  if coalesce(p_new_role, '') not in ('admin', 'finance', 'freelance') then
    return jsonb_build_object('ok', false, 'error', 'Role akun tidak dikenal');
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Alasan pembuatan akun wajib diisi');
  end if;

  select role, is_active, registration_status, name
    into v_old_role, v_old_active, v_old_registration_status, v_target_label
  from public.profiles where id = p_target for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Profil akun baru belum tersedia');
  end if;
  if v_old_role <> 'freelance' or v_old_active or v_old_registration_status <> 'pending' then
    return jsonb_build_object('ok', false, 'error', 'Profil bukan akun baru yang menunggu aktivasi');
  end if;

  select name into v_actor_label
  from public.profiles where id = p_actor and role = 'super_admin' and is_active;
  if v_actor_label is null then
    return jsonb_build_object('ok', false, 'error', 'Pelaku pembuatan akun tidak valid');
  end if;

  update public.profiles set
    role = p_new_role,
    is_active = true,
    registration_status = 'approved',
    registration_reviewed_at = now(),
    registration_reviewed_by_profile_id = p_actor,
    registration_review_reason = 'Akun dibuat langsung melalui Manajemen Pengguna.'
  where id = p_target;

  insert into public.profile_role_events(
    target_profile_id, old_role, new_role, old_active, new_active,
    actor_profile_id, actor_label, reason
  ) values (
    p_target, v_old_role, p_new_role, v_old_active, true,
    p_actor, v_actor_label, trim(p_reason)
  );

  insert into public.admin_audit_events(
    event_type, target_profile_id, target_label, actor_profile_id, actor_label,
    before_data, after_data, reason
  ) values (
    'account_created', p_target, v_target_label, p_actor, v_actor_label,
    jsonb_build_object('role', v_old_role, 'is_active', v_old_active, 'registration_status', v_old_registration_status),
    jsonb_build_object('role', p_new_role, 'is_active', true, 'registration_status', 'approved', 'invitation_sent', false),
    trim(p_reason)
  );

  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.set_created_account_role(uuid, text, uuid, text) from public, anon, authenticated;
grant execute on function public.set_created_account_role(uuid, text, uuid, text) to service_role;

drop function if exists public.set_invited_account_role(uuid, text, uuid, text);

-- Source migration: 20261017000016_super_admin_account_editing.sql
-- Allow Super Admin to edit managed profile details while keeping phone
-- numbers protected by profile_contacts RLS and recording a single audit row.
create or replace function public.update_managed_account(
  p_target uuid,
  p_actor uuid,
  p_name text,
  p_whatsapp text,
  p_old_email text,
  p_email_changed boolean,
  p_password_changed boolean,
  p_reason text
) returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare
  v_old_name text;
  v_old_whatsapp text;
  v_new_whatsapp text := nullif(btrim(coalesce(p_whatsapp, '')), '');
  v_new_email text;
  v_actor_label text;
  v_changed boolean;
begin
  if not public.is_service_role() then
    return jsonb_build_object('ok', false, 'error', 'Hanya server tepercaya');
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Alasan perubahan wajib diisi');
  end if;
  if length(btrim(coalesce(p_name, ''))) < 3 or length(btrim(coalesce(p_name, ''))) > 100 then
    return jsonb_build_object('ok', false, 'error', 'Nama harus terdiri dari 3–100 karakter');
  end if;
  if v_new_whatsapp is not null and v_new_whatsapp !~ '^\+?[0-9(). -]{8,24}$' then
    return jsonb_build_object('ok', false, 'error', 'Nomor WhatsApp tidak valid');
  end if;

  select name into v_actor_label
  from public.profiles
  where id = p_actor and role = 'super_admin' and is_active;
  if v_actor_label is null then
    return jsonb_build_object('ok', false, 'error', 'Pelaku perubahan tidak valid');
  end if;

  select p.name, c.whatsapp into v_old_name, v_old_whatsapp
  from public.profiles p
  left join public.profile_contacts c on c.profile_id = p.id
  where p.id = p_target
  for update of p;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Profil akun tidak ditemukan');
  end if;

  select u.email into v_new_email from auth.users u where u.id = p_target;
  if v_new_email is null then
    return jsonb_build_object('ok', false, 'error', 'Akun Auth tidak ditemukan');
  end if;

  v_changed := v_old_name is distinct from btrim(p_name)
    or v_old_whatsapp is distinct from v_new_whatsapp
    or coalesce(p_email_changed, false)
    or coalesce(p_password_changed, false);

  update public.profiles set name = btrim(p_name) where id = p_target;
  if v_new_whatsapp is null then
    delete from public.profile_contacts where profile_id = p_target;
  else
    insert into public.profile_contacts(profile_id, whatsapp, updated_at)
    values (p_target, v_new_whatsapp, now())
    on conflict (profile_id) do update set whatsapp = excluded.whatsapp, updated_at = excluded.updated_at;
  end if;

  if v_changed then
    insert into public.admin_audit_events(
      event_type, target_profile_id, target_label, actor_profile_id, actor_label,
      before_data, after_data, reason
    ) values (
      'account_updated', p_target, btrim(p_name), p_actor, v_actor_label,
      jsonb_build_object(
        'name', v_old_name,
        'whatsapp', v_old_whatsapp,
        'email', case when coalesce(p_email_changed, false) then p_old_email else v_new_email end
      ),
      jsonb_build_object(
        'name', btrim(p_name),
        'whatsapp', v_new_whatsapp,
        'email', v_new_email,
        'password_changed', coalesce(p_password_changed, false)
      ),
      btrim(p_reason)
    );
  end if;

  return jsonb_build_object('ok', true, 'changed', v_changed);
exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'Nama tersebut sudah digunakan akun lain');
end $$;

revoke all on function public.update_managed_account(uuid, uuid, text, text, text, boolean, boolean, text) from public, anon, authenticated;
grant execute on function public.update_managed_account(uuid, uuid, text, text, text, boolean, boolean, text) to service_role;

-- Source migration: 20261017000017_admin_account_deletion.sql
-- Admins need a searchable account directory for account cleanup. Audit access
-- remains Super Admin-only; this directory contains only account identity data.
create or replace function public.managed_account_directory()
returns table(
  profile_id uuid,
  name text,
  role text,
  is_active boolean,
  last_seen timestamptz,
  email text,
  email_confirmed_at timestamptz
)
language sql stable security definer set search_path = public, auth as $$
  select p.id, p.name, p.role, p.is_active, p.last_seen, u.email, u.email_confirmed_at
  from public.profiles p
  join auth.users u on u.id = p.id
  where public.is_admin()
  order by p.name, p.id
$$;

revoke all on function public.managed_account_directory() from public, anon;
grant execute on function public.managed_account_directory() to authenticated, service_role;

-- The target profile has already been removed through Supabase Auth when this
-- server-only function records the deletion. Audit target IDs are intentionally
-- not foreign keys so the record survives account removal.
create or replace function public.record_managed_account_deletion(
  p_target uuid,
  p_actor uuid,
  p_target_label text,
  p_target_email text,
  p_reason text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor_label text;
begin
  if not public.is_service_role() then
    return jsonb_build_object('ok', false, 'error', 'Hanya server tepercaya');
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Alasan penghapusan wajib diisi');
  end if;
  if exists (select 1 from public.profiles where id = p_target) then
    return jsonb_build_object('ok', false, 'error', 'Akun belum berhasil dihapus');
  end if;

  select name into v_actor_label
  from public.profiles
  where id = p_actor and is_active and role in ('admin', 'super_admin');
  if v_actor_label is null then
    return jsonb_build_object('ok', false, 'error', 'Admin yang menghapus tidak valid');
  end if;

  insert into public.admin_audit_events(
    event_type, target_profile_id, target_label, actor_profile_id, actor_label,
    before_data, after_data, reason
  ) values (
    'account_deleted', p_target, coalesce(nullif(trim(p_target_label), ''), p_target_email), p_actor, v_actor_label,
    jsonb_build_object('email', p_target_email, 'exists', true),
    jsonb_build_object('exists', false),
    trim(p_reason)
  );
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.record_managed_account_deletion(uuid, uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.record_managed_account_deletion(uuid, uuid, text, text, text) to service_role;

-- Source migration: 20261017000018_super_admin_only_account_directory.sql
-- Keep account emails in the management directory visible only to a verified
-- Super Admin. Admin accounts do not have access to /pengguna.
create or replace function public.managed_account_directory()
returns table(
  profile_id uuid,
  name text,
  role text,
  is_active boolean,
  last_seen timestamptz,
  email text,
  email_confirmed_at timestamptz
)
language sql stable security definer set search_path = public, auth as $$
  select p.id, p.name, p.role, p.is_active, p.last_seen, u.email, u.email_confirmed_at
  from public.profiles p
  join auth.users u on u.id = p.id
  where public.is_super_admin()
  order by p.name, p.id
$$;

revoke all on function public.managed_account_directory() from public, anon;
grant execute on function public.managed_account_directory() to authenticated, service_role;

-- Source migration: 20261017000019_finance_payment_ledger.sql
-- Finance payment ledger: preserve finish dates, record transfers and allocations,
-- and expose curated, paginated reporting functions to Finance.

alter table public.jobs add column if not exists finished_at timestamptz;

update public.jobs j
set finished_at = coalesce(
  (select max(e.created_at) from public.job_events e where e.job_id = j.id and e.event_type = 'finish'),
  j.created_at
)
where j.status = 'Finished' and j.finished_at is null;

create index if not exists jobs_finished_at_recipient_idx
  on public.jobs (finished_at, (coalesce(approved_for_profile_id, assignee_profile_id)))
  where status = 'Finished';

create or replace function public.guard_job_finished_at() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if OLD.status = 'Finished' and NEW.status <> 'Finished' then
    raise exception 'FINISHED_JOB_LOCKED: job selesai tidak dapat dibuka kembali';
  end if;
  if OLD.finished_at is not null and NEW.finished_at is distinct from OLD.finished_at then
    raise exception 'FINISH_TIME_LOCKED: waktu selesai tidak dapat diubah';
  end if;
  if NEW.status <> 'Finished' and NEW.finished_at is not null then
    raise exception 'FINISH_TIME_INVALID: hanya job Finished yang memiliki waktu selesai';
  end if;
  if NEW.status = 'Finished' and (OLD.status <> 'Finished' or OLD.finished_at is null) then
    NEW.finished_at := now();
  end if;
  return NEW;
end $$;

drop trigger if exists trg_guard_job_finished_at on public.jobs;
create trigger trg_guard_job_finished_at before update on public.jobs
  for each row execute function public.guard_job_finished_at();

-- Finance no longer reads the jobs table directly. Reports below expose only
-- the fields required for reconciliation, avoiding brief/reference disclosure.
drop policy if exists jobs_finance_acc_read on public.jobs;
revoke all on function public.finance_acc_recipients() from public, anon, authenticated;
revoke all on function public.finance_acc_approval_times() from public, anon, authenticated;

create table public.freelancer_payment_records (
  id uuid primary key default gen_random_uuid(),
  recipient_profile_id uuid not null,
  recipient_label text not null,
  snapshot_bank_name text,
  snapshot_account_number text,
  snapshot_account_holder text,
  amount bigint not null check (amount > 0),
  paid_at timestamptz not null,
  bank_reference text not null check (char_length(btrim(bank_reference)) between 1 and 120),
  proof_path text not null,
  note text not null default '' check (char_length(note) <= 1000),
  status text not null default 'posted' check (status in ('posted', 'voided')),
  recorded_by_profile_id uuid references public.profiles(id) on delete set null,
  recorded_at timestamptz not null default now(),
  voided_by_profile_id uuid references public.profiles(id) on delete set null,
  voided_at timestamptz,
  void_reason text,
  constraint freelancer_payment_records_void_check check (
    (status = 'posted' and voided_at is null and voided_by_profile_id is null and void_reason is null)
    or (status = 'voided' and voided_at is not null and void_reason is not null)
  )
);

create unique index freelancer_payment_records_reference_unique
  on public.freelancer_payment_records (recipient_profile_id, lower(btrim(bank_reference)));
create unique index freelancer_payment_records_proof_path_unique
  on public.freelancer_payment_records (proof_path);
create index freelancer_payment_records_paid_at_idx
  on public.freelancer_payment_records (paid_at desc, id desc);
create index freelancer_payment_records_recipient_idx
  on public.freelancer_payment_records (recipient_profile_id, paid_at desc);

create table public.freelancer_payment_allocations (
  id uuid primary key default gen_random_uuid(),
  payment_record_id uuid not null references public.freelancer_payment_records(id) on delete restrict,
  job_id text not null references public.jobs(id) on delete restrict,
  amount bigint not null check (amount > 0),
  created_at timestamptz not null default now(),
  unique (payment_record_id, job_id)
);
create index freelancer_payment_allocations_job_idx on public.freelancer_payment_allocations (job_id);

create table public.freelancer_payment_events (
  id uuid primary key default gen_random_uuid(),
  payment_record_id uuid references public.freelancer_payment_records(id) on delete restrict,
  target_profile_id uuid,
  actor_profile_id uuid references public.profiles(id) on delete set null,
  event_type text not null check (event_type in (
    'payment_recorded', 'payment_voided', 'payment_proof_viewed', 'bank_details_viewed'
  )),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.freelancer_payment_events
  drop constraint if exists freelancer_payment_events_event_type_check;
alter table public.freelancer_payment_events
  add constraint freelancer_payment_events_event_type_check check (event_type in (
    'payment_recorded', 'payment_voided', 'payment_proof_viewed', 'bank_details_viewed',
    'payment_schedule_updated'
  ));
create index freelancer_payment_events_record_idx
  on public.freelancer_payment_events (payment_record_id, created_at desc);

create or replace function public.log_freelancer_payment_schedule_change()
returns trigger language plpgsql security definer set search_path = public, auth as $$
begin
  insert into public.freelancer_payment_events(target_profile_id, actor_profile_id, event_type, details)
  values (
    new.profile_id,
    coalesce(new.updated_by_profile_id, auth.uid()),
    'payment_schedule_updated',
    jsonb_build_object(
      'before', case when tg_op = 'INSERT' then jsonb_build_object('payout_frequency', 'per_job')
        else jsonb_build_object('payout_frequency', old.payout_frequency, 'payout_method', old.payout_method) end,
      'after', jsonb_build_object('payout_frequency', new.payout_frequency, 'payout_method', new.payout_method)
    )
  );
  return new;
end $$;
drop trigger if exists trg_log_freelancer_payment_schedule_change on public.freelancer_payment_settings;
create trigger trg_log_freelancer_payment_schedule_change after insert or update on public.freelancer_payment_settings
  for each row execute function public.log_freelancer_payment_schedule_change();

alter table public.freelancer_payment_records enable row level security;
alter table public.freelancer_payment_allocations enable row level security;
alter table public.freelancer_payment_events enable row level security;
revoke all on public.freelancer_payment_records, public.freelancer_payment_allocations,
  public.freelancer_payment_events from public, anon, authenticated;
grant all on public.freelancer_payment_records, public.freelancer_payment_allocations,
  public.freelancer_payment_events to service_role;

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('finance-payment-proofs', 'finance-payment-proofs', false, 10485760,
  array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = 10485760,
  allowed_mime_types = excluded.allowed_mime_types;

create or replace function public.finance_payment_proof_is_linked(p_path text)
returns boolean language sql stable security definer set search_path = public as $$
  select case
    when not (public.is_finance() or public.is_super_admin())
      or split_part(p_path, '/', 1) <> auth.uid()::text then true
    else exists (select 1 from public.freelancer_payment_records r where r.proof_path = p_path)
  end
$$;

create or replace function public.finance_payment_proof_is_audited(p_path text)
returns boolean language sql stable security definer set search_path = public as $$
  select (public.is_finance() or public.is_super_admin()) and exists (
    select 1
    from public.freelancer_payment_records r
    join public.freelancer_payment_events e on e.payment_record_id = r.id
    where r.proof_path = p_path
      and e.event_type = 'payment_proof_viewed'
      and e.actor_profile_id = auth.uid()
      and e.created_at >= now() - interval '5 minutes'
  )
$$;
revoke all on function public.finance_payment_proof_is_audited(text) from public, anon;
grant execute on function public.finance_payment_proof_is_audited(text) to authenticated, service_role;

drop policy if exists finance_payment_proof_read on storage.objects;
create policy finance_payment_proof_read on storage.objects for select to authenticated
  using (bucket_id = 'finance-payment-proofs' and public.finance_payment_proof_is_audited(name));
drop policy if exists finance_payment_proof_insert on storage.objects;
create policy finance_payment_proof_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'finance-payment-proofs'
    and (public.is_finance() or public.is_super_admin())
    and split_part(name, '/', 1) = auth.uid()::text);
drop policy if exists finance_payment_proof_delete on storage.objects;
create policy finance_payment_proof_delete on storage.objects for delete to authenticated
  using (bucket_id = 'finance-payment-proofs'
    and (public.is_finance() or public.is_super_admin())
    and split_part(name, '/', 1) = auth.uid()::text
    and not public.finance_payment_proof_is_linked(name));

create or replace function public.finish_job(p_job text, p_expected_rev int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype; v_final_files jsonb;
begin
  if not public.is_freelance() then return jsonb_build_object('ok', false, 'error', 'Hanya freelancer aktif yang dapat menyelesaikan job'); end if;
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.assignee_profile_id is distinct from public.my_uid() then return jsonb_build_object('ok', false, 'error', 'Bukan job milikmu'); end if;
  if v_job.status <> 'ACC' then return jsonb_build_object('ok', false, 'error', 'Preview harus di-ACC sebelum file asli dikirim'); end if;
  select coalesce(jsonb_agg(id), '[]'::jsonb) into v_final_files from public.job_files
  where job_id = p_job and file_role = 'source' and file_kind = 'CDR'
    and uploaded_by_profile_id = public.my_uid() and expired_at is null;
  if jsonb_array_length(v_final_files) = 0 then return jsonb_build_object('ok', false, 'error', 'Unggah minimal satu file asli CDR terlebih dahulu'); end if;
  update public.jobs set status = 'Finished', finished_at = now(), revision = revision + 1 where id = p_job;
  insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, details)
  values (p_job, public.my_uid(), 'finish', 'ACC', 'Finished', jsonb_build_object('final_file_ids', v_final_files));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.finance_monthly_payment_report(p_month date)
returns table(
  profile_id uuid,
  profile_name text,
  opening_balance bigint,
  earned_this_month bigint,
  paid_this_month bigint,
  closing_balance bigint,
  jobs_finished_this_month bigint
)
language plpgsql stable security definer set search_path = public as $$
declare v_month date; v_start timestamptz; v_end timestamptz;
begin
  if not (public.is_finance() or public.is_super_admin()) then
    raise exception 'FORBIDDEN: hanya Finance yang dapat melihat laporan pembayaran';
  end if;
  if p_month is null then raise exception 'Pilih bulan laporan'; end if;
  v_month := date_trunc('month', p_month)::date;
  v_start := v_month::timestamp at time zone 'Asia/Jakarta';
  v_end := (v_month + interval '1 month')::timestamp at time zone 'Asia/Jakarta';
  return query
    with recipient_sources as (
      select p.id, p.name from public.profiles p
      where p.role = 'freelance' and p.registration_status = 'approved'
      union all
      select r.recipient_profile_id, r.recipient_label from public.freelancer_payment_records r
      union all
      select coalesce(j.approved_for_profile_id, j.assignee_profile_id),
        coalesce(max(p.name), coalesce(j.approved_for_profile_id, j.assignee_profile_id)::text)
      from public.jobs j
      left join public.profiles p on p.id = coalesce(j.approved_for_profile_id, j.assignee_profile_id)
      where j.status = 'Finished' and coalesce(j.approved_for_profile_id, j.assignee_profile_id) is not null
      group by coalesce(j.approved_for_profile_id, j.assignee_profile_id)
    ), recipients as (
      select source.id, coalesce(max(profile.name), max(source.name), source.id::text) as name
      from recipient_sources source
      left join public.profiles profile on profile.id = source.id
      group by source.id
    ), earned as (
      select coalesce(j.approved_for_profile_id, j.assignee_profile_id) as recipient_id,
        coalesce(sum(coalesce(j.approved_fee, j.fee)), 0)::bigint as total,
        count(*)::bigint as job_count
      from public.jobs j
      where j.status = 'Finished' and j.finished_at >= v_start and j.finished_at < v_end
      group by coalesce(j.approved_for_profile_id, j.assignee_profile_id)
    ), earned_before as (
      select coalesce(j.approved_for_profile_id, j.assignee_profile_id) as recipient_id,
        coalesce(sum(coalesce(j.approved_fee, j.fee)), 0)::bigint as total
      from public.jobs j where j.status = 'Finished' and j.finished_at < v_start
      group by coalesce(j.approved_for_profile_id, j.assignee_profile_id)
    ), paid as (
      select r.recipient_profile_id as recipient_id,
        coalesce(sum(case when r.paid_at >= v_start and r.paid_at < v_end then r.amount else 0 end)
          - sum(case when r.voided_at >= v_start and r.voided_at < v_end then r.amount else 0 end), 0)::bigint as total
      from public.freelancer_payment_records r
      where (r.paid_at >= v_start and r.paid_at < v_end)
        or (r.voided_at >= v_start and r.voided_at < v_end)
      group by r.recipient_profile_id
    ), paid_before as (
      select r.recipient_profile_id as recipient_id,
        coalesce(sum(case when r.paid_at < v_start then r.amount else 0 end)
          - sum(case when r.voided_at < v_start then r.amount else 0 end), 0)::bigint as total
      from public.freelancer_payment_records r
      where r.paid_at < v_start or r.voided_at < v_start
      group by r.recipient_profile_id
    )
    select rec.id, rec.name,
      coalesce(eb.total, 0) - coalesce(pb.total, 0),
      coalesce(e.total, 0), coalesce(pd.total, 0),
      coalesce(eb.total, 0) - coalesce(pb.total, 0) + coalesce(e.total, 0) - coalesce(pd.total, 0),
      coalesce(e.job_count, 0)
    from recipients rec
    left join earned e on e.recipient_id = rec.id
    left join earned_before eb on eb.recipient_id = rec.id
    left join paid pd on pd.recipient_id = rec.id
    left join paid_before pb on pb.recipient_id = rec.id
    order by rec.name, rec.id;
end $$;

create or replace function public.finance_monthly_jobs(
  p_month date, p_profile uuid, p_limit int default 50, p_offset int default 0
)
returns table(
  job_id text, team_name text, job_type public.job_type, finished_at timestamptz,
  earned_fee bigint, paid_amount bigint, due_amount bigint, total_rows bigint
)
language plpgsql stable security definer set search_path = public as $$
declare v_month date; v_start timestamptz; v_end timestamptz;
begin
  if not (public.is_finance() or public.is_super_admin()) then
    raise exception 'FORBIDDEN: hanya Finance yang dapat melihat rincian fee bulanan';
  end if;
  if p_month is null or p_profile is null or p_limit < 1 or p_limit > 100
    or p_offset < 0 or p_offset > 100000 then
    raise exception 'Parameter rincian fee bulanan tidak valid';
  end if;
  v_month := date_trunc('month', p_month)::date;
  v_start := v_month::timestamp at time zone 'Asia/Jakarta';
  v_end := (v_month + interval '1 month')::timestamp at time zone 'Asia/Jakarta';
  return query
    with balances as (
      select j.id, j.tim, j.jenis, j.finished_at,
        coalesce(j.approved_fee, j.fee)::bigint as earned,
        coalesce(sum(a.amount) filter (where r.status = 'posted'), 0)::bigint as paid
      from public.jobs j
      left join public.freelancer_payment_allocations a on a.job_id = j.id
      left join public.freelancer_payment_records r on r.id = a.payment_record_id
      where j.status = 'Finished' and j.finished_at >= v_start and j.finished_at < v_end
        and coalesce(j.approved_for_profile_id, j.assignee_profile_id) = p_profile
      group by j.id
    )
    select b.id, b.tim, b.jenis, b.finished_at, b.earned, b.paid,
      (b.earned - b.paid)::bigint, count(*) over()::bigint
    from balances b
    order by b.finished_at, b.id
    limit p_limit offset p_offset;
end $$;

create or replace function public.finance_unpaid_jobs(
  p_profile uuid, p_limit int default 50, p_offset int default 0
)
returns table(
  job_id text, team_name text, job_type public.job_type, finished_at timestamptz,
  earned_fee bigint, paid_amount bigint, due_amount bigint, total_rows bigint
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.is_finance() or public.is_super_admin()) then
    raise exception 'FORBIDDEN: hanya Finance yang dapat melihat rincian pembayaran';
  end if;
  if p_profile is null or p_limit < 1 or p_limit > 100 or p_offset < 0 or p_offset > 100000 then
    raise exception 'Parameter halaman rincian pembayaran tidak valid';
  end if;
  return query
    with balances as (
      select j.id, j.tim, j.jenis, j.finished_at,
        coalesce(j.approved_fee, j.fee)::bigint as earned,
        coalesce(sum(a.amount) filter (where r.status = 'posted'), 0)::bigint as paid
      from public.jobs j
      left join public.freelancer_payment_allocations a on a.job_id = j.id
      left join public.freelancer_payment_records r on r.id = a.payment_record_id
      where j.status = 'Finished'
        and coalesce(j.approved_for_profile_id, j.assignee_profile_id) = p_profile
      group by j.id
    ), due as (
      select b.*, (b.earned - b.paid)::bigint as remaining
      from balances b where b.earned > b.paid
    )
    select d.id, d.tim, d.jenis, d.finished_at, d.earned, d.paid, d.remaining,
      count(*) over()::bigint
    from due d
    order by d.finished_at, d.id
    limit p_limit offset p_offset;
end $$;

create or replace function public.finance_payment_history(
  p_month date, p_limit int default 50, p_offset int default 0
)
returns table(
  payment_id uuid, recipient_profile_id uuid, recipient_name text,
  bank_name text, account_number_last4 text, account_holder text, amount bigint,
  paid_at timestamptz, bank_reference text, note text, proof_path text, status text,
  recorded_by text, recorded_at timestamptz, voided_by text, voided_at timestamptz,
  void_reason text, allocations jsonb, total_rows bigint
)
language plpgsql stable security definer set search_path = public as $$
declare v_month date; v_start timestamptz; v_end timestamptz;
begin
  if not (public.is_finance() or public.is_super_admin()) then
    raise exception 'FORBIDDEN: hanya Finance yang dapat melihat histori pembayaran';
  end if;
  if p_month is null or p_limit < 1 or p_limit > 100 or p_offset < 0 or p_offset > 100000 then
    raise exception 'Parameter halaman histori pembayaran tidak valid';
  end if;
  v_month := date_trunc('month', p_month)::date;
  v_start := v_month::timestamp at time zone 'Asia/Jakarta';
  v_end := (v_month + interval '1 month')::timestamp at time zone 'Asia/Jakarta';
  return query
    select r.id, r.recipient_profile_id, r.recipient_label,
      r.snapshot_bank_name, right(r.snapshot_account_number, 4), r.snapshot_account_holder,
      r.amount, r.paid_at,
      r.bank_reference, r.note, r.proof_path, r.status,
      coalesce(actor.name, 'akun nonaktif'), r.recorded_at,
      voider.name, r.voided_at, r.void_reason,
      coalesce((
        select jsonb_agg(jsonb_build_object(
          'job_id', a.job_id, 'team_name', j.tim, 'amount', a.amount
        ) order by j.finished_at, a.job_id)
        from public.freelancer_payment_allocations a
        join public.jobs j on j.id = a.job_id
        where a.payment_record_id = r.id
      ), '[]'::jsonb), count(*) over()::bigint
    from public.freelancer_payment_records r
    left join public.profiles actor on actor.id = r.recorded_by_profile_id
    left join public.profiles voider on voider.id = r.voided_by_profile_id
    where r.paid_at >= v_start and r.paid_at < v_end
    order by r.paid_at desc, r.recorded_at desc, r.id
    limit p_limit offset p_offset;
end $$;

create or replace function public.finance_payment_audit_log(
  p_month date, p_limit int default 100, p_offset int default 0
)
returns table(
  event_id uuid, payment_record_id uuid, target_profile_id uuid, target_name text,
  actor_name text, event_type text, details jsonb, created_at timestamptz, total_rows bigint
)
language plpgsql stable security definer set search_path = public as $$
declare v_month date; v_start timestamptz; v_end timestamptz;
begin
  if not (public.is_finance() or public.is_super_admin()) then
    raise exception 'FORBIDDEN: hanya Finance yang dapat melihat audit pembayaran';
  end if;
  if p_month is null or p_limit < 1 or p_limit > 200 or p_offset < 0 or p_offset > 100000 then
    raise exception 'Parameter halaman audit pembayaran tidak valid';
  end if;
  v_month := date_trunc('month', p_month)::date;
  v_start := v_month::timestamp at time zone 'Asia/Jakarta';
  v_end := (v_month + interval '1 month')::timestamp at time zone 'Asia/Jakarta';
  return query
    select e.id, e.payment_record_id, e.target_profile_id,
      coalesce(target.name, r.recipient_label, 'akun dihapus'),
      coalesce(actor.name, 'akun nonaktif'), e.event_type, e.details, e.created_at,
      count(*) over()::bigint
    from public.freelancer_payment_events e
    left join public.profiles target on target.id = e.target_profile_id
    left join public.freelancer_payment_records r on r.id = e.payment_record_id
    left join public.profiles actor on actor.id = e.actor_profile_id
    where e.created_at >= v_start and e.created_at < v_end
    order by e.created_at desc, e.id
    limit p_limit offset p_offset;
end $$;

create or replace function public.finance_freelancer_payment_settings()
returns table(
  profile_id uuid,
  profile_name text,
  is_active boolean,
  payout_frequency text,
  payout_method text,
  bank_name text,
  account_number text,
  account_holder text,
  updated_at timestamptz
)
language sql stable security definer set search_path = public as $$
  select p.id, p.name, p.is_active,
    coalesce(s.payout_frequency, 'per_job'), coalesce(s.payout_method, 'bank_transfer'),
    b.bank_name,
    case when b.account_number is null then null else '•••• ' || right(b.account_number, 4) end,
    b.account_holder, s.updated_at
  from public.profiles p
  left join public.freelancer_payment_settings s on s.profile_id = p.id
  left join public.freelancer_bank_accounts b on b.profile_id = p.id
  where (public.is_finance() or public.is_super_admin())
    and p.role = 'freelance' and p.registration_status = 'approved'
  order by p.name, p.id
$$;

create or replace function public.finance_freelancer_bank_account(p_profile uuid)
returns table(bank_name text, account_number text, account_holder text)
language plpgsql security definer set search_path = public as $$
begin
  if not (public.is_finance() or public.is_super_admin()) then
    raise exception 'FORBIDDEN: hanya Finance yang dapat melihat rekening pembayaran';
  end if;
  return query
    select b.bank_name, b.account_number, b.account_holder
    from public.freelancer_bank_accounts b join public.profiles p on p.id = b.profile_id
    where b.profile_id = p_profile and p.role = 'freelance'
      and (
        p.registration_status = 'approved'
        or exists (
          select 1 from public.jobs j
          where j.status = 'Finished'
            and coalesce(j.approved_for_profile_id, j.assignee_profile_id) = p.id
        )
        or exists (
          select 1 from public.freelancer_payment_records r where r.recipient_profile_id = p.id
        )
      );
  if found then
    insert into public.freelancer_payment_events(target_profile_id, actor_profile_id, event_type)
    values (p_profile, auth.uid(), 'bank_details_viewed');
  end if;
end $$;

create or replace function public.record_freelancer_payment(
  p_recipient uuid,
  p_paid_at timestamptz,
  p_bank_reference text,
  p_note text,
  p_proof_path text,
  p_allocations jsonb
) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  v_recipient public.profiles%rowtype;
  v_bank public.freelancer_bank_accounts%rowtype;
  v_actor uuid := auth.uid();
  v_payment_id uuid;
  v_item jsonb;
  v_job public.jobs%rowtype;
  v_job_id text;
  v_amount bigint;
  v_total bigint := 0;
  v_previous_paid bigint;
  v_job_fee bigint;
  v_allocations_count int;
  v_distinct_jobs int;
begin
  if not (public.is_finance() or public.is_super_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Hanya Finance yang dapat mencatat pembayaran.');
  end if;
  if p_paid_at is null or p_paid_at > now() + interval '5 minutes' then
    return jsonb_build_object('ok', false, 'error', 'Tanggal pembayaran tidak valid.');
  end if;
  if nullif(btrim(coalesce(p_bank_reference, '')), '') is null or char_length(btrim(p_bank_reference)) > 120 then
    return jsonb_build_object('ok', false, 'error', 'Nomor referensi transfer wajib diisi (maksimal 120 karakter).');
  end if;
  if char_length(coalesce(p_note, '')) > 1000 then
    return jsonb_build_object('ok', false, 'error', 'Catatan maksimal 1.000 karakter.');
  end if;
  if p_proof_path is null or split_part(p_proof_path, '/', 1) <> v_actor::text
    or not exists (
      select 1 from storage.objects o where o.bucket_id = 'finance-payment-proofs' and o.name = p_proof_path
    ) then
    return jsonb_build_object('ok', false, 'error', 'Bukti transfer belum diunggah dengan benar.');
  end if;
  if p_allocations is null or jsonb_typeof(p_allocations) is distinct from 'array' then
    return jsonb_build_object('ok', false, 'error', 'Pilih minimal satu job untuk alokasi pembayaran.');
  end if;
  v_allocations_count := jsonb_array_length(p_allocations);
  if v_allocations_count < 1 or v_allocations_count > 100 then
    return jsonb_build_object('ok', false, 'error', 'Satu transfer harus dialokasikan ke 1–100 job.');
  end if;
  select count(distinct value->>'job_id') into v_distinct_jobs
  from jsonb_array_elements(p_allocations);
  if v_distinct_jobs <> v_allocations_count then
    return jsonb_build_object('ok', false, 'error', 'Job yang sama tidak boleh dipilih lebih dari satu kali.');
  end if;
  for v_item in select value from jsonb_array_elements(p_allocations) loop
    v_job_id := nullif(v_item->>'job_id', '');
    if v_job_id is null or coalesce(v_item->>'amount', '') !~ '^[0-9]+$' then
      return jsonb_build_object('ok', false, 'error', 'Rincian alokasi tidak valid.');
    end if;
    v_amount := (v_item->>'amount')::bigint;
    if v_amount <= 0 then
      return jsonb_build_object('ok', false, 'error', 'Nilai alokasi harus lebih dari nol.');
    end if;
    v_total := v_total + v_amount;
  end loop;
  if v_total <= 0 then
    return jsonb_build_object('ok', false, 'error', 'Nilai transfer harus lebih dari nol.');
  end if;

  select * into v_recipient from public.profiles where id = p_recipient for share;
  if not found or v_recipient.role <> 'freelance' then
    return jsonb_build_object('ok', false, 'error', 'Freelancer penerima tidak ditemukan.');
  end if;
  select * into v_bank from public.freelancer_bank_accounts where profile_id = p_recipient for share;

  -- Lock jobs in a stable order so concurrent Finance entries cannot overpay a job.
  perform j.id
  from public.jobs j
  where j.id in (select value->>'job_id' from jsonb_array_elements(p_allocations))
  order by j.id
  for update of j;

  for v_item in select value from jsonb_array_elements(p_allocations) loop
    v_job_id := v_item->>'job_id';
    v_amount := (v_item->>'amount')::bigint;
    select * into v_job from public.jobs where id = v_job_id;
    if not found or v_job.status <> 'Finished'
      or coalesce(v_job.approved_for_profile_id, v_job.assignee_profile_id) is distinct from p_recipient then
      return jsonb_build_object('ok', false, 'error', 'Semua alokasi harus mengarah ke job Finished milik freelancer tersebut.');
    end if;
    v_job_fee := coalesce(v_job.approved_fee, v_job.fee);
    select coalesce(sum(a.amount), 0) into v_previous_paid
    from public.freelancer_payment_allocations a
    join public.freelancer_payment_records r on r.id = a.payment_record_id
    where a.job_id = v_job_id and r.status = 'posted';
    if v_previous_paid + v_amount > v_job_fee then
      return jsonb_build_object('ok', false, 'error', 'Alokasi melebihi sisa fee job ' || v_job_id || '.');
    end if;
  end loop;

  insert into public.freelancer_payment_records(
    recipient_profile_id, recipient_label, snapshot_bank_name, snapshot_account_number,
    snapshot_account_holder, amount, paid_at, bank_reference, proof_path, note, recorded_by_profile_id
  ) values (
    p_recipient, v_recipient.name, v_bank.bank_name, v_bank.account_number, v_bank.account_holder,
    v_total, p_paid_at, btrim(p_bank_reference), p_proof_path, btrim(coalesce(p_note, '')), v_actor
  ) returning id into v_payment_id;

  insert into public.freelancer_payment_allocations(payment_record_id, job_id, amount)
  select v_payment_id, x.job_id, x.amount
  from jsonb_to_recordset(p_allocations) as x(job_id text, amount bigint);

  insert into public.freelancer_payment_events(payment_record_id, target_profile_id, actor_profile_id, event_type, details)
  values (v_payment_id, p_recipient, v_actor, 'payment_recorded',
    jsonb_build_object('amount', v_total, 'bank_reference', btrim(p_bank_reference), 'allocation_count', v_allocations_count));
  return jsonb_build_object('ok', true, 'payment_id', v_payment_id, 'amount', v_total);
exception when unique_violation then
  return jsonb_build_object('ok', false, 'error', 'Nomor referensi transfer ini sudah pernah dicatat untuk freelancer tersebut.');
end $$;

create or replace function public.void_freelancer_payment(p_payment uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare v_record public.freelancer_payment_records%rowtype;
begin
  if not (public.is_finance() or public.is_super_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Hanya Finance yang dapat membatalkan pencatatan pembayaran.');
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null or char_length(btrim(p_reason)) > 1000 then
    return jsonb_build_object('ok', false, 'error', 'Alasan pembatalan wajib diisi (maksimal 1.000 karakter).');
  end if;
  select * into v_record from public.freelancer_payment_records where id = p_payment for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Pembayaran tidak ditemukan.'); end if;
  if v_record.status <> 'posted' then return jsonb_build_object('ok', false, 'error', 'Pembayaran ini sudah dibatalkan.'); end if;
  update public.freelancer_payment_records set status = 'voided', voided_by_profile_id = auth.uid(),
    voided_at = now(), void_reason = btrim(p_reason) where id = p_payment;
  insert into public.freelancer_payment_events(payment_record_id, target_profile_id, actor_profile_id, event_type, details)
  values (p_payment, v_record.recipient_profile_id, auth.uid(), 'payment_voided',
    jsonb_build_object('reason', btrim(p_reason), 'amount', v_record.amount));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.finance_log_payment_proof_view(p_payment uuid)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare v_record public.freelancer_payment_records%rowtype;
begin
  if not (public.is_finance() or public.is_super_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Hanya Finance yang dapat membuka bukti pembayaran.');
  end if;
  select * into v_record from public.freelancer_payment_records where id = p_payment;
  if not found then return jsonb_build_object('ok', false, 'error', 'Pembayaran tidak ditemukan.'); end if;
  insert into public.freelancer_payment_events(payment_record_id, target_profile_id, actor_profile_id, event_type)
  values (p_payment, v_record.recipient_profile_id, auth.uid(), 'payment_proof_viewed');
  return jsonb_build_object('ok', true, 'proof_path', v_record.proof_path);
end $$;

revoke all on function public.finance_monthly_payment_report(date) from public, anon;
revoke all on function public.finance_monthly_jobs(date, uuid, int, int) from public, anon;
revoke all on function public.finance_unpaid_jobs(uuid, int, int) from public, anon;
revoke all on function public.finance_payment_history(date, int, int) from public, anon;
revoke all on function public.finance_payment_audit_log(date, int, int) from public, anon;
revoke all on function public.finance_freelancer_payment_settings() from public, anon;
revoke all on function public.finance_freelancer_bank_account(uuid) from public, anon;
revoke all on function public.record_freelancer_payment(uuid, timestamptz, text, text, text, jsonb) from public, anon;
revoke all on function public.void_freelancer_payment(uuid, text) from public, anon;
revoke all on function public.finance_log_payment_proof_view(uuid) from public, anon;
revoke all on function public.finance_payment_proof_is_linked(text) from public, anon;
revoke all on function public.finance_payment_proof_is_audited(text) from public, anon;
grant execute on function public.finance_monthly_payment_report(date) to authenticated, service_role;
grant execute on function public.finance_monthly_jobs(date, uuid, int, int) to authenticated, service_role;
grant execute on function public.finance_unpaid_jobs(uuid, int, int) to authenticated, service_role;
grant execute on function public.finance_payment_history(date, int, int) to authenticated, service_role;
grant execute on function public.finance_payment_audit_log(date, int, int) to authenticated, service_role;
grant execute on function public.finance_freelancer_payment_settings() to authenticated, service_role;
grant execute on function public.finance_freelancer_bank_account(uuid) to authenticated, service_role;
grant execute on function public.record_freelancer_payment(uuid, timestamptz, text, text, text, jsonb) to authenticated, service_role;
grant execute on function public.void_freelancer_payment(uuid, text) to authenticated, service_role;
grant execute on function public.finance_log_payment_proof_view(uuid) to authenticated, service_role;
grant execute on function public.finance_payment_proof_is_linked(text) to authenticated, service_role;
grant execute on function public.finance_payment_proof_is_audited(text) to authenticated, service_role;
revoke all on function public.log_freelancer_payment_schedule_change() from public, anon, authenticated;
revoke all on function public.guard_job_finished_at() from public, anon, authenticated;

-- Source migration: 20261017000020_freelancer_role_hardening.sql
-- Harden the freelancer lifecycle, presence, assignment, payout data and uploads.

-- New accounts start offline. A browser cannot keep a future heartbeat alive.
alter table public.profiles
  alter column last_seen set default (clock_timestamp() - interval '2 minutes');

create or replace function public.is_freelance() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.is_active and p.role = 'freelance'
      and p.registration_status = 'approved'
  )
$$;

-- Profile updates are limited to editable presentation fields. Presence and
-- availability are updated through trusted functions using database time.
revoke update on public.profiles from public, anon, authenticated;
grant update (name, avatar_path) on public.profiles to authenticated;

create or replace function public.touch_freelancer_presence()
returns jsonb language plpgsql security definer set search_path = public, auth as $$
begin
  update public.profiles
  set last_seen = clock_timestamp()
  where id = auth.uid() and role = 'freelance'
    and is_active and registration_status = 'approved';
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Akun freelancer belum aktif');
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.set_freelancer_availability(p_status text)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
begin
  if p_status is null or p_status not in ('pending', 'ready', 'unavailable') then
    return jsonb_build_object('ok', false, 'error', 'Status kesiapan tidak valid');
  end if;
  update public.profiles
  set availability_status = p_status,
      availability_updated_at = clock_timestamp()
  where id = auth.uid() and role = 'freelance'
    and is_active and registration_status = 'approved';
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Akun freelancer belum aktif');
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.set_freelancer_offline()
returns jsonb language plpgsql security definer set search_path = public, auth as $$
begin
  update public.profiles
  set availability_status = 'unavailable',
      availability_updated_at = clock_timestamp(),
      last_seen = clock_timestamp() - interval '2 minutes'
  where id = auth.uid() and role = 'freelance'
    and is_active and registration_status = 'approved';
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Akun freelancer belum aktif');
  end if;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.touch_freelancer_presence() from public, anon;
grant execute on function public.touch_freelancer_presence() to authenticated, service_role;
revoke all on function public.set_freelancer_availability(text) from public, anon;
grant execute on function public.set_freelancer_availability(text) to authenticated, service_role;
revoke all on function public.set_freelancer_offline() from public, anon;
grant execute on function public.set_freelancer_offline() to authenticated, service_role;

-- Only the freelancer, Finance and Super Admin need bank account data.
-- Finance and Super Admin access it through the audited RPCs in migration 19.
drop policy if exists freelancer_bank_accounts_admin_read on public.freelancer_bank_accounts;

-- Require email verification before an application appears in the review queue
-- or an Admin/Super Admin can approve it.
create or replace function public.pending_freelancer_registrations()
returns table(
  profile_id uuid,
  name text,
  email text,
  whatsapp text,
  requested_at timestamptz
)
language sql stable security definer set search_path = public, auth as $$
  select p.id, p.name, u.email, c.whatsapp, p.registration_requested_at
  from public.profiles p
  join auth.users u on u.id = p.id
  left join public.profile_contacts c on c.profile_id = p.id
  where p.role = 'freelance'
    and p.registration_status = 'pending'
    and not p.is_active
    and u.email_confirmed_at is not null
    and exists (
      select 1 from public.profiles reviewer
      where reviewer.id = auth.uid() and reviewer.is_active
        and reviewer.role in ('admin', 'super_admin')
    )
  order by p.registration_requested_at asc, p.name asc
$$;

create or replace function public.review_freelancer_registration(
  p_target uuid,
  p_approve boolean,
  p_actor uuid,
  p_reason text
) returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare
  v_target public.profiles%rowtype;
  v_actor_label text;
  v_new_status text;
begin
  if not public.is_service_role() then
    return jsonb_build_object('ok', false, 'error', 'Hanya server tepercaya');
  end if;
  if p_approve is null then
    return jsonb_build_object('ok', false, 'error', 'Keputusan pendaftaran tidak valid');
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Catatan keputusan wajib diisi');
  end if;

  select * into v_target from public.profiles where id = p_target for update;
  if not found or v_target.role <> 'freelance'
     or v_target.registration_status <> 'pending' or v_target.is_active then
    return jsonb_build_object('ok', false, 'error', 'Pendaftaran tidak lagi menunggu keputusan');
  end if;
  if not exists (
    select 1 from auth.users u where u.id = p_target and u.email_confirmed_at is not null
  ) then
    return jsonb_build_object('ok', false, 'error', 'Email harus diverifikasi sebelum pendaftaran ditinjau');
  end if;

  select name into v_actor_label from public.profiles
  where id = p_actor and is_active and role in ('admin', 'super_admin');
  if v_actor_label is null then
    return jsonb_build_object('ok', false, 'error', 'Admin yang meninjau tidak valid');
  end if;

  v_new_status := case when p_approve then 'approved' else 'rejected' end;
  update public.profiles set
    registration_status = v_new_status,
    is_active = p_approve,
    registration_reviewed_at = now(),
    registration_reviewed_by_profile_id = p_actor,
    registration_review_reason = trim(p_reason)
  where id = p_target;

  insert into public.admin_audit_events(
    event_type, target_profile_id, target_label, actor_profile_id, actor_label,
    before_data, after_data, reason
  ) values (
    case when p_approve then 'freelancer_registration_approved' else 'freelancer_registration_rejected' end,
    p_target, v_target.name, p_actor, v_actor_label,
    jsonb_build_object('registration_status', 'pending', 'is_active', false),
    jsonb_build_object('registration_status', v_new_status, 'is_active', p_approve),
    trim(p_reason)
  );
  return jsonb_build_object('ok', true, 'registration_status', v_new_status);
end $$;

-- Assignment is guarded by current approval, bounded presence, explicit
-- readiness and capacity in the database, even if the UI is bypassed.
create or replace function public.assign_job(
  p_job text, p_target uuid, p_reason text, p_expected_rev int
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_job public.jobs%rowtype;
  v_t public.profiles%rowtype;
  v_active int;
  v_max int;
  v_now timestamptz := clock_timestamp();
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'Hanya Admin'); end if;
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.status in ('ACC','Finished','Dibatalkan') then return jsonb_build_object('ok', false, 'error', 'Penerima job sudah dikunci'); end if;
  if v_job.status in ('Preview','MintaACC') then return jsonb_build_object('ok', false, 'error', 'Tinjau preview sebelum mengalihkan job'); end if;

  select coalesce(max(max_active_jobs), 4) into v_max from public.app_settings where id = 1;
  select * into v_t from public.profiles where id = p_target;
  if not found or v_t.role <> 'freelance' or not v_t.is_active
     or v_t.registration_status <> 'approved' then
    return jsonb_build_object('ok', false, 'error', 'Target bukan freelancer aktif yang disetujui');
  end if;

  perform pg_advisory_xact_lock(hashtext('assign:' || p_target::text)::bigint);
  if v_t.last_seen < v_now - interval '90 seconds' or v_t.last_seen > v_now then
    return jsonb_build_object('ok', false, 'error', 'Freelance offline');
  end if;
  if v_t.availability_status <> 'ready' then
    return jsonb_build_object('ok', false, 'error', 'Freelance belum siap menerima job');
  end if;

  select count(*) into v_active from public.jobs
    where assignee_profile_id = p_target
      and status in ('Antre','Dikerjakan','Preview','ACC','MintaACC','Revisi')
      and id <> p_job;
  if v_active >= v_max then
    return jsonb_build_object('ok', false, 'error', 'Freelance penuh (batas ' || v_max || ' job aktif)');
  end if;
  if v_job.assignee_profile_id is not null and v_job.assignee_profile_id <> p_target
     and v_job.status in ('Dikerjakan','Revisi') and nullif(trim(coalesce(p_reason,'')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Pengalihan Dikerjakan/Revisi wajib alasan');
  end if;

  if v_job.assignee_profile_id is null then
    update public.jobs set assignee_profile_id = p_target, status = 'Antre',
      antre_since = v_now, revision = revision + 1 where id = p_job;
    insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, reason)
    values (p_job, public.my_uid(), 'assign', v_job.status, 'Antre', nullif(trim(coalesce(p_reason,'')), ''));
  else
    update public.jobs set assignee_profile_id = p_target,
      antre_since = case when v_job.status = 'Antre' then v_now else antre_since end,
      revision = revision + 1 where id = p_job;
    insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, reason)
    values (p_job, public.my_uid(), 'reassign', v_job.status, v_job.status, nullif(trim(coalesce(p_reason,'')), ''));
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- Reservations bind the exact object path, role, uploader and byte count.
alter table public.job_upload_reservations
  add column if not exists object_path text,
  add column if not exists file_role text;

create unique index if not exists job_upload_reservations_object_path_uidx
  on public.job_upload_reservations(object_path) where object_path is not null;

revoke insert, update, delete on public.job_upload_reservations from public, anon, authenticated;
grant select on public.job_upload_reservations to authenticated;

drop function if exists public.reserve_upload(text, bigint);
create or replace function public.reserve_upload(
  p_job text,
  p_size bigint,
  p_file_name text,
  p_file_role text
) returns jsonb language plpgsql security definer set search_path = public, auth, storage as $$
declare
  v_job public.jobs%rowtype;
  v_total bigint;
  v_reservation uuid := gen_random_uuid();
  v_admin boolean := public.is_admin();
  v_extension text;
  v_safe_name text;
  v_object_path text;
  v_now timestamptz := clock_timestamp();
begin
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.status in ('ACC','Finished','Dibatalkan') then
    return jsonb_build_object('ok', false, 'error', 'Job terminal');
  end if;
  if p_size is null or p_size <= 0 or p_size > 1073741824 then
    return jsonb_build_object('ok', false, 'error', 'Maks 1 GiB per file');
  end if;
  if p_file_name is null or length(btrim(p_file_name)) not between 1 and 180 then
    return jsonb_build_object('ok', false, 'error', 'Nama file tidak valid');
  end if;
  if p_file_role is null then
    return jsonb_build_object('ok', false, 'error', 'Peran file tidak valid');
  end if;
  v_extension := lower(split_part(btrim(p_file_name), '.', array_length(string_to_array(btrim(p_file_name), '.'), 1)));
  if v_extension = 'jpg' then v_extension := 'jpeg'; end if;
  if v_extension not in ('pdf','cdr','png','jpeg','svg','docx','xlsx','pptx','ai','psd') then
    return jsonb_build_object('ok', false, 'error', 'Format file tidak didukung');
  end if;

  if v_admin then
    if p_file_role is distinct from 'reference' then
      return jsonb_build_object('ok', false, 'error', 'Admin hanya dapat mengunggah file referensi');
    end if;
  else
    if not public.is_freelance() or v_job.assignee_profile_id is distinct from auth.uid() then
      return jsonb_build_object('ok', false, 'error', 'Bukan job milikmu');
    end if;
    if p_file_role = 'preview' then
      if v_job.status not in ('Dikerjakan','Revisi') or v_extension not in ('png','jpeg','svg') then
        return jsonb_build_object('ok', false, 'error', 'Preview harus berupa gambar saat job dikerjakan');
      end if;
    elsif p_file_role = 'source' then
      if v_job.status <> 'ACC' or v_extension <> 'cdr' then
        return jsonb_build_object('ok', false, 'error', 'File asli CDR hanya dapat dikirim setelah preview di-ACC');
      end if;
    else
      return jsonb_build_object('ok', false, 'error', 'Freelancer hanya dapat mengunggah preview atau file asli');
    end if;
  end if;

  v_safe_name := regexp_replace(btrim(p_file_name), '[^a-zA-Z0-9._-]+', '_', 'g');
  v_object_path := p_job || '/' || v_reservation::text || '-' || v_safe_name;
  perform pg_advisory_xact_lock(hashtext(p_job)::bigint);

  -- Expired reservations remain available for safe cleanup and are replaced
  -- with a state transition so orphan Storage objects cannot disappear from
  -- quota accounting when their reservation expires.
  update public.job_upload_reservations
  set state = 'expired'
  where job_id = p_job and state = 'active' and expires_at <= v_now;

  select
    coalesce((
      select sum(f.size_bytes) from public.job_files f
      where f.job_id = p_job and f.expired_at is null
    ), 0)
    + coalesce((
      select sum(r.size_bytes) from public.job_upload_reservations r
      where r.job_id = p_job and r.state = 'active' and r.expires_at > v_now
    ), 0)
    + coalesce((
      select sum(case
        when (o.metadata ->> 'size') ~ '^[0-9]{1,10}$'
         and (o.metadata ->> 'size')::bigint between 1 and 1073741824
          then (o.metadata ->> 'size')::bigint
        else 1073741824
      end)
      from storage.objects o
      where o.bucket_id = 'job-files'
        and split_part(o.name, '/', 1) = p_job
        and not exists (
          select 1 from public.job_files f
          where f.path = o.name and f.expired_at is null
        )
        and not exists (
          select 1 from public.job_upload_reservations r
          where r.object_path = o.name and r.state = 'active' and r.expires_at > v_now
        )
    ), 0)
  into v_total;

  if v_total + p_size > 10737418240 then
    return jsonb_build_object('ok', false, 'error', 'Total melebihi 10 GiB per job');
  end if;

  insert into public.job_upload_reservations(
    id, job_id, profile_id, size_bytes, state, expires_at, object_path, file_role
  ) values (
    v_reservation, p_job, auth.uid(), p_size, 'active', v_now + interval '1 hour', v_object_path, p_file_role
  );
  return jsonb_build_object('ok', true, 'reservation_id', v_reservation, 'object_path', v_object_path);
end $$;

revoke all on function public.reserve_upload(text, bigint, text, text) from public, anon;
grant execute on function public.reserve_upload(text, bigint, text, text) to authenticated, service_role;

-- The Storage INSERT policy can only accept a matching server reservation and
-- actual object size. The same binding is checked again before metadata insert.
create or replace function public.can_upload_job_file_object(p_name text, p_metadata jsonb)
returns boolean language plpgsql security definer set search_path = public, auth, storage as $$
declare
  v_size_text text;
  v_size bigint;
  v_res public.job_upload_reservations%rowtype;
  v_job public.jobs%rowtype;
begin
  if auth.uid() is null or p_name is null or jsonb_typeof(p_metadata) <> 'object' then return false; end if;
  v_size_text := p_metadata ->> 'size';
  if v_size_text is null or length(v_size_text) > 10 or v_size_text !~ '^[0-9]+$' then return false; end if;
  v_size := v_size_text::bigint;
  if v_size <= 0 or v_size > 1073741824 then return false; end if;

  select * into v_res from public.job_upload_reservations r
  where r.object_path = p_name
    and r.job_id = split_part(p_name, '/', 1)
    and r.profile_id = auth.uid()
    and r.size_bytes = v_size
    and r.state = 'active'
    and r.expires_at > clock_timestamp();
  if not found then return false; end if;
  select * into v_job from public.jobs j where j.id = v_res.job_id;
  if not found then return false; end if;

  if public.is_admin() then
    return v_res.file_role = 'reference'
      and v_job.status not in ('Finished','Dibatalkan');
  end if;
  if not public.is_freelance() or v_job.assignee_profile_id is distinct from auth.uid() then return false; end if;
  if v_res.file_role = 'preview' then
    return v_job.status in ('Dikerjakan','Revisi');
  elsif v_res.file_role = 'source' then
    return v_job.status = 'ACC';
  end if;
  return false;
end $$;

revoke all on function public.can_upload_job_file_object(text, jsonb) from public, anon;
grant execute on function public.can_upload_job_file_object(text, jsonb) to authenticated;

drop policy if exists sto_admin_write on storage.objects;
drop policy if exists sto_free_write on storage.objects;
drop policy if exists sto_job_upload_reserved on storage.objects;
create policy sto_job_upload_reserved on storage.objects for insert to authenticated
  with check (
    bucket_id = 'job-files'
    and public.can_upload_job_file_object(name, metadata)
  );

drop policy if exists sto_free_delete_uncommitted on storage.objects;
create policy sto_free_delete_uncommitted on storage.objects for delete to authenticated
  using (
    bucket_id = 'job-files'
    and exists (
      select 1 from public.job_upload_reservations r
      where r.object_path = name and r.profile_id = auth.uid()
        and r.job_id = split_part(name, '/', 1)
        and r.state in ('active','released','expired')
    )
    and not exists (select 1 from public.job_files f where f.path = name)
  );

-- Legacy reservations established their uploader identity already. Preserve
-- it for existing files, then refuse unreserved metadata writes from clients.
drop trigger if exists trg_job_files_guard on public.job_files;
update public.job_files f
set uploaded_by_profile_id = r.profile_id
from public.job_upload_reservations r
where f.reservation_id = r.id and f.uploaded_by_profile_id is null;

create or replace function public.guard_job_file() returns trigger
language plpgsql security definer set search_path = public, auth, storage as $$
declare
  v_locked boolean;
  v_res public.job_upload_reservations%rowtype;
  v_storage_size bigint;
  v_storage_size_text text;
begin
  if TG_OP = 'DELETE' then
    if public.is_service_role() then return OLD; end if;
    select exists (select 1 from public.job_submission_files b where b.job_file_id = OLD.id) into v_locked;
    if v_locked then raise exception 'FILE_LOCKED: file terikat submission'; end if;
    return OLD;
  end if;

  if TG_OP = 'INSERT' then
    if public.is_service_role() then return NEW; end if;
    if auth.uid() is null then raise exception 'FORBIDDEN: sesi pengguna tidak valid'; end if;
    perform pg_advisory_xact_lock(hashtext(NEW.job_id)::bigint);

    select * into v_res from public.job_upload_reservations r
    where r.id = NEW.reservation_id and r.job_id = NEW.job_id
      and r.profile_id = auth.uid() and r.object_path = NEW.path
      and r.file_role = NEW.file_role and r.size_bytes = NEW.size_bytes
      and r.state = 'active' and r.expires_at > clock_timestamp()
    for update;
    if not found then raise exception 'FORBIDDEN: reservation unggahan tidak valid'; end if;

    select o.metadata ->> 'size' into v_storage_size_text
    from storage.objects o
    where o.bucket_id = 'job-files' and o.name = NEW.path;
    if not found or v_storage_size_text is null or length(v_storage_size_text) > 10
       or v_storage_size_text !~ '^[0-9]+$' then
      raise exception 'UPLOAD_OBJECT_MISSING: objek unggahan tidak ditemukan';
    end if;
    v_storage_size := v_storage_size_text::bigint;
    if v_storage_size <> NEW.size_bytes then
      raise exception 'UPLOAD_SIZE_MISMATCH: ukuran objek tidak cocok dengan metadata';
    end if;

    NEW.uploaded_by_profile_id := auth.uid();
    update public.job_upload_reservations set state = 'committed' where id = v_res.id;
    return NEW;
  end if;

  if NEW.expired_at is distinct from OLD.expired_at and not public.is_service_role() then
    raise exception 'FORBIDDEN: expired_at hanya oleh retensi';
  end if;
  if public.is_service_role() then return NEW; end if;
  select exists (select 1 from public.job_submission_files b where b.job_file_id = NEW.id) into v_locked;
  if v_locked then raise exception 'FILE_LOCKED: file terikat submission'; end if;
  return NEW;
end $$;

create trigger trg_job_files_guard
  before insert or update or delete on public.job_files
  for each row execute function public.guard_job_file();

notify pgrst, 'reload schema';

-- Source migration: 20261017000021_assignment_presence_lock.sql
-- Serialize assignment with availability/heartbeat updates on the freelancer.
create or replace function public.assign_job(
  p_job text, p_target uuid, p_reason text, p_expected_rev int
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_job public.jobs%rowtype;
  v_t public.profiles%rowtype;
  v_active int;
  v_max int;
  v_now timestamptz := clock_timestamp();
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'Hanya Admin'); end if;
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.status in ('ACC','Finished','Dibatalkan') then return jsonb_build_object('ok', false, 'error', 'Penerima job sudah dikunci'); end if;
  if v_job.status in ('Preview','MintaACC') then return jsonb_build_object('ok', false, 'error', 'Tinjau preview sebelum mengalihkan job'); end if;

  select coalesce(max(max_active_jobs), 4) into v_max from public.app_settings where id = 1;
  select * into v_t from public.profiles where id = p_target for update;
  if not found or v_t.role <> 'freelance' or not v_t.is_active
     or v_t.registration_status <> 'approved' then
    return jsonb_build_object('ok', false, 'error', 'Target bukan freelancer aktif yang disetujui');
  end if;

  perform pg_advisory_xact_lock(hashtext('assign:' || p_target::text)::bigint);
  v_now := clock_timestamp();
  if v_t.last_seen < v_now - interval '90 seconds' or v_t.last_seen > v_now then
    return jsonb_build_object('ok', false, 'error', 'Freelance offline');
  end if;
  if v_t.availability_status <> 'ready' then
    return jsonb_build_object('ok', false, 'error', 'Freelance belum siap menerima job');
  end if;

  select count(*) into v_active from public.jobs
    where assignee_profile_id = p_target
      and status in ('Antre','Dikerjakan','Preview','ACC','MintaACC','Revisi')
      and id <> p_job;
  if v_active >= v_max then
    return jsonb_build_object('ok', false, 'error', 'Freelance penuh (batas ' || v_max || ' job aktif)');
  end if;
  if v_job.assignee_profile_id is not null and v_job.assignee_profile_id <> p_target
     and v_job.status in ('Dikerjakan','Revisi') and nullif(trim(coalesce(p_reason,'')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Pengalihan Dikerjakan/Revisi wajib alasan');
  end if;

  if v_job.assignee_profile_id is null then
    update public.jobs set assignee_profile_id = p_target, status = 'Antre',
      antre_since = v_now, revision = revision + 1 where id = p_job;
    insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, reason)
    values (p_job, public.my_uid(), 'assign', v_job.status, 'Antre', nullif(trim(coalesce(p_reason,'')), ''));
  else
    update public.jobs set assignee_profile_id = p_target,
      antre_since = case when v_job.status = 'Antre' then v_now else antre_since end,
      revision = revision + 1 where id = p_job;
    insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, reason)
    values (p_job, public.my_uid(), 'reassign', v_job.status, v_job.status, nullif(trim(coalesce(p_reason,'')), ''));
  end if;
  return jsonb_build_object('ok', true);
end $$;

notify pgrst, 'reload schema';

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

-- Preserve a source migration privilege rule.
grant usage on schema public to anon, authenticated;

-- Preserve a source migration privilege rule.
grant select, insert, update, delete on all tables in schema public to authenticated;

-- Preserve a source migration privilege rule.
grant usage, select on all sequences in schema public to authenticated;

-- Preserve a source migration privilege rule.
grant all privileges on all tables in schema public to service_role;

-- Preserve a source migration privilege rule.
grant usage, select on all sequences in schema public to service_role;

-- Preserve a source migration privilege rule.
grant execute on all functions in schema public to service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.manage_profile_access(uuid, text, boolean, text) from public, anon;

-- Preserve a source migration privilege rule.
grant execute on function public.manage_profile_access(uuid, text, boolean, text) to authenticated, service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.finance_acc_recipients() from public, anon;

-- Preserve a source migration privilege rule.
grant execute on function public.finance_acc_recipients() to authenticated;

-- Preserve a source migration privilege rule.
revoke all on function public.finance_acc_approval_times() from public, anon;

-- Preserve a source migration privilege rule.
grant execute on function public.finance_acc_approval_times() to authenticated;

-- Preserve a source migration privilege rule.
revoke all on function public.promote_super_admin(uuid, text, text) from public, anon, authenticated;

-- Preserve a source migration privilege rule.
grant execute on function public.promote_super_admin(uuid, text, text) to service_role;

-- Preserve a source migration privilege rule.
revoke all on public.admin_audit_events from public, anon;

-- Preserve a source migration privilege rule.
revoke insert, update, delete on public.admin_audit_events from authenticated;

-- Preserve a source migration privilege rule.
grant select on public.admin_audit_events to authenticated;

-- Preserve a source migration privilege rule.
grant all on public.admin_audit_events to service_role;

-- Preserve a source migration privilege rule.
revoke update on public.app_settings from public, anon, authenticated;

-- Preserve a source migration privilege rule.
grant select on public.app_settings to authenticated;

-- Preserve a source migration privilege rule.
revoke all on function public.super_admin_account_directory() from public, anon;

-- Preserve a source migration privilege rule.
grant execute on function public.super_admin_account_directory() to authenticated, service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.super_admin_audit_log() from public, anon;

-- Preserve a source migration privilege rule.
grant execute on function public.super_admin_audit_log() to authenticated, service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.update_app_settings(integer, integer, text) from public, anon;

-- Preserve a source migration privilege rule.
grant execute on function public.update_app_settings(integer, integer, text) to authenticated, service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.set_invited_account_role(uuid, text, uuid, text) from public, anon, authenticated;

-- Preserve a source migration privilege rule.
grant execute on function public.set_invited_account_role(uuid, text, uuid, text) to service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.record_super_admin_user_action(uuid, uuid, text, text) from public, anon, authenticated;

-- Preserve a source migration privilege rule.
grant execute on function public.record_super_admin_user_action(uuid, uuid, text, text) to service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.manage_profile_access(uuid, text, boolean, text) from public, anon;

-- Preserve a source migration privilege rule.
grant execute on function public.manage_profile_access(uuid, text, boolean, text) to authenticated, service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.promote_super_admin(uuid, text, text) from public, anon, authenticated;

-- Preserve a source migration privilege rule.
grant execute on function public.promote_super_admin(uuid, text, text) to service_role;

-- Preserve a source migration privilege rule.
revoke all on public.profile_contacts from public, anon, authenticated;

-- Preserve a source migration privilege rule.
grant select on public.profile_contacts to authenticated;

-- Preserve a source migration privilege rule.
revoke all on function public.pending_freelancer_registrations() from public, anon;

-- Preserve a source migration privilege rule.
grant execute on function public.pending_freelancer_registrations() to authenticated, service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.review_freelancer_registration(uuid, boolean, uuid, text) from public, anon, authenticated;

-- Preserve a source migration privilege rule.
grant execute on function public.review_freelancer_registration(uuid, boolean, uuid, text) to service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.set_invited_account_role(uuid, text, uuid, text) from public, anon, authenticated;

-- Preserve a source migration privilege rule.
grant execute on function public.set_invited_account_role(uuid, text, uuid, text) to service_role;

-- Preserve a source migration privilege rule.
revoke all on public.freelancer_bank_accounts from public, anon, authenticated;

-- Preserve a source migration privilege rule.
grant select, insert, update on public.freelancer_bank_accounts to authenticated;

-- Preserve a source migration privilege rule.
revoke all on function public.submit_for_acc(text, uuid[], text, int) from public, anon, authenticated;

-- Preserve a source migration privilege rule.
revoke all on function public.submit_preview(text, uuid[], text, int) from public, anon;

-- Preserve a source migration privilege rule.
grant execute on function public.submit_preview(text, uuid[], text, int) to authenticated, service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.finish_job(text, int) from public, anon;

-- Preserve a source migration privilege rule.
grant execute on function public.finish_job(text, int) to authenticated, service_role;

-- Preserve a source migration privilege rule.
revoke all on public.freelancer_compensation from public, anon, authenticated;

-- Preserve a source migration privilege rule.
grant all on public.freelancer_compensation to service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.finance_freelancer_compensation() from public, anon;

-- Preserve a source migration privilege rule.
grant execute on function public.finance_freelancer_compensation() to authenticated, service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.set_freelancer_compensation(uuid, text, bigint) from public, anon;

-- Preserve a source migration privilege rule.
grant execute on function public.set_freelancer_compensation(uuid, text, bigint) to authenticated, service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.finance_freelancer_payment_settings() from public, anon;

-- Preserve a source migration privilege rule.
grant execute on function public.finance_freelancer_payment_settings() to authenticated, service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.set_freelancer_payment_schedule(uuid, text) from public, anon;

-- Preserve a source migration privilege rule.
grant execute on function public.set_freelancer_payment_schedule(uuid, text) to authenticated, service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.set_created_account_role(uuid, text, uuid, text) from public, anon, authenticated;

-- Preserve a source migration privilege rule.
grant execute on function public.set_created_account_role(uuid, text, uuid, text) to service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.update_managed_account(uuid, uuid, text, text, text, boolean, boolean, text) from public, anon, authenticated;

-- Preserve a source migration privilege rule.
grant execute on function public.update_managed_account(uuid, uuid, text, text, text, boolean, boolean, text) to service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.managed_account_directory() from public, anon;

-- Preserve a source migration privilege rule.
grant execute on function public.managed_account_directory() to authenticated, service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.record_managed_account_deletion(uuid, uuid, text, text, text) from public, anon, authenticated;

-- Preserve a source migration privilege rule.
grant execute on function public.record_managed_account_deletion(uuid, uuid, text, text, text) to service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.managed_account_directory() from public, anon;

-- Preserve a source migration privilege rule.
grant execute on function public.managed_account_directory() to authenticated, service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.finance_acc_recipients() from public, anon, authenticated;

-- Preserve a source migration privilege rule.
revoke all on function public.finance_acc_approval_times() from public, anon, authenticated;

-- Preserve a source migration privilege rule.
revoke all on public.freelancer_payment_records, public.freelancer_payment_allocations,
  public.freelancer_payment_events from public, anon, authenticated;

-- Preserve a source migration privilege rule.
grant all on public.freelancer_payment_records, public.freelancer_payment_allocations,
  public.freelancer_payment_events to service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.finance_payment_proof_is_audited(text) from public, anon;

-- Preserve a source migration privilege rule.
grant execute on function public.finance_payment_proof_is_audited(text) to authenticated, service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.finance_monthly_payment_report(date) from public, anon;

-- Preserve a source migration privilege rule.
revoke all on function public.finance_monthly_jobs(date, uuid, int, int) from public, anon;

-- Preserve a source migration privilege rule.
revoke all on function public.finance_unpaid_jobs(uuid, int, int) from public, anon;

-- Preserve a source migration privilege rule.
revoke all on function public.finance_payment_history(date, int, int) from public, anon;

-- Preserve a source migration privilege rule.
revoke all on function public.finance_payment_audit_log(date, int, int) from public, anon;

-- Preserve a source migration privilege rule.
revoke all on function public.finance_freelancer_payment_settings() from public, anon;

-- Preserve a source migration privilege rule.
revoke all on function public.finance_freelancer_bank_account(uuid) from public, anon;

-- Preserve a source migration privilege rule.
revoke all on function public.record_freelancer_payment(uuid, timestamptz, text, text, text, jsonb) from public, anon;

-- Preserve a source migration privilege rule.
revoke all on function public.void_freelancer_payment(uuid, text) from public, anon;

-- Preserve a source migration privilege rule.
revoke all on function public.finance_log_payment_proof_view(uuid) from public, anon;

-- Preserve a source migration privilege rule.
revoke all on function public.finance_payment_proof_is_linked(text) from public, anon;

-- Preserve a source migration privilege rule.
revoke all on function public.finance_payment_proof_is_audited(text) from public, anon;

-- Preserve a source migration privilege rule.
grant execute on function public.finance_monthly_payment_report(date) to authenticated, service_role;

-- Preserve a source migration privilege rule.
grant execute on function public.finance_monthly_jobs(date, uuid, int, int) to authenticated, service_role;

-- Preserve a source migration privilege rule.
grant execute on function public.finance_unpaid_jobs(uuid, int, int) to authenticated, service_role;

-- Preserve a source migration privilege rule.
grant execute on function public.finance_payment_history(date, int, int) to authenticated, service_role;

-- Preserve a source migration privilege rule.
grant execute on function public.finance_payment_audit_log(date, int, int) to authenticated, service_role;

-- Preserve a source migration privilege rule.
grant execute on function public.finance_freelancer_payment_settings() to authenticated, service_role;

-- Preserve a source migration privilege rule.
grant execute on function public.finance_freelancer_bank_account(uuid) to authenticated, service_role;

-- Preserve a source migration privilege rule.
grant execute on function public.record_freelancer_payment(uuid, timestamptz, text, text, text, jsonb) to authenticated, service_role;

-- Preserve a source migration privilege rule.
grant execute on function public.void_freelancer_payment(uuid, text) to authenticated, service_role;

-- Preserve a source migration privilege rule.
grant execute on function public.finance_log_payment_proof_view(uuid) to authenticated, service_role;

-- Preserve a source migration privilege rule.
grant execute on function public.finance_payment_proof_is_linked(text) to authenticated, service_role;

-- Preserve a source migration privilege rule.
grant execute on function public.finance_payment_proof_is_audited(text) to authenticated, service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.log_freelancer_payment_schedule_change() from public, anon, authenticated;

-- Preserve a source migration privilege rule.
revoke all on function public.guard_job_finished_at() from public, anon, authenticated;

-- Preserve a source migration privilege rule.
revoke update on public.profiles from public, anon, authenticated;

-- Preserve a source migration privilege rule.
grant update (name, avatar_path) on public.profiles to authenticated;

-- Preserve a source migration privilege rule.
revoke all on function public.touch_freelancer_presence() from public, anon;

-- Preserve a source migration privilege rule.
grant execute on function public.touch_freelancer_presence() to authenticated, service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.set_freelancer_availability(text) from public, anon;

-- Preserve a source migration privilege rule.
grant execute on function public.set_freelancer_availability(text) to authenticated, service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.set_freelancer_offline() from public, anon;

-- Preserve a source migration privilege rule.
grant execute on function public.set_freelancer_offline() to authenticated, service_role;

-- Preserve a source migration privilege rule.
revoke insert, update, delete on public.job_upload_reservations from public, anon, authenticated;

-- Preserve a source migration privilege rule.
grant select on public.job_upload_reservations to authenticated;

-- Preserve a source migration privilege rule.
revoke all on function public.reserve_upload(text, bigint, text, text) from public, anon;

-- Preserve a source migration privilege rule.
grant execute on function public.reserve_upload(text, bigint, text, text) to authenticated, service_role;

-- Preserve a source migration privilege rule.
revoke all on function public.can_upload_job_file_object(text, jsonb) from public, anon;

-- Preserve a source migration privilege rule.
grant execute on function public.can_upload_job_file_object(text, jsonb) to authenticated;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'threadline_app') THEN
    EXECUTE 'GRANT authenticated, service_role TO threadline_app';
  END IF;
END $$;
