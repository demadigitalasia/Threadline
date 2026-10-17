-- Freelancers may keep one private profile photo in their own storage folder.
alter table public.profiles
  add column if not exists avatar_path text;

alter table public.profiles
  drop constraint if exists profiles_avatar_path_owner_check;
alter table public.profiles
  add constraint profiles_avatar_path_owner_check
  check (avatar_path is null or avatar_path like id::text || '/%');

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'profile-photos',
  'profile-photos',
  false,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp']::text[]
)
on conflict (id) do nothing;

drop policy if exists profile_photos_read_self on storage.objects;
drop policy if exists profile_photos_upload_self on storage.objects;
drop policy if exists profile_photos_delete_self on storage.objects;

create policy profile_photos_read_self on storage.objects for select to authenticated
  using (
    bucket_id = 'profile-photos'
    and public.is_freelance()
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy profile_photos_upload_self on storage.objects for insert to authenticated
  with check (
    bucket_id = 'profile-photos'
    and public.is_freelance()
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy profile_photos_delete_self on storage.objects for delete to authenticated
  using (
    bucket_id = 'profile-photos'
    and public.is_freelance()
    and (storage.foldername(name))[1] = auth.uid()::text
  );
