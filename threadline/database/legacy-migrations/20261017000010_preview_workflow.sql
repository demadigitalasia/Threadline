-- Replace final-result approval with preview review, then final CDR delivery.

alter table public.job_submissions
  add column if not exists submission_kind text not null default 'legacy';

alter table public.job_submissions
  drop constraint if exists job_submissions_submission_kind_check;
alter table public.job_submissions
  add constraint job_submissions_submission_kind_check
  check (submission_kind in ('legacy', 'preview'));

-- Historical approvals already completed their old workflow. Preserve those
-- jobs as Finished. Old pending file approvals return to Dikerjakan so the
-- freelancer can submit image previews under the new workflow.
alter table public.jobs drop constraint if exists jobs_active_have_assignee;
drop trigger if exists trg_guard_approved on public.jobs;

update public.jobs set status = 'Finished' where status = 'ACC';
update public.jobs set status = 'Dikerjakan', current_submission_id = null where status = 'MintaACC';
update public.jobs set status = 'Dikerjakan' where status = 'Revisi';

alter table public.jobs
  add constraint jobs_active_have_assignee check (
    (status in ('Antre','Dikerjakan','Preview','ACC','MintaACC','Revisi') and assignee_profile_id is not null)
    or status not in ('Antre','Dikerjakan','Preview','ACC','MintaACC','Revisi')
  );

alter table public.job_files drop constraint if exists job_files_file_role_check;
alter table public.job_files add constraint job_files_file_role_check
  check (file_role in ('reference','result','preview','source'));

create or replace function public.guard_job_approved() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_service_role() then return NEW; end if;
  if OLD.status in ('ACC','Finished') and (
    NEW.approved_fee is distinct from OLD.approved_fee or
    NEW.approved_for_profile_id is distinct from OLD.approved_for_profile_id or
    NEW.approved_submission_id is distinct from OLD.approved_submission_id or
    NEW.assignee_profile_id is distinct from OLD.assignee_profile_id
  ) then
    raise exception 'FORBIDDEN: fee dan penerima yang sudah ACC terkunci';
  end if;
  if OLD.status = 'Finished' and NEW.status is distinct from OLD.status then
    raise exception 'FORBIDDEN: job Finished terminal';
  end if;
  if NEW.status is distinct from OLD.status and NEW.status = 'Finished' and OLD.status <> 'ACC' then
    raise exception 'FORBIDDEN: hanya job ACC yang dapat diselesaikan';
  end if;
  if NEW.status is distinct from OLD.status and NEW.status = 'ACC' and OLD.status <> 'Preview' then
    raise exception 'FORBIDDEN: ACC hanya dapat diberikan setelah review Preview';
  end if;
  if NEW.status is distinct from OLD.status and NEW.status = 'ACC' and not public.is_admin() then
    raise exception 'FORBIDDEN: hanya Admin yang dapat menyetujui preview';
  end if;
  if NEW.status is distinct from OLD.status and NEW.status = 'ACC' and (
    NEW.approved_submission_id is distinct from OLD.current_submission_id or
    NEW.approved_for_profile_id is distinct from OLD.assignee_profile_id or
    NEW.approved_fee is distinct from NEW.fee or
    not exists (
      select 1 from public.job_submissions s
      where s.id = OLD.current_submission_id and s.job_id = OLD.id
        and s.submission_kind = 'preview' and s.decision = 'approved'
        and s.reviewed_by_profile_id is not null
    )
  ) then
    raise exception 'FORBIDDEN: preview belum disetujui oleh Admin';
  end if;
  if NEW.status is distinct from OLD.status and NEW.status = 'Dikerjakan' then
    if OLD.status in ('Antre','Revisi') and public.is_freelance()
      and OLD.assignee_profile_id = public.my_uid() then
      null;
    elsif OLD.status = 'Preview' and public.is_admin() and exists (
      select 1 from public.job_submissions s
      where s.id = OLD.current_submission_id and s.job_id = OLD.id
        and s.submission_kind = 'preview' and s.decision = 'revision_requested'
        and s.reviewed_by_profile_id is not null
    ) then
      null;
    else
      raise exception 'FORBIDDEN: hanya freelancer yang memulai atau Admin yang meminta revisi';
    end if;
  end if;
  if NEW.status = 'Preview' and OLD.status = 'Dikerjakan' and (
    not public.is_freelance() or OLD.assignee_profile_id is distinct from public.my_uid() or
    not exists (
      select 1 from public.job_submissions s
      where s.id = NEW.current_submission_id and s.job_id = OLD.id
        and s.submission_kind = 'preview' and s.decision = 'pending'
    )
  ) then
    raise exception 'FORBIDDEN: preview hanya dapat diajukan oleh freelancer yang ditugaskan';
  end if;
  if NEW.status is distinct from OLD.status and NEW.status = 'Finished' and (not public.is_freelance() or OLD.assignee_profile_id is distinct from public.my_uid()) then
    raise exception 'FORBIDDEN: freelancer yang ditugaskan mengirim file asli';
  end if;
  if OLD.status = 'ACC' and NEW.status = 'Finished' and not exists (
    select 1 from public.job_files f
    where f.job_id = OLD.id and f.file_role = 'source' and f.file_kind = 'CDR'
      and f.uploaded_by_profile_id = OLD.assignee_profile_id and f.expired_at is null
  ) then
    raise exception 'SOURCE_REQUIRED: unggah file asli CDR sebelum Finished';
  end if;
  if OLD.status = 'ACC' and NEW.status is distinct from OLD.status
     and NEW.status not in ('Finished','Dibatalkan') then
    raise exception 'FORBIDDEN: ACC preview hanya dapat diselesaikan atau dibatalkan';
  end if;
  if OLD.status = 'Dibatalkan' and NEW.status is distinct from OLD.status then
    raise exception 'FORBIDDEN: job Dibatalkan terminal';
  end if;
  return NEW;
