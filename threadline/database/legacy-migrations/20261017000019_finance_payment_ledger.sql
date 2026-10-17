-- Finance payment ledger: preserve finish dates, record transfers and allocations,
-- and expose curated, paginated reporting functions to Finance.

alter table public.jobs add column if not exists finished_at timestamptz;

update public.jobs j
set finished_at = coalesce(
  (select max(e.created_at) from public.job_events e where e.job_id = j.id and e.event_type = 'finish'),
  j.created_at
)
where j.status = 'Finished' and j.finished_at is null;

create index if not exists jobs_finished_at_recipient_idx
  on public.jobs (finished_at, (coalesce(approved_for_profile_id, assignee_profile_id)))
  where status = 'Finished';

create or replace function public.guard_job_finished_at() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if OLD.status = 'Finished' and NEW.status <> 'Finished' then
    raise exception 'FINISHED_JOB_LOCKED: job selesai tidak dapat dibuka kembali';
  end if;
  if OLD.finished_at is not null and NEW.finished_at is distinct from OLD.finished_at then
    raise exception 'FINISH_TIME_LOCKED: waktu selesai tidak dapat diubah';
  end if;
  if NEW.status <> 'Finished' and NEW.finished_at is not null then
    raise exception 'FINISH_TIME_INVALID: hanya job Finished yang memiliki waktu selesai';
  end if;
  if NEW.status = 'Finished' and (OLD.status <> 'Finished' or OLD.finished_at is null) then
    NEW.finished_at := now();
  end if;
  return NEW;
end $$;

drop trigger if exists trg_guard_job_finished_at on public.jobs;
create trigger trg_guard_job_finished_at before update on public.jobs
  for each row execute function public.guard_job_finished_at();

-- Finance no longer reads the jobs table directly. Reports below expose only
-- the fields required for reconciliation, avoiding brief/reference disclosure.
drop policy if exists jobs_finance_acc_read on public.jobs;
revoke all on function public.finance_acc_recipients() from public, anon, authenticated;
revoke all on function public.finance_acc_approval_times() from public, anon, authenticated;

create table public.freelancer_payment_records (
  id uuid primary key default gen_random_uuid(),
  recipient_profile_id uuid not null,
  recipient_label text not null,
  snapshot_bank_name text,
  snapshot_account_number text,
  snapshot_account_holder text,
  amount bigint not null check (amount > 0),
  paid_at timestamptz not null,
  bank_reference text not null check (char_length(btrim(bank_reference)) between 1 and 120),
  proof_path text not null,
  note text not null default '' check (char_length(note) <= 1000),
  status text not null default 'posted' check (status in ('posted', 'voided')),
  recorded_by_profile_id uuid references public.profiles(id) on delete set null,
  recorded_at timestamptz not null default now(),
  voided_by_profile_id uuid references public.profiles(id) on delete set null,
  voided_at timestamptz,
  void_reason text,
  constraint freelancer_payment_records_void_check check (
    (status = 'posted' and voided_at is null and voided_by_profile_id is null and void_reason is null)
    or (status = 'voided' and voided_at is not null and void_reason is not null)
  )
);

create unique index freelancer_payment_records_reference_unique
  on public.freelancer_payment_records (recipient_profile_id, lower(btrim(bank_reference)));
create unique index freelancer_payment_records_proof_path_unique
  on public.freelancer_payment_records (proof_path);
create index freelancer_payment_records_paid_at_idx
  on public.freelancer_payment_records (paid_at desc, id desc);
create index freelancer_payment_records_recipient_idx
  on public.freelancer_payment_records (recipient_profile_id, paid_at desc);

create table public.freelancer_payment_allocations (
  id uuid primary key default gen_random_uuid(),
  payment_record_id uuid not null references public.freelancer_payment_records(id) on delete restrict,
  job_id text not null references public.jobs(id) on delete restrict,
  amount bigint not null check (amount > 0),
  created_at timestamptz not null default now(),
  unique (payment_record_id, job_id)
);
create index freelancer_payment_allocations_job_idx on public.freelancer_payment_allocations (job_id);

