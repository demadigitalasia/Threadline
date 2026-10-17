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
