-- MFA is not required for Super Admin accounts. Keep role and active-profile
-- checks, and allow password-only sessions even if an authenticator was enrolled.
create or replace function public.is_super_admin() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.is_active and p.role = 'super_admin'
  )
$$;
