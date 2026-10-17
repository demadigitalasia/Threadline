-- TOTP remains available as an optional Supabase Auth factor, but is no longer
-- required to access Super Admin data or operations.
create or replace function public.is_super_admin() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.is_active and p.role = 'super_admin'
  )
$$;
