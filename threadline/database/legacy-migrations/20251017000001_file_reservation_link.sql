-- Kaitan eksplisit reservation -> file agar commit kuota tepat sasaran,
-- plus backstop kuota untuk insert langsung tanpa reservation.

alter table public.job_files
  add column if not exists reservation_id uuid references public.job_upload_reservations(id) on delete set null;

drop trigger if exists trg_job_files_guard on public.job_files;
drop function if exists public.guard_job_file();

create or replace function public.guard_job_file() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_locked boolean;
  v_res uuid;
  v_total bigint;
begin
  if TG_OP = 'DELETE' then
    if public.is_service_role() then return OLD; end if;
    select exists (select 1 from public.job_submission_files b where b.job_file_id = OLD.id) into v_locked;
    if v_locked then
      raise exception 'FILE_LOCKED: file terikat submission';
    end if;
    return OLD;
  end if;

  if TG_OP = 'INSERT' then
    if public.is_service_role() then return NEW; end if;
    perform pg_advisory_xact_lock(hashtext(NEW.job_id)::bigint);
    if NEW.reservation_id is not null then
      select r.id into v_res from public.job_upload_reservations r
        where r.id = NEW.reservation_id and r.job_id = NEW.job_id
          and r.profile_id = public.my_uid() and r.state = 'active' and r.expires_at > now();
      if v_res is null then
        raise exception 'FORBIDDEN: reservation tidak valid';
      end if;
      update public.job_upload_reservations set state = 'committed' where id = v_res;
    else
      -- insert tanpa reservation: cek kuota penuh sebagai backstop
      select coalesce(sum(f.size_bytes),0) into v_total
        from public.job_files f where f.job_id = NEW.job_id and f.expired_at is null;
      select v_total + coalesce(sum(r.size_bytes),0) into v_total
        from public.job_upload_reservations r
        where r.job_id = NEW.job_id and r.state = 'active' and r.expires_at > now();
      if v_total + NEW.size_bytes > 10737418240 then
        raise exception 'QUOTA_EXCEEDED: total melebihi 10 GiB per job';
      end if;
    end if;
    return NEW;
  end if;

  -- UPDATE
  if NEW.expired_at is distinct from OLD.expired_at and not public.is_service_role() then
    raise exception 'FORBIDDEN: expired_at hanya oleh retensi';
  end if;
  if public.is_service_role() then return NEW; end if;
  select exists (select 1 from public.job_submission_files b where b.job_file_id = NEW.id) into v_locked;
  if v_locked then
    raise exception 'FILE_LOCKED: file terikat submission';
  end if;
  return NEW;
end $$;

create trigger trg_job_files_guard
  before insert or update or delete on public.job_files
  for each row execute function public.guard_job_file();
