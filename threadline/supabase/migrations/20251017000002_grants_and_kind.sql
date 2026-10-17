-- Hak akses tabel/fungsi untuk peran aplikasi.
-- Tanpa ini RLS pun tak bisa dievaluasi (permission denied).

grant usage on schema public to anon, authenticated;

grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;

grant all privileges on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;

alter default privileges in schema public grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema public grant usage, select on sequences to authenticated;
alter default privileges in schema public grant all on tables to service_role;

-- RPC data: cabut dari PUBLIC/anon, buka hanya untuk authenticated (+service_role di atas).
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('create_job','assign_job','transition_job','submit_for_acc','review_submission',
        'cancel_job','delete_job','update_job_fields','reserve_upload','release_upload_reservation','promote_admin')
  loop
    execute 'revoke all on function ' || f.sig || ' from public, anon';
    execute 'grant execute on function ' || f.sig || ' to authenticated, service_role';
  end loop;
end $$;

-- Validasi jenis file dari EKSTENSI NAMA di server (nilai file_kind klien tak dipercaya).
create or replace function public.validate_job_file_kind() returns trigger
language plpgsql security definer set search_path = public as $$
declare ext text;
begin
  ext := lower(split_part(NEW.name, '.', array_length(string_to_array(NEW.name, '.'), 1)));
  if ext = 'jpg' then ext := 'jpeg'; end if;
  if ext not in ('pdf','cdr','png','jpeg') then
    raise exception 'INVALID_TYPE: hanya PDF/CDR/PNG/JPEG';
  end if;
  if upper(ext) <> NEW.file_kind then
    raise exception 'INVALID_TYPE: file_kind tidak cocok ekstensi';
  end if;
  return NEW;
end $$;
drop trigger if exists trg_validate_kind on public.job_files;
create trigger trg_validate_kind before insert on public.job_files
  for each row execute function public.validate_job_file_kind();
