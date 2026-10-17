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
