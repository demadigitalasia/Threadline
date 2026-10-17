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
