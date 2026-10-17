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

-- ============ REALTIME ============
do $$
declare t text;
begin
  foreach t in array array['profiles','jobs','job_files','job_submissions','job_events','app_settings','chat_threads','chat_messages'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;
