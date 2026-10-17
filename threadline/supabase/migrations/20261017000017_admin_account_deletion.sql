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
