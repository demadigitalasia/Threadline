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
