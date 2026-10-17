-- Perbaikan create_job: values kekurangan p_ref (9 kolom, 8 values).

create or replace function public.create_job(
  p_tim text, p_jenis job_type, p_qty int, p_deadline timestamptz,
  p_fee bigint, p_priority job_priority, p_brief text, p_ref text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id text;
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'Hanya Admin'); end if;
  if p_qty < 1 then return jsonb_build_object('ok', false, 'error', 'Qty minimal 1'); end if;
  if p_fee < 0 then return jsonb_build_object('ok', false, 'error', 'Fee tidak valid'); end if;
  v_id := 'JRS-' || nextval('public.threadline_job_seq')::text;
  insert into public.jobs(id, tim, jenis, qty, deadline, fee, priority, brief, ref)
  values (v_id, nullif(trim(p_tim), ''), p_jenis, p_qty, p_deadline, p_fee, p_priority,
    nullif(trim(p_brief), ''), nullif(trim(coalesce(p_ref, '')), ''));
  insert into public.job_events(job_id, actor_profile_id, event_type, to_status)
  values (v_id, public.my_uid(), 'create', 'Belum Ditugaskan');
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;
