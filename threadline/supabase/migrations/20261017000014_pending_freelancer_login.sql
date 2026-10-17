-- Freelancer applicants can sign in immediately to see their Admin Review status.
-- Confirm existing pending Auth users too; the review decision remains the access gate.
update auth.users as u
set email_confirmed_at = now(),
    updated_at = now()
from public.profiles as p
where p.id = u.id
  and p.role = 'freelance'
  and p.registration_status = 'pending'
  and p.is_active = false
  and u.email_confirmed_at is null;

-- Keep a pending freelancer's own profile readable for the Admin Review screen,
-- while withholding their identity from operational RLS policies and RPCs.
create or replace function public.my_uid() returns uuid
language sql stable security definer set search_path = public, auth as $$
  select auth.uid()
  where exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.is_active
      and p.registration_status = 'approved'
  )
$$;

drop policy if exists prof_self_select on public.profiles;
create policy prof_self_select on public.profiles
  for select to authenticated using (id = auth.uid());