end $$;
create trigger trg_guard_approved before update on public.jobs
  for each row execute function public.guard_job_approved();

-- Admins can assign/reassign before preview approval. ACC locks the recipient.
create or replace function public.assign_job(
  p_job text, p_target uuid, p_reason text, p_expected_rev int
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype; v_t public.profiles%rowtype; v_active int; v_max int;
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'Hanya Admin'); end if;
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.status in ('ACC','Finished','Dibatalkan') then return jsonb_build_object('ok', false, 'error', 'Penerima job sudah dikunci'); end if;
  if v_job.status in ('Preview','MintaACC') then return jsonb_build_object('ok', false, 'error', 'Tinjau preview sebelum mengalihkan job'); end if;
  select coalesce(max(max_active_jobs), 4) into v_max from public.app_settings where id = 1;
  select * into v_t from public.profiles where id = p_target;
  if not found or v_t.role <> 'freelance' then return jsonb_build_object('ok', false, 'error', 'Target bukan Freelance'); end if;
  perform pg_advisory_xact_lock(hashtext('assign:' || p_target::text)::bigint);
  if now() - v_t.last_seen >= interval '90 seconds' and not (v_job.assignee_profile_id = p_target and v_job.status = 'Antre') then
    return jsonb_build_object('ok', false, 'error', 'Freelance offline');
  end if;
  select count(*) into v_active from public.jobs
    where assignee_profile_id = p_target and status in ('Antre','Dikerjakan','Preview','ACC','MintaACC','Revisi') and id <> p_job;
  if v_active >= v_max then return jsonb_build_object('ok', false, 'error', 'Freelance penuh (batas ' || v_max || ' job aktif)'); end if;
  if v_job.assignee_profile_id is not null and v_job.assignee_profile_id <> p_target
     and v_job.status in ('Dikerjakan','Revisi') and nullif(trim(coalesce(p_reason,'')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Pengalihan Dikerjakan/Revisi wajib alasan');
  end if;
  if v_job.assignee_profile_id is null then
    update public.jobs set assignee_profile_id = p_target, status = 'Antre',
      antre_since = now(), revision = revision + 1 where id = p_job;
    insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, reason)
    values (p_job, public.my_uid(), 'assign', v_job.status, 'Antre', nullif(trim(coalesce(p_reason,'')), ''));
  else
    update public.jobs set assignee_profile_id = p_target,
      antre_since = case when v_job.status = 'Antre' then now() else antre_since end,
      revision = revision + 1 where id = p_job;
    insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, reason)
    values (p_job, public.my_uid(), 'reassign', v_job.status, v_job.status, nullif(trim(coalesce(p_reason,'')), ''));
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.transition_job(
  p_job text, p_to job_status, p_reason text, p_expected_rev int
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype; v_admin boolean;
begin
  v_admin := public.is_admin();
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.status in ('ACC','Finished','Dibatalkan') then return jsonb_build_object('ok', false, 'error', 'Job tidak dapat memulai ulang'); end if;
  if v_admin then return jsonb_build_object('ok', false, 'error', 'Freelancer yang ditugaskan memulai pekerjaan'); end if;
  if v_job.assignee_profile_id is distinct from public.my_uid() then
    return jsonb_build_object('ok', false, 'error', 'Bukan job milikmu');
  end if;
  if p_to <> 'Dikerjakan' or not (v_job.status = 'Antre' or v_job.status = 'Revisi') then
    return jsonb_build_object('ok', false, 'error', 'Gunakan alur preview untuk mengubah tahap ini');
  end if;
  update public.jobs set status = 'Dikerjakan', revision = revision + 1 where id = p_job;
  insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, reason)
  values (p_job, public.my_uid(), 'status', v_job.status, 'Dikerjakan', nullif(trim(coalesce(p_reason,'')), ''));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.submit_preview(
  p_job text, p_file_ids uuid[], p_note text, p_expected_rev int
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype; v_sub uuid; v_ver int; v_file uuid;
begin
  if not public.is_freelance() then return jsonb_build_object('ok', false, 'error', 'Hanya freelancer aktif yang dapat mengirim preview'); end if;
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.assignee_profile_id is distinct from public.my_uid() then return jsonb_build_object('ok', false, 'error', 'Bukan job milikmu'); end if;
  if v_job.status not in ('Dikerjakan','Revisi') then return jsonb_build_object('ok', false, 'error', 'Preview hanya dapat dikirim saat job dikerjakan'); end if;
  if coalesce(array_length(p_file_ids, 1), 0) < 1 then return jsonb_build_object('ok', false, 'error', 'Pilih minimal satu gambar preview'); end if;
  foreach v_file in array p_file_ids loop
    if not exists (
      select 1 from public.job_files f where f.id = v_file and f.job_id = p_job
        and f.file_role = 'preview' and f.file_kind in ('PNG','JPEG','SVG')
        and f.expired_at is null and f.uploaded_by_profile_id = public.my_uid()
    ) then return jsonb_build_object('ok', false, 'error', 'Pilih gambar preview milik Anda yang masih aktif'); end if;
  end loop;
  select coalesce(max(version), 0) + 1 into v_ver from public.job_submissions where job_id = p_job;
  v_sub := gen_random_uuid();
  insert into public.job_submissions(id, job_id, version, submitted_by_profile_id, note, submission_kind)
  values (v_sub, p_job, v_ver, public.my_uid(), nullif(trim(coalesce(p_note,'')), ''), 'preview');
  insert into public.job_submission_files(submission_id, job_file_id) select v_sub, unnest(p_file_ids);
  update public.jobs set status = 'Preview', current_submission_id = v_sub, revision = revision + 1 where id = p_job;
  insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status)
  values (p_job, public.my_uid(), 'preview_submit', v_job.status, 'Preview');
  return jsonb_build_object('ok', true, 'submission_id', v_sub);
