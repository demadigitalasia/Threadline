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
