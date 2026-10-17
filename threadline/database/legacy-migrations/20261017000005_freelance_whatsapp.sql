-- Keep freelancer contact details separate from profile names so other
-- freelancers cannot read phone numbers through the profiles table policies.
create table if not exists public.profile_contacts (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  whatsapp text not null check (nullif(btrim(whatsapp), '') is not null),
  updated_at timestamptz not null default now()
);
alter table public.profile_contacts enable row level security;
revoke all on public.profile_contacts from public, anon, authenticated;
grant select on public.profile_contacts to authenticated;
drop policy if exists profile_contacts_admin_select on public.profile_contacts;
create policy profile_contacts_admin_select on public.profile_contacts
  for select to authenticated using (public.is_admin());
drop policy if exists profile_contacts_self_select on public.profile_contacts;
create policy profile_contacts_self_select on public.profile_contacts
  for select to authenticated using (profile_id = public.my_uid());

-- Keep the signup metadata on the profile row so admins can contact freelancers.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare
  v_name text;
  v_whatsapp text;
begin
  v_name := coalesce(
    nullif(btrim(NEW.raw_user_meta_data ->> 'name'), ''),
    split_part(NEW.email, '@', 1)
  );
  v_whatsapp := nullif(btrim(NEW.raw_user_meta_data ->> 'whatsapp'), '');

  insert into public.profiles(id, name, role)
  values (NEW.id, v_name, 'freelance')
  on conflict (id) do nothing;

  if v_whatsapp is not null then
    insert into public.profile_contacts(profile_id, whatsapp)
    values (NEW.id, v_whatsapp) on conflict (profile_id) do nothing;
  end if;

  insert into public.chat_threads(freelance_profile_id)
  values (NEW.id) on conflict do nothing;
  return NEW;
exception when unique_violation then
  -- Preserve the submitted name while resolving a duplicate profile name.
  insert into public.profiles(id, name, role)
  values (NEW.id, v_name || '-' || substr(md5(NEW.id::text), 1, 4), 'freelance')
  on conflict (id) do nothing;
  if v_whatsapp is not null then
    insert into public.profile_contacts(profile_id, whatsapp)
    values (NEW.id, v_whatsapp) on conflict (profile_id) do nothing;
  end if;
  insert into public.chat_threads(freelance_profile_id)
  values (NEW.id) on conflict do nothing;
  return NEW;
end $$;
