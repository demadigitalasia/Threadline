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