create table public.freelancer_payment_events (
  id uuid primary key default gen_random_uuid(),
  payment_record_id uuid references public.freelancer_payment_records(id) on delete restrict,
  target_profile_id uuid,
  actor_profile_id uuid references public.profiles(id) on delete set null,
  event_type text not null check (event_type in (
    'payment_recorded', 'payment_voided', 'payment_proof_viewed', 'bank_details_viewed'
  )),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.freelancer_payment_events
  drop constraint if exists freelancer_payment_events_event_type_check;
alter table public.freelancer_payment_events
  add constraint freelancer_payment_events_event_type_check check (event_type in (
    'payment_recorded', 'payment_voided', 'payment_proof_viewed', 'bank_details_viewed',
    'payment_schedule_updated'
  ));
create index freelancer_payment_events_record_idx
  on public.freelancer_payment_events (payment_record_id, created_at desc);

create or replace function public.log_freelancer_payment_schedule_change()
returns trigger language plpgsql security definer set search_path = public, auth as $$
begin
  insert into public.freelancer_payment_events(target_profile_id, actor_profile_id, event_type, details)
  values (
    new.profile_id,
    coalesce(new.updated_by_profile_id, auth.uid()),
    'payment_schedule_updated',
    jsonb_build_object(
      'before', case when tg_op = 'INSERT' then jsonb_build_object('payout_frequency', 'per_job')
        else jsonb_build_object('payout_frequency', old.payout_frequency, 'payout_method', old.payout_method) end,
      'after', jsonb_build_object('payout_frequency', new.payout_frequency, 'payout_method', new.payout_method)
    )
  );
  return new;
end $$;
drop trigger if exists trg_log_freelancer_payment_schedule_change on public.freelancer_payment_settings;
create trigger trg_log_freelancer_payment_schedule_change after insert or update on public.freelancer_payment_settings
  for each row execute function public.log_freelancer_payment_schedule_change();

alter table public.freelancer_payment_records enable row level security;
alter table public.freelancer_payment_allocations enable row level security;
alter table public.freelancer_payment_events enable row level security;
revoke all on public.freelancer_payment_records, public.freelancer_payment_allocations,
  public.freelancer_payment_events from public, anon, authenticated;
grant all on public.freelancer_payment_records, public.freelancer_payment_allocations,
  public.freelancer_payment_events to service_role;

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('finance-payment-proofs', 'finance-payment-proofs', false, 10485760,
  array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = 10485760,
  allowed_mime_types = excluded.allowed_mime_types;

create or replace function public.finance_payment_proof_is_linked(p_path text)
returns boolean language sql stable security definer set search_path = public as $$
  select case
    when not (public.is_finance() or public.is_super_admin())
      or split_part(p_path, '/', 1) <> auth.uid()::text then true
    else exists (select 1 from public.freelancer_payment_records r where r.proof_path = p_path)
  end
$$;

create or replace function public.finance_payment_proof_is_audited(p_path text)
returns boolean language sql stable security definer set search_path = public as $$
  select (public.is_finance() or public.is_super_admin()) and exists (
    select 1
    from public.freelancer_payment_records r
    join public.freelancer_payment_events e on e.payment_record_id = r.id
    where r.proof_path = p_path
      and e.event_type = 'payment_proof_viewed'
      and e.actor_profile_id = auth.uid()
      and e.created_at >= now() - interval '5 minutes'
  )
$$;
revoke all on function public.finance_payment_proof_is_audited(text) from public, anon;
grant execute on function public.finance_payment_proof_is_audited(text) to authenticated, service_role;

drop policy if exists finance_payment_proof_read on storage.objects;
create policy finance_payment_proof_read on storage.objects for select to authenticated
  using (bucket_id = 'finance-payment-proofs' and public.finance_payment_proof_is_audited(name));
drop policy if exists finance_payment_proof_insert on storage.objects;
create policy finance_payment_proof_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'finance-payment-proofs'
    and (public.is_finance() or public.is_super_admin())
    and split_part(name, '/', 1) = auth.uid()::text);
drop policy if exists finance_payment_proof_delete on storage.objects;
create policy finance_payment_proof_delete on storage.objects for delete to authenticated
  using (bucket_id = 'finance-payment-proofs'
    and (public.is_finance() or public.is_super_admin())
    and split_part(name, '/', 1) = auth.uid()::text
    and not public.finance_payment_proof_is_linked(name));

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
  update public.jobs set status = 'Finished', finished_at = now(), revision = revision + 1 where id = p_job;
  insert into public.job_events(job_id, actor_profile_id, event_type, from_status, to_status, details)
  values (p_job, public.my_uid(), 'finish', 'ACC', 'Finished', jsonb_build_object('final_file_ids', v_final_files));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.finance_monthly_payment_report(p_month date)
returns table(
  profile_id uuid,
  profile_name text,
  opening_balance bigint,
  earned_this_month bigint,
  paid_this_month bigint,
  closing_balance bigint,
  jobs_finished_this_month bigint
)
language plpgsql stable security definer set search_path = public as $$
declare v_month date; v_start timestamptz; v_end timestamptz;
begin
  if not (public.is_finance() or public.is_super_admin()) then
    raise exception 'FORBIDDEN: hanya Finance yang dapat melihat laporan pembayaran';
  end if;
  if p_month is null then raise exception 'Pilih bulan laporan'; end if;
  v_month := date_trunc('month', p_month)::date;
  v_start := v_month::timestamp at time zone 'Asia/Jakarta';
  v_end := (v_month + interval '1 month')::timestamp at time zone 'Asia/Jakarta';
  return query
    with recipient_sources as (
      select p.id, p.name from public.profiles p
      where p.role = 'freelance' and p.registration_status = 'approved'
      union all
      select r.recipient_profile_id, r.recipient_label from public.freelancer_payment_records r
      union all
      select coalesce(j.approved_for_profile_id, j.assignee_profile_id),
        coalesce(max(p.name), coalesce(j.approved_for_profile_id, j.assignee_profile_id)::text)
      from public.jobs j
      left join public.profiles p on p.id = coalesce(j.approved_for_profile_id, j.assignee_profile_id)
      where j.status = 'Finished' and coalesce(j.approved_for_profile_id, j.assignee_profile_id) is not null
      group by coalesce(j.approved_for_profile_id, j.assignee_profile_id)
    ), recipients as (
      select source.id, coalesce(max(profile.name), max(source.name), source.id::text) as name
      from recipient_sources source
      left join public.profiles profile on profile.id = source.id
      group by source.id
    ), earned as (
      select coalesce(j.approved_for_profile_id, j.assignee_profile_id) as recipient_id,
        coalesce(sum(coalesce(j.approved_fee, j.fee)), 0)::bigint as total,
        count(*)::bigint as job_count
      from public.jobs j
      where j.status = 'Finished' and j.finished_at >= v_start and j.finished_at < v_end
      group by coalesce(j.approved_for_profile_id, j.assignee_profile_id)
    ), earned_before as (
      select coalesce(j.approved_for_profile_id, j.assignee_profile_id) as recipient_id,
        coalesce(sum(coalesce(j.approved_fee, j.fee)), 0)::bigint as total
      from public.jobs j where j.status = 'Finished' and j.finished_at < v_start
      group by coalesce(j.approved_for_profile_id, j.assignee_profile_id)
    ), paid as (
      select r.recipient_profile_id as recipient_id,
        coalesce(sum(case when r.paid_at >= v_start and r.paid_at < v_end then r.amount else 0 end)
          - sum(case when r.voided_at >= v_start and r.voided_at < v_end then r.amount else 0 end), 0)::bigint as total
      from public.freelancer_payment_records r
      where (r.paid_at >= v_start and r.paid_at < v_end)
        or (r.voided_at >= v_start and r.voided_at < v_end)
      group by r.recipient_profile_id
    ), paid_before as (
      select r.recipient_profile_id as recipient_id,
        coalesce(sum(case when r.paid_at < v_start then r.amount else 0 end)
          - sum(case when r.voided_at < v_start then r.amount else 0 end), 0)::bigint as total
      from public.freelancer_payment_records r
      where r.paid_at < v_start or r.voided_at < v_start
      group by r.recipient_profile_id
    )
    select rec.id, rec.name,
      coalesce(eb.total, 0) - coalesce(pb.total, 0),
      coalesce(e.total, 0), coalesce(pd.total, 0),
      coalesce(eb.total, 0) - coalesce(pb.total, 0) + coalesce(e.total, 0) - coalesce(pd.total, 0),
      coalesce(e.job_count, 0)
    from recipients rec
    left join earned e on e.recipient_id = rec.id
    left join earned_before eb on eb.recipient_id = rec.id
    left join paid pd on pd.recipient_id = rec.id
    left join paid_before pb on pb.recipient_id = rec.id
    order by rec.name, rec.id;
end $$;

create or replace function public.finance_monthly_jobs(
  p_month date, p_profile uuid, p_limit int default 50, p_offset int default 0
)
returns table(
  job_id text, team_name text, job_type public.job_type, finished_at timestamptz,
  earned_fee bigint, paid_amount bigint, due_amount bigint, total_rows bigint
)
language plpgsql stable security definer set search_path = public as $$
declare v_month date; v_start timestamptz; v_end timestamptz;
begin
  if not (public.is_finance() or public.is_super_admin()) then
    raise exception 'FORBIDDEN: hanya Finance yang dapat melihat rincian fee bulanan';
  end if;
  if p_month is null or p_profile is null or p_limit < 1 or p_limit > 100
    or p_offset < 0 or p_offset > 100000 then
    raise exception 'Parameter rincian fee bulanan tidak valid';
  end if;
  v_month := date_trunc('month', p_month)::date;
  v_start := v_month::timestamp at time zone 'Asia/Jakarta';
  v_end := (v_month + interval '1 month')::timestamp at time zone 'Asia/Jakarta';
  return query
    with balances as (
      select j.id, j.tim, j.jenis, j.finished_at,
        coalesce(j.approved_fee, j.fee)::bigint as earned,
        coalesce(sum(a.amount) filter (where r.status = 'posted'), 0)::bigint as paid
      from public.jobs j
      left join public.freelancer_payment_allocations a on a.job_id = j.id
      left join public.freelancer_payment_records r on r.id = a.payment_record_id
      where j.status = 'Finished' and j.finished_at >= v_start and j.finished_at < v_end
        and coalesce(j.approved_for_profile_id, j.assignee_profile_id) = p_profile
      group by j.id
    )
    select b.id, b.tim, b.jenis, b.finished_at, b.earned, b.paid,
      (b.earned - b.paid)::bigint, count(*) over()::bigint
    from balances b
    order by b.finished_at, b.id
    limit p_limit offset p_offset;
end $$;

create or replace function public.finance_unpaid_jobs(
  p_profile uuid, p_limit int default 50, p_offset int default 0
)
returns table(
  job_id text, team_name text, job_type public.job_type, finished_at timestamptz,
  earned_fee bigint, paid_amount bigint, due_amount bigint, total_rows bigint
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.is_finance() or public.is_super_admin()) then
    raise exception 'FORBIDDEN: hanya Finance yang dapat melihat rincian pembayaran';
  end if;
  if p_profile is null or p_limit < 1 or p_limit > 100 or p_offset < 0 or p_offset > 100000 then
    raise exception 'Parameter halaman rincian pembayaran tidak valid';
  end if;
  return query
    with balances as (
      select j.id, j.tim, j.jenis, j.finished_at,
        coalesce(j.approved_fee, j.fee)::bigint as earned,
        coalesce(sum(a.amount) filter (where r.status = 'posted'), 0)::bigint as paid
      from public.jobs j
      left join public.freelancer_payment_allocations a on a.job_id = j.id
      left join public.freelancer_payment_records r on r.id = a.payment_record_id
      where j.status = 'Finished'
        and coalesce(j.approved_for_profile_id, j.assignee_profile_id) = p_profile
      group by j.id
    ), due as (
      select b.*, (b.earned - b.paid)::bigint as remaining
      from balances b where b.earned > b.paid
    )
    select d.id, d.tim, d.jenis, d.finished_at, d.earned, d.paid, d.remaining,
      count(*) over()::bigint
    from due d
    order by d.finished_at, d.id
    limit p_limit offset p_offset;
end $$;

create or replace function public.finance_payment_history(
  p_month date, p_limit int default 50, p_offset int default 0
)
returns table(
  payment_id uuid, recipient_profile_id uuid, recipient_name text,
  bank_name text, account_number_last4 text, account_holder text, amount bigint,
  paid_at timestamptz, bank_reference text, note text, proof_path text, status text,
  recorded_by text, recorded_at timestamptz, voided_by text, voided_at timestamptz,
  void_reason text, allocations jsonb, total_rows bigint
)
language plpgsql stable security definer set search_path = public as $$
declare v_month date; v_start timestamptz; v_end timestamptz;
begin
  if not (public.is_finance() or public.is_super_admin()) then
    raise exception 'FORBIDDEN: hanya Finance yang dapat melihat histori pembayaran';
  end if;
  if p_month is null or p_limit < 1 or p_limit > 100 or p_offset < 0 or p_offset > 100000 then
    raise exception 'Parameter halaman histori pembayaran tidak valid';
  end if;
  v_month := date_trunc('month', p_month)::date;
  v_start := v_month::timestamp at time zone 'Asia/Jakarta';
  v_end := (v_month + interval '1 month')::timestamp at time zone 'Asia/Jakarta';
  return query
    select r.id, r.recipient_profile_id, r.recipient_label,
      r.snapshot_bank_name, right(r.snapshot_account_number, 4), r.snapshot_account_holder,
      r.amount, r.paid_at,
      r.bank_reference, r.note, r.proof_path, r.status,
      coalesce(actor.name, 'akun nonaktif'), r.recorded_at,
      voider.name, r.voided_at, r.void_reason,
      coalesce((
        select jsonb_agg(jsonb_build_object(
          'job_id', a.job_id, 'team_name', j.tim, 'amount', a.amount
        ) order by j.finished_at, a.job_id)
        from public.freelancer_payment_allocations a
        join public.jobs j on j.id = a.job_id
        where a.payment_record_id = r.id
      ), '[]'::jsonb), count(*) over()::bigint
    from public.freelancer_payment_records r
    left join public.profiles actor on actor.id = r.recorded_by_profile_id
    left join public.profiles voider on voider.id = r.voided_by_profile_id
    where r.paid_at >= v_start and r.paid_at < v_end
    order by r.paid_at desc, r.recorded_at desc, r.id
    limit p_limit offset p_offset;
end $$;

create or replace function public.finance_payment_audit_log(
  p_month date, p_limit int default 100, p_offset int default 0
)
returns table(
  event_id uuid, payment_record_id uuid, target_profile_id uuid, target_name text,
  actor_name text, event_type text, details jsonb, created_at timestamptz, total_rows bigint
)
language plpgsql stable security definer set search_path = public as $$
declare v_month date; v_start timestamptz; v_end timestamptz;
begin
  if not (public.is_finance() or public.is_super_admin()) then
    raise exception 'FORBIDDEN: hanya Finance yang dapat melihat audit pembayaran';
  end if;
  if p_month is null or p_limit < 1 or p_limit > 200 or p_offset < 0 or p_offset > 100000 then
    raise exception 'Parameter halaman audit pembayaran tidak valid';
  end if;
  v_month := date_trunc('month', p_month)::date;
  v_start := v_month::timestamp at time zone 'Asia/Jakarta';
  v_end := (v_month + interval '1 month')::timestamp at time zone 'Asia/Jakarta';
  return query
    select e.id, e.payment_record_id, e.target_profile_id,
      coalesce(target.name, r.recipient_label, 'akun dihapus'),
      coalesce(actor.name, 'akun nonaktif'), e.event_type, e.details, e.created_at,
      count(*) over()::bigint
    from public.freelancer_payment_events e
    left join public.profiles target on target.id = e.target_profile_id
    left join public.freelancer_payment_records r on r.id = e.payment_record_id
    left join public.profiles actor on actor.id = e.actor_profile_id
    where e.created_at >= v_start and e.created_at < v_end
    order by e.created_at desc, e.id
    limit p_limit offset p_offset;
end $$;

create or replace function public.finance_freelancer_payment_settings()
returns table(
  profile_id uuid,
  profile_name text,
  is_active boolean,
  payout_frequency text,
  payout_method text,
  bank_name text,
  account_number text,
  account_holder text,
  updated_at timestamptz
)
language sql stable security definer set search_path = public as $$
  select p.id, p.name, p.is_active,
    coalesce(s.payout_frequency, 'per_job'), coalesce(s.payout_method, 'bank_transfer'),
    b.bank_name,
    case when b.account_number is null then null else '•••• ' || right(b.account_number, 4) end,
    b.account_holder, s.updated_at
  from public.profiles p
  left join public.freelancer_payment_settings s on s.profile_id = p.id
  left join public.freelancer_bank_accounts b on b.profile_id = p.id
  where (public.is_finance() or public.is_super_admin())
    and p.role = 'freelance' and p.registration_status = 'approved'
  order by p.name, p.id
$$;

create or replace function public.finance_freelancer_bank_account(p_profile uuid)
returns table(bank_name text, account_number text, account_holder text)
language plpgsql security definer set search_path = public as $$
begin
  if not (public.is_finance() or public.is_super_admin()) then
    raise exception 'FORBIDDEN: hanya Finance yang dapat melihat rekening pembayaran';
  end if;
  return query
    select b.bank_name, b.account_number, b.account_holder
    from public.freelancer_bank_accounts b join public.profiles p on p.id = b.profile_id
    where b.profile_id = p_profile and p.role = 'freelance'
      and (
        p.registration_status = 'approved'
        or exists (
          select 1 from public.jobs j
          where j.status = 'Finished'
            and coalesce(j.approved_for_profile_id, j.assignee_profile_id) = p.id
        )
        or exists (
          select 1 from public.freelancer_payment_records r where r.recipient_profile_id = p.id
        )
      );
  if found then
    insert into public.freelancer_payment_events(target_profile_id, actor_profile_id, event_type)
    values (p_profile, auth.uid(), 'bank_details_viewed');
  end if;
end $$;

create or replace function public.record_freelancer_payment(
  p_recipient uuid,
  p_paid_at timestamptz,
  p_bank_reference text,
  p_note text,
  p_proof_path text,
  p_allocations jsonb
) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  v_recipient public.profiles%rowtype;
  v_bank public.freelancer_bank_accounts%rowtype;
  v_actor uuid := auth.uid();
  v_payment_id uuid;
  v_item jsonb;
  v_job public.jobs%rowtype;
  v_job_id text;
  v_amount bigint;
  v_total bigint := 0;
  v_previous_paid bigint;
  v_job_fee bigint;
  v_allocations_count int;
  v_distinct_jobs int;
begin
  if not (public.is_finance() or public.is_super_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Hanya Finance yang dapat mencatat pembayaran.');
  end if;
  if p_paid_at is null or p_paid_at > now() + interval '5 minutes' then
    return jsonb_build_object('ok', false, 'error', 'Tanggal pembayaran tidak valid.');
  end if;
  if nullif(btrim(coalesce(p_bank_reference, '')), '') is null or char_length(btrim(p_bank_reference)) > 120 then
    return jsonb_build_object('ok', false, 'error', 'Nomor referensi transfer wajib diisi (maksimal 120 karakter).');
  end if;
  if char_length(coalesce(p_note, '')) > 1000 then
    return jsonb_build_object('ok', false, 'error', 'Catatan maksimal 1.000 karakter.');
  end if;
  if p_proof_path is null or split_part(p_proof_path, '/', 1) <> v_actor::text
    or not exists (
      select 1 from storage.objects o where o.bucket_id = 'finance-payment-proofs' and o.name = p_proof_path
    ) then
    return jsonb_build_object('ok', false, 'error', 'Bukti transfer belum diunggah dengan benar.');
  end if;
  if p_allocations is null or jsonb_typeof(p_allocations) is distinct from 'array' then
    return jsonb_build_object('ok', false, 'error', 'Pilih minimal satu job untuk alokasi pembayaran.');
  end if;
  v_allocations_count := jsonb_array_length(p_allocations);
  if v_allocations_count < 1 or v_allocations_count > 100 then
    return jsonb_build_object('ok', false, 'error', 'Satu transfer harus dialokasikan ke 1–100 job.');
  end if;
  select count(distinct value->>'job_id') into v_distinct_jobs
  from jsonb_array_elements(p_allocations);
  if v_distinct_jobs <> v_allocations_count then
    return jsonb_build_object('ok', false, 'error', 'Job yang sama tidak boleh dipilih lebih dari satu kali.');
  end if;
  for v_item in select value from jsonb_array_elements(p_allocations) loop
    v_job_id := nullif(v_item->>'job_id', '');
    if v_job_id is null or coalesce(v_item->>'amount', '') !~ '^[0-9]+$' then
      return jsonb_build_object('ok', false, 'error', 'Rincian alokasi tidak valid.');
    end if;
    v_amount := (v_item->>'amount')::bigint;
    if v_amount <= 0 then
      return jsonb_build_object('ok', false, 'error', 'Nilai alokasi harus lebih dari nol.');
    end if;
    v_total := v_total + v_amount;
  end loop;
  if v_total <= 0 then
    return jsonb_build_object('ok', false, 'error', 'Nilai transfer harus lebih dari nol.');
  end if;

  select * into v_recipient from public.profiles where id = p_recipient for share;
  if not found or v_recipient.role <> 'freelance' then
    return jsonb_build_object('ok', false, 'error', 'Freelancer penerima tidak ditemukan.');
  end if;
  select * into v_bank from public.freelancer_bank_accounts where profile_id = p_recipient for share;

  -- Lock jobs in a stable order so concurrent Finance entries cannot overpay a job.
  perform j.id
  from public.jobs j
  where j.id in (select value->>'job_id' from jsonb_array_elements(p_allocations))
  order by j.id
  for update of j;

  for v_item in select value from jsonb_array_elements(p_allocations) loop
    v_job_id := v_item->>'job_id';
    v_amount := (v_item->>'amount')::bigint;
    select * into v_job from public.jobs where id = v_job_id;
    if not found or v_job.status <> 'Finished'
      or coalesce(v_job.approved_for_profile_id, v_job.assignee_profile_id) is distinct from p_recipient then
      return jsonb_build_object('ok', false, 'error', 'Semua alokasi harus mengarah ke job Finished milik freelancer tersebut.');
    end if;
    v_job_fee := coalesce(v_job.approved_fee, v_job.fee);
    select coalesce(sum(a.amount), 0) into v_previous_paid
    from public.freelancer_payment_allocations a
    join public.freelancer_payment_records r on r.id = a.payment_record_id
    where a.job_id = v_job_id and r.status = 'posted';
    if v_previous_paid + v_amount > v_job_fee then
      return jsonb_build_object('ok', false, 'error', 'Alokasi melebihi sisa fee job ' || v_job_id || '.');
    end if;
  end loop;

  insert into public.freelancer_payment_records(
    recipient_profile_id, recipient_label, snapshot_bank_name, snapshot_account_number,
    snapshot_account_holder, amount, paid_at, bank_reference, proof_path, note, recorded_by_profile_id
  ) values (
    p_recipient, v_recipient.name, v_bank.bank_name, v_bank.account_number, v_bank.account_holder,
    v_total, p_paid_at, btrim(p_bank_reference), p_proof_path, btrim(coalesce(p_note, '')), v_actor
  ) returning id into v_payment_id;

  insert into public.freelancer_payment_allocations(payment_record_id, job_id, amount)
  select v_payment_id, x.job_id, x.amount
  from jsonb_to_recordset(p_allocations) as x(job_id text, amount bigint);

  insert into public.freelancer_payment_events(payment_record_id, target_profile_id, actor_profile_id, event_type, details)
  values (v_payment_id, p_recipient, v_actor, 'payment_recorded',
    jsonb_build_object('amount', v_total, 'bank_reference', btrim(p_bank_reference), 'allocation_count', v_allocations_count));
  return jsonb_build_object('ok', true, 'payment_id', v_payment_id, 'amount', v_total);
exception when unique_violation then
  return jsonb_build_object('ok', false, 'error', 'Nomor referensi transfer ini sudah pernah dicatat untuk freelancer tersebut.');
end $$;

create or replace function public.void_freelancer_payment(p_payment uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare v_record public.freelancer_payment_records%rowtype;
begin
  if not (public.is_finance() or public.is_super_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Hanya Finance yang dapat membatalkan pencatatan pembayaran.');
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null or char_length(btrim(p_reason)) > 1000 then
    return jsonb_build_object('ok', false, 'error', 'Alasan pembatalan wajib diisi (maksimal 1.000 karakter).');
  end if;
  select * into v_record from public.freelancer_payment_records where id = p_payment for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Pembayaran tidak ditemukan.'); end if;
  if v_record.status <> 'posted' then return jsonb_build_object('ok', false, 'error', 'Pembayaran ini sudah dibatalkan.'); end if;
  update public.freelancer_payment_records set status = 'voided', voided_by_profile_id = auth.uid(),
    voided_at = now(), void_reason = btrim(p_reason) where id = p_payment;
  insert into public.freelancer_payment_events(payment_record_id, target_profile_id, actor_profile_id, event_type, details)
  values (p_payment, v_record.recipient_profile_id, auth.uid(), 'payment_voided',
    jsonb_build_object('reason', btrim(p_reason), 'amount', v_record.amount));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.finance_log_payment_proof_view(p_payment uuid)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare v_record public.freelancer_payment_records%rowtype;
begin
  if not (public.is_finance() or public.is_super_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Hanya Finance yang dapat membuka bukti pembayaran.');
  end if;
  select * into v_record from public.freelancer_payment_records where id = p_payment;
  if not found then return jsonb_build_object('ok', false, 'error', 'Pembayaran tidak ditemukan.'); end if;
  insert into public.freelancer_payment_events(payment_record_id, target_profile_id, actor_profile_id, event_type)
  values (p_payment, v_record.recipient_profile_id, auth.uid(), 'payment_proof_viewed');
  return jsonb_build_object('ok', true, 'proof_path', v_record.proof_path);
end $$;

revoke all on function public.finance_monthly_payment_report(date) from public, anon;
revoke all on function public.finance_monthly_jobs(date, uuid, int, int) from public, anon;
revoke all on function public.finance_unpaid_jobs(uuid, int, int) from public, anon;
revoke all on function public.finance_payment_history(date, int, int) from public, anon;
revoke all on function public.finance_payment_audit_log(date, int, int) from public, anon;
revoke all on function public.finance_freelancer_payment_settings() from public, anon;
revoke all on function public.finance_freelancer_bank_account(uuid) from public, anon;
revoke all on function public.record_freelancer_payment(uuid, timestamptz, text, text, text, jsonb) from public, anon;
revoke all on function public.void_freelancer_payment(uuid, text) from public, anon;
revoke all on function public.finance_log_payment_proof_view(uuid) from public, anon;
revoke all on function public.finance_payment_proof_is_linked(text) from public, anon;
revoke all on function public.finance_payment_proof_is_audited(text) from public, anon;
grant execute on function public.finance_monthly_payment_report(date) to authenticated, service_role;
grant execute on function public.finance_monthly_jobs(date, uuid, int, int) to authenticated, service_role;
grant execute on function public.finance_unpaid_jobs(uuid, int, int) to authenticated, service_role;
grant execute on function public.finance_payment_history(date, int, int) to authenticated, service_role;
grant execute on function public.finance_payment_audit_log(date, int, int) to authenticated, service_role;
grant execute on function public.finance_freelancer_payment_settings() to authenticated, service_role;
grant execute on function public.finance_freelancer_bank_account(uuid) to authenticated, service_role;
grant execute on function public.record_freelancer_payment(uuid, timestamptz, text, text, text, jsonb) to authenticated, service_role;
grant execute on function public.void_freelancer_payment(uuid, text) to authenticated, service_role;
grant execute on function public.finance_log_payment_proof_view(uuid) to authenticated, service_role;
grant execute on function public.finance_payment_proof_is_linked(text) to authenticated, service_role;
grant execute on function public.finance_payment_proof_is_audited(text) to authenticated, service_role;
revoke all on function public.log_freelancer_payment_schedule_change() from public, anon, authenticated;
revoke all on function public.guard_job_finished_at() from public, anon, authenticated;