end $$;

create or replace function public.review_submission(
  p_submission uuid, p_decision text, p_review_note text, p_expected_rev int
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_sub public.job_submissions%rowtype; v_job public.jobs%rowtype;
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'Hanya Admin'); end if;
  select * into v_sub from public.job_submissions where id = p_submission;
  if not found then return jsonb_build_object('ok', false, 'error', 'Submission tidak ditemukan'); end if;
  select * into v_job from public.jobs where id = v_sub.job_id for update;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.status <> 'Preview' or v_job.current_submission_id is distinct from p_submission
    or v_sub.submission_kind <> 'preview' or v_sub.decision <> 'pending' then
    return jsonb_build_object('ok', false, 'error', 'Preview ini bukan pengajuan aktif');
  end if;
  if p_decision = 'approved' then
    update public.job_submissions set decision = 'approved', reviewed_by_profile_id = public.my_uid(), reviewed_at = now() where id = p_submission;
    update public.jobs set status = 'ACC', approved_fee = fee, approved_for_profile_id = assignee_profile_id,
      approved_submission_id = p_submission, revision = revision + 1 where id = v_job.id;
    insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status)
    values (v_job.id, public.my_uid(), 'preview_approve', 'Preview', 'ACC');
  elsif p_decision = 'revision' then
    if nullif(trim(coalesce(p_review_note,'')), '') is null then return jsonb_build_object('ok', false, 'error', 'Alasan revisi wajib diisi'); end if;
    update public.job_submissions set decision = 'revision_requested', review_note = trim(p_review_note),
      reviewed_by_profile_id = public.my_uid(), reviewed_at = now() where id = p_submission;
    update public.jobs set status = 'Dikerjakan', revision = revision + 1 where id = v_job.id;
    insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, reason)
    values (v_job.id, public.my_uid(), 'preview_revision', 'Preview', 'Dikerjakan', trim(p_review_note));
  else
    return jsonb_build_object('ok', false, 'error', 'Keputusan tidak dikenal');
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.finish_job(p_job text, p_expected_rev int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype; v_final_files jsonb;
begin
  if not public.is_freelance() then return jsonb_build_object('ok', false, 'error', 'Hanya freelancer aktif yang dapat menyelesaikan job'); end if;
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.assignee_profile_id is distinct from public.my_uid() then return jsonb_build_object('ok', false, 'error', 'Bukan job milikmu'); end if;
  if v_job.status <> 'ACC' then return jsonb_build_object('ok', false, 'error', 'Preview harus di-ACC sebelum file asli dikirim'); end if;
  select coalesce(jsonb_agg(id), '[]'::jsonb) into v_final_files from public.job_files
  where job_id = p_job and file_role = 'source' and file_kind = 'CDR'
    and uploaded_by_profile_id = public.my_uid() and expired_at is null;
  if jsonb_array_length(v_final_files) = 0 then return jsonb_build_object('ok', false, 'error', 'Unggah minimal satu file asli CDR terlebih dahulu'); end if;
  update public.jobs set status = 'Finished', revision = revision + 1 where id = p_job;
  insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, details)
  values (p_job, public.my_uid(), 'finish', 'ACC', 'Finished', jsonb_build_object('final_file_ids', v_final_files));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.cancel_job(p_job text, p_reason text, p_expected_rev int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype;
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'Hanya Admin'); end if;
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.status in ('Finished','Dibatalkan') then return jsonb_build_object('ok', false, 'error', 'Job sudah terminal'); end if;
  if nullif(trim(coalesce(p_reason,'')), '') is null then return jsonb_build_object('ok', false, 'error', 'Alasan wajib'); end if;
  update public.jobs set status = 'Dibatalkan', cancelled_at = now(), cancelled_by_profile_id = public.my_uid(),
    cancellation_reason = trim(p_reason), revision = revision + 1 where id = p_job;
  insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, reason)
  values (p_job, public.my_uid(), 'cancel', v_job.status, 'Dibatalkan', trim(p_reason));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.update_job_fields(
  p_job text, p_expected_rev int, p_tim text, p_jenis job_type, p_qty int,
  p_deadline timestamptz, p_fee bigint, p_priority job_priority, p_brief text, p_ref text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype;
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'Hanya Admin'); end if;
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.status in ('ACC','Finished','Dibatalkan') then return jsonb_build_object('ok', false, 'error', 'Job yang sudah ACC tidak dapat diedit'); end if;
  update public.jobs set tim = coalesce(nullif(trim(p_tim), ''), tim), jenis = coalesce(p_jenis, jenis),
    qty = coalesce(p_qty, qty), deadline = coalesce(p_deadline, deadline), fee = coalesce(p_fee, fee),
    priority = coalesce(p_priority, priority), brief = coalesce(nullif(trim(p_brief), ''), brief),
    ref = coalesce(p_ref, ref), revision = revision + 1 where id = p_job;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.reserve_upload(p_job text, p_size bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype; v_total bigint; v_r uuid; v_admin boolean;
begin
  v_admin := public.is_admin();
  if not v_admin and not public.is_freelance() then return jsonb_build_object('ok', false, 'error', 'Role ini tidak dapat mengunggah file'); end if;
  select * into v_job from public.jobs where id = p_job;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.status in ('Finished','Dibatalkan') then return jsonb_build_object('ok', false, 'error', 'Job sudah selesai'); end if;
  if not v_admin and v_job.assignee_profile_id is distinct from public.my_uid() then return jsonb_build_object('ok', false, 'error', 'Bukan job milikmu'); end if;
  if not v_admin and v_job.status not in ('Dikerjakan','Revisi','ACC') then return jsonb_build_object('ok', false, 'error', 'Unggahan tidak tersedia pada tahap ini'); end if;
  if p_size <= 0 or p_size > 1073741824 then return jsonb_build_object('ok', false, 'error', 'Maks 1 GiB per file'); end if;
  perform pg_advisory_xact_lock(hashtext(p_job)::bigint);
  delete from public.job_upload_reservations where job_id = p_job and state = 'active' and expires_at <= now();
  select coalesce(sum(f.size_bytes),0) into v_total from public.job_files f where f.job_id = p_job and f.expired_at is null;
  select v_total + coalesce(sum(r.size_bytes),0) into v_total from public.job_upload_reservations r
    where r.job_id = p_job and r.state = 'active' and r.expires_at > now();
  if v_total + p_size > 10737418240 then return jsonb_build_object('ok', false, 'error', 'Total melebihi 10 GiB per job'); end if;
  insert into public.job_upload_reservations(job_id, profile_id, size_bytes) values (p_job, public.my_uid(), p_size) returning id into v_r;
  return jsonb_build_object('ok', true, 'reservation_id', v_r);
end $$;

create or replace function public.validate_job_file_kind() returns trigger
language plpgsql security definer set search_path = public as $$
declare ext text; v_job public.jobs%rowtype;
begin
  ext := lower(split_part(NEW.name, '.', array_length(string_to_array(NEW.name, '.'), 1)));
  if ext = 'jpg' then ext := 'jpeg'; end if;
  if ext not in ('pdf','cdr','png','jpeg','svg','docx','xlsx','pptx','ai','psd') then raise exception 'INVALID_TYPE: format file tidak didukung'; end if;
  if upper(ext) <> NEW.file_kind then raise exception 'INVALID_TYPE: file_kind tidak cocok ekstensi'; end if;
  select * into v_job from public.jobs where id = NEW.job_id;
  if not found then raise exception 'JOB_NOT_FOUND: job tidak ditemukan'; end if;
  if NEW.file_role = 'reference' then
    if not public.is_admin() then raise exception 'REFERENCE_ADMIN_ONLY: hanya Admin yang dapat mengunggah referensi'; end if;
    if v_job.status in ('Finished','Dibatalkan') then raise exception 'JOB_FINISHED: job sudah selesai'; end if;
  elsif NEW.file_role = 'preview' then
    if not public.is_freelance() or v_job.assignee_profile_id is distinct from public.my_uid()
      or v_job.status not in ('Dikerjakan','Revisi') or NEW.file_kind not in ('PNG','JPEG','SVG') then
      raise exception 'PREVIEW_UPLOAD_INVALID: unggah gambar preview hanya saat job dikerjakan';
    end if;
  elsif NEW.file_role = 'source' then
    if not public.is_freelance() or v_job.assignee_profile_id is distinct from public.my_uid()
      or v_job.status <> 'ACC' or NEW.file_kind <> 'CDR' then
      raise exception 'SOURCE_UPLOAD_INVALID: file asli CDR hanya dapat dikirim setelah preview di-ACC';
    end if;
  else
    raise exception 'FILE_ROLE_INVALID: gunakan referensi, preview, atau file asli';
  end if;
  return NEW;
end $$;

create or replace function public.preserve_finished_source_file() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_service_role() and OLD.file_role = 'source'
    and exists (select 1 from public.jobs j where j.id = OLD.job_id and j.status = 'Finished') then
    raise exception 'FILE_LOCKED: file asli job Finished tidak dapat dihapus';
  end if;
  return OLD;
end $$;
drop trigger if exists trg_preserve_finished_source_file on public.job_files;
create trigger trg_preserve_finished_source_file before delete on public.job_files
  for each row execute function public.preserve_finished_source_file();

-- Finance reporting counts only jobs whose original files have been delivered.
create or replace function public.finance_acc_recipients()
returns table(profile_id uuid, profile_name text)
language sql stable security definer set search_path = public as $$
  select distinct p.id, p.name
  from public.profiles p join public.jobs j on coalesce(j.approved_for_profile_id, j.assignee_profile_id) = p.id
  where public.is_finance() and j.status = 'Finished'
$$;
create or replace function public.finance_acc_approval_times()
returns table(job_id text, approved_at timestamptz)
language sql stable security definer set search_path = public as $$
  select e.job_id, max(e.created_at)
  from public.job_events e join public.jobs j on j.id = e.job_id
  where public.is_finance() and j.status = 'Finished' and e.event_type = 'preview_approve'
  group by e.job_id
$$;
drop policy if exists jobs_finance_acc_read on public.jobs;
create policy jobs_finance_acc_read on public.jobs for select to authenticated
  using (public.is_finance() and status = 'Finished');

-- The old submission endpoint would bypass preview review; disable it.
revoke all on function public.submit_for_acc(text, uuid[], text, int) from public, anon, authenticated;
revoke all on function public.submit_preview(text, uuid[], text, int) from public, anon;
grant execute on function public.submit_preview(text, uuid[], text, int) to authenticated, service_role;
revoke all on function public.finish_job(text, int) from public, anon;
grant execute on function public.finish_job(text, int) to authenticated, service_role;
