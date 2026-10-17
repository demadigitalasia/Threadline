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
