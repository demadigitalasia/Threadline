-- Pisahkan file referensi dari hasil kerja dan perluas format file yang didukung.
alter table public.job_files
  add column if not exists file_role text not null default 'result';

alter table public.job_files
  drop constraint if exists job_files_file_kind_check;

alter table public.job_files
  add constraint job_files_file_kind_allowed_check
  check (file_kind in ('PDF','CDR','PNG','JPEG','SVG','DOCX','XLSX','PPTX','AI','PSD'));

alter table public.job_files
  drop constraint if exists job_files_file_role_check;

alter table public.job_files
  add constraint job_files_file_role_check
  check (file_role in ('reference','result'));

-- Validasi ekstensi dan label jenis tetap dilakukan oleh database.
create or replace function public.validate_job_file_kind() returns trigger
language plpgsql security definer set search_path = public as $$
declare ext text;
begin
  ext := lower(split_part(NEW.name, '.', array_length(string_to_array(NEW.name, '.'), 1)));
  if ext = 'jpg' then ext := 'jpeg'; end if;
  if ext not in ('pdf','cdr','png','jpeg','svg','docx','xlsx','pptx','ai','psd') then
    raise exception 'INVALID_TYPE: format file tidak didukung';
  end if;
  if upper(ext) <> NEW.file_kind then
    raise exception 'INVALID_TYPE: file_kind tidak cocok ekstensi';
  end if;
  if NEW.file_role = 'reference' and not public.is_admin() then
    raise exception 'REFERENCE_ADMIN_ONLY: hanya Admin yang dapat mengunggah file referensi';
  end if;
  return NEW;
end $$;

-- Pertahanan database: hanya file hasil yang dapat dikunci dalam pengajuan ACC.
create or replace function public.submit_for_acc(
  p_job text, p_file_ids uuid[], p_note text, p_expected_rev int
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype; v_sub uuid; v_ver int; v_f uuid;
begin
  if not public.is_freelance() then
    return jsonb_build_object('ok', false, 'error', 'Hanya Freelance yang dapat mengirim hasil');
  end if;
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.assignee_profile_id is distinct from public.my_uid() then
    return jsonb_build_object('ok', false, 'error', 'Bukan job milikmu');
  end if;
  if v_job.status not in ('Dikerjakan','Revisi') then
    return jsonb_build_object('ok', false, 'error', 'Submission hanya dari Dikerjakan/Revisi');
  end if;
  if coalesce(array_length(p_file_ids, 1), 0) < 1 then
    return jsonb_build_object('ok', false, 'error', 'Pilih >=1 file');
  end if;
  foreach v_f in array p_file_ids loop
    if not exists (
      select 1 from public.job_files f
      where f.id = v_f and f.job_id = p_job and f.file_role = 'result' and f.expired_at is null
    ) then
      return jsonb_build_object('ok', false, 'error', 'Pilih file hasil yang masih aktif');
    end if;
  end loop;
  select coalesce(max(version), 0) + 1 into v_ver from public.job_submissions where job_id = p_job;
  v_sub := gen_random_uuid();
  insert into public.job_submissions(id, job_id, version, submitted_by_profile_id, note)
  values (v_sub, p_job, v_ver, public.my_uid(), nullif(trim(coalesce(p_note,'')), ''));
  insert into public.job_submission_files(submission_id, job_file_id)
  select v_sub, unnest(p_file_ids);
  update public.jobs set status = 'MintaACC', current_submission_id = v_sub, revision = revision + 1 where id = p_job;
  insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status)
  values (p_job, public.my_uid(), 'submit', v_job.status, 'MintaACC');
  return jsonb_build_object('ok', true, 'submission_id', v_sub);
end $$;
