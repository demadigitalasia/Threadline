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
