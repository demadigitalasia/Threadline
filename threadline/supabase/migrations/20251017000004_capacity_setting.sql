-- D-26: batas job aktif menjadi pengaturan global (default 4, 1-20), diubah Admin.

alter table public.app_settings
  add column if not exists max_active_jobs integer not null default 4
  check (max_active_jobs >= 1 and max_active_jobs <= 20);

create or replace function public.assign_job(
  p_job text, p_target uuid, p_reason text, p_expected_rev int
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_job public.jobs%rowtype; v_t public.profiles%rowtype; v_active int; v_max int;
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'Hanya Admin'); end if;
  select * into v_job from public.jobs where id = p_job for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Job tidak ditemukan'); end if;
  if v_job.revision <> p_expected_rev then return jsonb_build_object('ok', false, 'error', 'STALE: muat ulang dulu'); end if;
  if v_job.status in ('ACC','Dibatalkan') then return jsonb_build_object('ok', false, 'error', 'Job terminal'); end if;
  if v_job.status = 'MintaACC' then return jsonb_build_object('ok', false, 'error', 'MintaACC harus diputuskan dulu'); end if;
  select * into v_t from public.profiles where id = p_target;
  if not found or v_t.role <> 'freelance' then return jsonb_build_object('ok', false, 'error', 'Target bukan Freelance'); end if;
  select coalesce(max(max_active_jobs), 4) into v_max from public.app_settings where id = 1;
  perform pg_advisory_xact_lock(hashtext('assign:' || p_target::text)::bigint);
  if now() - v_t.last_seen >= interval '90 seconds' and not (v_job.assignee_profile_id = p_target and v_job.status = 'Antre') then
    return jsonb_build_object('ok', false, 'error', 'Freelance offline');
  end if;
  select count(*) into v_active from public.jobs
    where assignee_profile_id = p_target and status in ('Antre','Dikerjakan','MintaACC','Revisi') and id <> p_job;
  if v_active >= v_max then
    return jsonb_build_object('ok', false, 'error', 'Freelance penuh (batas ' || v_max || ' job aktif)');
  end if;
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
