-- Finance records manual freelancer transfers in an immutable, job-allocated ledger.
-- Fee becomes payable when the original CDR is delivered and the job becomes Finished.

alter table public.jobs add column finished_at timestamptz;

update public.jobs j
set finished_at = coalesce(
  (select max(e.created_at) from public.job_events e where e.job_id = j.id and e.event_type = 'finish'),
  j.created_at
)
where j.status = 'Finished' and j.finished_at is null;

create or replace function public.set_job_finished_at() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and OLD.finished_at is not null
     and NEW.finished_at is distinct from OLD.finished_at then
    raise exception 'FORBIDDEN: tanggal job Finished terkunci';
  end if;
  if NEW.status = 'Finished' and NEW.finished_at is null then
    NEW.finished_at := now();
  end if;
  return NEW;
end $$;

drop trigger if exists trg_job_finished_at on public.jobs;
create trigger trg_job_finished_at before insert or update on public.jobs
  for each row execute function public.set_job_finished_at();

create index if not exists jobs_finished_at_profile_idx
  on public.jobs(approved_for_profile_id, finished_at) where status = 'Finished';

-- Move client/job design notes out of the Finance-readable job row. Finance
-- receives all recap data through the narrow, role-checked RPCs below.
create table public.job_private_details (
  job_id text primary key references public.jobs(id) on delete cascade,
  brief text not null default '-',
  ref text
);

insert into public.job_private_details(job_id, brief, ref)
select id, brief, ref from public.jobs;

alter table public.jobs drop column brief;
alter table public.jobs drop column ref;

alter table public.job_private_details enable row level security;
revoke all on public.job_private_details from public, anon, authenticated;
grant select, insert, update, delete on public.job_private_details to authenticated;

create policy job_private_details_admin_all on public.job_private_details for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy job_private_details_freelance_read on public.job_private_details for select to authenticated
  using (public.is_freelance() and exists (
    select 1 from public.jobs j
    where j.id = job_id and j.assignee_profile_id = public.my_uid()
  ));

create or replace function public.create_job(
  p_tim text, p_jenis job_type, p_qty int, p_deadline timestamptz,
  p_fee bigint, p_priority job_priority, p_brief text, p_ref text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id text;
  v_number bigint;
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'Hanya Admin'); end if;
  if p_qty < 1 then return jsonb_build_object('ok', false, 'error', 'Qty minimal 1'); end if;
  if p_fee < 0 then return jsonb_build_object('ok', false, 'error', 'Fee tidak valid'); end if;

  v_number := nextval('public.threadline_job_seq');
  v_id := 'TRD-' || lpad(v_number::text, greatest(4, length(v_number::text)), '0');

  insert into public.jobs(id, tim, jenis, qty, deadline, fee, priority)
  values (v_id, nullif(trim(p_tim), ''), p_jenis, p_qty, p_deadline, p_fee, p_priority);
  insert into public.job_private_details(job_id, brief, ref)
  values (v_id, coalesce(nullif(trim(p_brief), ''), '-'), nullif(trim(coalesce(p_ref, '')), ''));
  insert into public.job_events(job_id, actor_profile_id, event_type, to_status)
  values (v_id, public.my_uid(), 'create', 'Belum Ditugaskan');
  return jsonb_build_object('ok', true, 'id', v_id);
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
    priority = coalesce(p_priority, priority), revision = revision + 1 where id = p_job;
  update public.job_private_details set
    brief = coalesce(nullif(trim(p_brief), ''), brief),
    ref = coalesce(p_ref, ref)
  where job_id = p_job;
  return jsonb_build_object('ok', true);
end $$;

-- Remove the row-level Finance policy. Finance reads narrowly-scoped reports
-- through SECURITY DEFINER functions, never directly from public.jobs.
drop policy if exists jobs_finance_acc_read on public.jobs;

create table public.freelancer_payment_records (
  id uuid primary key default gen_random_uuid(),
  recipient_profile_id uuid not null references public.profiles(id) on delete restrict,
  amount bigint not null check (amount > 0),
  paid_at timestamptz not null,
  bank_reference text not null check (char_length(btrim(bank_reference)) between 2 and 120),
  proof_path text not null unique,
  note text,
  status text not null default 'posted' check (status in ('posted', 'voided')),
  recorded_by_profile_id uuid not null references public.profiles(id) on delete restrict,
  recorded_at timestamptz not null default now(),
  voided_at timestamptz,
  voided_by_profile_id uuid references public.profiles(id) on delete restrict,
  void_reason text,
  constraint freelancer_payment_records_void_fields check (
    (status = 'posted' and voided_at is null and voided_by_profile_id is null and void_reason is null)
    or (status = 'voided' and voided_at is not null and voided_by_profile_id is not null and nullif(btrim(void_reason), '') is not null)
  )
);

create unique index freelancer_payment_reference_unique
  on public.freelancer_payment_records(recipient_profile_id, lower(btrim(bank_reference)));
create index freelancer_payment_month_idx
  on public.freelancer_payment_records(paid_at desc, id desc);
create index freelancer_payment_recipient_idx
  on public.freelancer_payment_records(recipient_profile_id, paid_at desc);

create table public.freelancer_payment_allocations (
  id uuid primary key default gen_random_uuid(),
  payment_record_id uuid not null references public.freelancer_payment_records(id) on delete restrict,
  job_id text not null references public.jobs(id) on delete restrict,
  amount bigint not null check (amount > 0),
  unique (payment_record_id, job_id)
);
create index freelancer_payment_allocations_job_idx on public.freelancer_payment_allocations(job_id);

create table public.freelancer_payment_events (
  id uuid primary key default gen_random_uuid(),
  payment_record_id uuid references public.freelancer_payment_records(id) on delete restrict,
  recipient_profile_id uuid not null references public.profiles(id) on delete restrict,
  event_type text not null check (event_type in (
    'payment_recorded', 'payment_voided', 'payment_proof_viewed', 'bank_details_viewed'
  )),
  actor_profile_id uuid not null references public.profiles(id) on delete restrict,
  reason text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index freelancer_payment_events_created_idx on public.freelancer_payment_events(created_at desc);
create index freelancer_payment_events_payment_idx on public.freelancer_payment_events(payment_record_id, created_at);

alter table public.freelancer_payment_records enable row level security;
alter table public.freelancer_payment_allocations enable row level security;
alter table public.freelancer_payment_events enable row level security;
revoke all on public.freelancer_payment_records, public.freelancer_payment_allocations, public.freelancer_payment_events from public, anon, authenticated;
grant select on public.freelancer_payment_records, public.freelancer_payment_allocations, public.freelancer_payment_events to authenticated;

create policy freelancer_payment_records_read on public.freelancer_payment_records for select to authenticated
  using (public.is_finance() or public.is_super_admin());
create policy freelancer_payment_allocations_read on public.freelancer_payment_allocations for select to authenticated
  using (public.is_finance() or public.is_super_admin());
create policy freelancer_payment_events_read on public.freelancer_payment_events for select to authenticated
  using (public.is_finance() or public.is_super_admin());

insert into storage.buckets(id, name, public, file_size_limit)
values ('payment-proofs', 'payment-proofs', false, 10485760)
on conflict (id) do update set public = false, file_size_limit = 10485760;

drop policy if exists finance_payment_proofs_read on storage.objects;
create policy finance_payment_proofs_read on storage.objects for select to authenticated
  using (bucket_id = 'payment-proofs' and (public.is_finance() or public.is_super_admin()));
drop policy if exists finance_payment_proofs_insert on storage.objects;
create policy finance_payment_proofs_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'payment-proofs'
    and (public.is_finance() or public.is_super_admin())
    and split_part(name, '/', 1) = auth.uid()::text
  );
drop policy if exists finance_payment_proofs_delete_unlinked on storage.objects;
create policy finance_payment_proofs_delete_unlinked on storage.objects for delete to authenticated
  using (
    bucket_id = 'payment-proofs'
    and (public.is_finance() or public.is_super_admin())
    and split_part(name, '/', 1) = auth.uid()::text
    and not exists (
      select 1 from public.freelancer_payment_records p where p.proof_path = name
    )
  );

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
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not (public.is_finance() or public.is_super_admin()) then
    raise exception 'FORBIDDEN: laporan pembayaran hanya untuk Finance';
  end if;

  return query
  with bounds as (
    select date_trunc('month', p_month::timestamp) at time zone 'Asia/Jakarta' as month_start,
      (date_trunc('month', p_month::timestamp) + interval '1 month') at time zone 'Asia/Jakarta' as month_end
  ), earned as (
    select j.approved_for_profile_id as recipient_id,
      coalesce(sum(coalesce(j.approved_fee, j.fee)) filter (where j.finished_at < b.month_start), 0)::bigint as before_month,
      coalesce(sum(coalesce(j.approved_fee, j.fee)) filter (where j.finished_at >= b.month_start and j.finished_at < b.month_end), 0)::bigint as in_month,
      count(*) filter (where j.finished_at >= b.month_start and j.finished_at < b.month_end)::bigint as jobs_in_month
    from public.jobs j cross join bounds b
    where j.status = 'Finished' and j.approved_for_profile_id is not null
    group by j.approved_for_profile_id
  ), paid as (
    select p.recipient_profile_id as recipient_id,
      coalesce(sum(a.amount) filter (where p.paid_at < b.month_start), 0)::bigint as before_month,
      coalesce(sum(a.amount) filter (where p.paid_at >= b.month_start and p.paid_at < b.month_end), 0)::bigint as in_month
    from public.freelancer_payment_records p
    join public.freelancer_payment_allocations a on a.payment_record_id = p.id
    cross join bounds b
    where p.status = 'posted'
    group by p.recipient_profile_id
  ), recipients as (
    select recipient_id from earned union select recipient_id from paid
  )
  select r.recipient_id, pr.name,
    (coalesce(e.before_month, 0) - coalesce(p.before_month, 0))::bigint,
    coalesce(e.in_month, 0)::bigint,
    coalesce(p.in_month, 0)::bigint,
    (coalesce(e.before_month, 0) + coalesce(e.in_month, 0)
      - coalesce(p.before_month, 0) - coalesce(p.in_month, 0))::bigint,
    coalesce(e.jobs_in_month, 0)::bigint
  from recipients r
  join public.profiles pr on pr.id = r.recipient_id
  left join earned e on e.recipient_id = r.recipient_id
  left join paid p on p.recipient_id = r.recipient_id
  where coalesce(e.before_month, 0) <> coalesce(p.before_month, 0)
    or coalesce(e.in_month, 0) <> 0
    or coalesce(p.in_month, 0) <> 0
  order by pr.name, pr.id;
end $$;

create or replace function public.finance_unpaid_jobs(
  p_profile uuid, p_limit integer default 50, p_offset integer default 0
)
returns table(
  job_id text,
  team_name text,
  job_type text,
  finished_at timestamptz,
  fee_amount bigint,
  paid_amount bigint,
  remaining_amount bigint
)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not (public.is_finance() or public.is_super_admin()) then
    raise exception 'FORBIDDEN: rincian pembayaran hanya untuk Finance';
  end if;

  return query
  select j.id, j.tim, j.jenis::text, j.finished_at,
    coalesce(j.approved_fee, j.fee)::bigint,
    coalesce(sum(a.amount), 0)::bigint,
    (coalesce(j.approved_fee, j.fee) - coalesce(sum(a.amount), 0))::bigint
  from public.jobs j
  left join public.freelancer_payment_allocations a on a.job_id = j.id
  left join public.freelancer_payment_records p on p.id = a.payment_record_id and p.status = 'posted'
  where j.status = 'Finished'
    and j.approved_for_profile_id = p_profile
  group by j.id, j.tim, j.jenis, j.finished_at, j.approved_fee, j.fee
  having coalesce(j.approved_fee, j.fee) > coalesce(sum(a.amount) filter (where p.status = 'posted'), 0)
  order by j.finished_at, j.id
  limit least(greatest(coalesce(p_limit, 50), 1), 100)
  offset greatest(coalesce(p_offset, 0), 0);
end $$;

create or replace function public.finance_payment_history(
  p_month date, p_limit integer default 50, p_offset integer default 0
)
returns table(
  payment_id uuid,
  recipient_profile_id uuid,
  recipient_name text,
  amount bigint,
  paid_at timestamptz,
  bank_reference text,
  proof_path text,
  note text,
  status text,
  recorded_by_name text,
  recorded_at timestamptz,
  voided_by_name text,
  voided_at timestamptz,
  void_reason text,
  allocations jsonb
)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not (public.is_finance() or public.is_super_admin()) then
    raise exception 'FORBIDDEN: riwayat pembayaran hanya untuk Finance';
  end if;

  return query
  select p.id, p.recipient_profile_id, recipient.name, p.amount, p.paid_at,
    p.bank_reference, p.proof_path, p.note, p.status, recorder.name, p.recorded_at,
    voider.name, p.voided_at, p.void_reason,
    coalesce((
      select jsonb_agg(jsonb_build_object('job_id', a.job_id, 'team_name', j.tim, 'amount', a.amount) order by j.finished_at, a.job_id)
      from public.freelancer_payment_allocations a
      join public.jobs j on j.id = a.job_id
      where a.payment_record_id = p.id
    ), '[]'::jsonb)
  from public.freelancer_payment_records p
  join public.profiles recipient on recipient.id = p.recipient_profile_id
  join public.profiles recorder on recorder.id = p.recorded_by_profile_id
  left join public.profiles voider on voider.id = p.voided_by_profile_id
  where p.paid_at >= (date_trunc('month', p_month::timestamp) at time zone 'Asia/Jakarta')
    and p.paid_at < ((date_trunc('month', p_month::timestamp) + interval '1 month') at time zone 'Asia/Jakarta')
  order by p.paid_at desc, p.id desc
  limit least(greatest(coalesce(p_limit, 50), 1), 100)
  offset greatest(coalesce(p_offset, 0), 0);
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
    coalesce(s.payout_frequency, 'per_job'),
    coalesce(s.payout_method, 'bank_transfer'),
    b.bank_name,
    case when b.account_number is null then null else '•••• ' || right(b.account_number, 4) end,
    b.account_holder, s.updated_at
  from public.profiles p
  left join public.freelancer_payment_settings s on s.profile_id = p.id
  left join public.freelancer_bank_accounts b on b.profile_id = p.id
  where (public.is_finance() or public.is_super_admin())
    and p.role = 'freelance'
    and p.registration_status = 'approved'
  order by p.name, p.id
$$;

create or replace function public.finance_freelancer_bank_account(p_profile uuid)
returns table(bank_name text, account_number text, account_holder text)
language plpgsql security definer set search_path = public, auth as $$
begin
  if not (public.is_finance() or public.is_super_admin()) then
    raise exception 'FORBIDDEN: data rekening hanya untuk Finance';
  end if;
  if not exists (
    select 1 from public.profiles p
    where p.id = p_profile and p.role = 'freelance' and p.registration_status = 'approved'
  ) then
    raise exception 'Freelancer tidak ditemukan atau belum disetujui';
  end if;

  insert into public.freelancer_payment_events(payment_record_id, recipient_profile_id, event_type, actor_profile_id, reason, details)
  values (null, p_profile, 'bank_details_viewed', auth.uid(), 'Finance membuka detail rekening untuk pembayaran', '{}'::jsonb);

  return query select b.bank_name, b.account_number, b.account_holder
    from public.freelancer_bank_accounts b where b.profile_id = p_profile;
end $$;

create or replace function public.finance_log_payment_proof_view(p_payment_id uuid)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare v_payment public.freelancer_payment_records%rowtype;
begin
  if not (public.is_finance() or public.is_super_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Hanya Finance yang dapat melihat bukti pembayaran.');
  end if;
  select * into v_payment from public.freelancer_payment_records where id = p_payment_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'Pembayaran tidak ditemukan.'); end if;

  insert into public.freelancer_payment_events(payment_record_id, recipient_profile_id, event_type, actor_profile_id, reason, details)
  values (v_payment.id, v_payment.recipient_profile_id, 'payment_proof_viewed', auth.uid(), 'Bukti transfer dibuka', '{}'::jsonb);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.record_freelancer_payment(
  p_profile uuid,
  p_paid_at timestamptz,
  p_bank_reference text,
  p_proof_path text,
  p_note text,
  p_allocations jsonb
) returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare
  v_payment_id uuid := gen_random_uuid();
  v_allocation record;
  v_job public.jobs%rowtype;
  v_total bigint := 0;
  v_allocated bigint;
  v_count integer;
  v_distinct_count integer;
  v_existing bigint;
begin
  if not (public.is_finance() or public.is_super_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Hanya Finance yang dapat mencatat pembayaran.');
  end if;
  if p_paid_at is null or p_paid_at > now() + interval '5 minutes' then
    return jsonb_build_object('ok', false, 'error', 'Tanggal pembayaran tidak valid.');
  end if;
  if nullif(btrim(coalesce(p_bank_reference, '')), '') is null
     or char_length(btrim(p_bank_reference)) > 120 then
    return jsonb_build_object('ok', false, 'error', 'Referensi transfer wajib diisi (maksimal 120 karakter).');
  end if;
  if p_allocations is null or jsonb_typeof(p_allocations) <> 'array'
     or jsonb_array_length(p_allocations) < 1 or jsonb_array_length(p_allocations) > 100 then
    return jsonb_build_object('ok', false, 'error', 'Pilih 1 sampai 100 alokasi job.');
  end if;
  if p_proof_path is null or split_part(p_proof_path, '/', 1) <> auth.uid()::text
     or not exists (select 1 from storage.objects o where o.bucket_id = 'payment-proofs' and o.name = p_proof_path) then
    return jsonb_build_object('ok', false, 'error', 'Bukti transfer belum terunggah dengan benar.');
  end if;
  if not exists (select 1 from public.profiles p where p.id = p_profile) then
    return jsonb_build_object('ok', false, 'error', 'Penerima pembayaran tidak ditemukan.');
  end if;
  if exists (
    select 1 from public.freelancer_payment_records p
    where p.recipient_profile_id = p_profile and lower(btrim(p.bank_reference)) = lower(btrim(p_bank_reference))
  ) then
    return jsonb_build_object('ok', false, 'error', 'Referensi transfer ini sudah pernah dicatat untuk freelancer tersebut.');
  end if;

  select count(*)::integer, count(distinct x.job_id)::integer, coalesce(sum(x.amount), 0)::bigint
  into v_count, v_distinct_count, v_total
  from jsonb_to_recordset(p_allocations) as x(job_id text, amount bigint);
  if v_count < 1 or v_count <> v_distinct_count or v_total <= 0 then
    return jsonb_build_object('ok', false, 'error', 'Alokasi job tidak valid atau berulang.');
  end if;

  for v_allocation in
    select x.job_id, x.amount
    from jsonb_to_recordset(p_allocations) as x(job_id text, amount bigint)
    order by x.job_id
  loop
    if v_allocation.amount is null or v_allocation.amount <= 0 then
      return jsonb_build_object('ok', false, 'error', 'Nominal setiap alokasi harus lebih dari nol.');
    end if;
    select * into v_job from public.jobs j where j.id = v_allocation.job_id for update;
    if not found or v_job.status <> 'Finished'
       or v_job.approved_for_profile_id is distinct from p_profile then
      return jsonb_build_object('ok', false, 'error', 'Job tidak Finished atau bukan milik penerima ini.');
    end if;
    select coalesce(sum(a.amount), 0)::bigint into v_allocated
    from public.freelancer_payment_allocations a
    join public.freelancer_payment_records p on p.id = a.payment_record_id
    where a.job_id = v_job.id and p.status = 'posted';
    v_existing := coalesce(v_job.approved_fee, v_job.fee);
    if v_allocated + v_allocation.amount > v_existing then
      return jsonb_build_object('ok', false, 'error', 'Alokasi melebihi sisa fee pada job ' || v_job.id || '.');
    end if;
  end loop;

  insert into public.freelancer_payment_records(
    id, recipient_profile_id, amount, paid_at, bank_reference, proof_path, note, recorded_by_profile_id
  ) values (
    v_payment_id, p_profile, v_total, p_paid_at, btrim(p_bank_reference), p_proof_path,
    nullif(btrim(coalesce(p_note, '')), ''), auth.uid()
  );

  insert into public.freelancer_payment_allocations(payment_record_id, job_id, amount)
  select v_payment_id, x.job_id, x.amount
  from jsonb_to_recordset(p_allocations) as x(job_id text, amount bigint);

  insert into public.freelancer_payment_events(payment_record_id, recipient_profile_id, event_type, actor_profile_id, reason, details)
  values (v_payment_id, p_profile, 'payment_recorded', auth.uid(), 'Transfer dicatat Finance',
    jsonb_build_object('amount', v_total, 'bank_reference', btrim(p_bank_reference), 'allocation_count', v_count));

  return jsonb_build_object('ok', true, 'payment_id', v_payment_id, 'amount', v_total);
end $$;

create or replace function public.void_freelancer_payment(p_payment_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare v_payment public.freelancer_payment_records%rowtype;
begin
  if not (public.is_finance() or public.is_super_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Hanya Finance yang dapat membatalkan catatan pembayaran.');
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Alasan pembatalan wajib diisi.');
  end if;
  select * into v_payment from public.freelancer_payment_records where id = p_payment_id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Pembayaran tidak ditemukan.'); end if;
  if v_payment.status <> 'posted' then return jsonb_build_object('ok', false, 'error', 'Pembayaran ini sudah dibatalkan.'); end if;

  update public.freelancer_payment_records set status = 'voided', voided_at = now(),
    voided_by_profile_id = auth.uid(), void_reason = btrim(p_reason)
  where id = p_payment_id;

  insert into public.freelancer_payment_events(payment_record_id, recipient_profile_id, event_type, actor_profile_id, reason, details)
  values (p_payment_id, v_payment.recipient_profile_id, 'payment_voided', auth.uid(), btrim(p_reason),
    jsonb_build_object('amount', v_payment.amount, 'bank_reference', v_payment.bank_reference));
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.finance_monthly_payment_report(date) from public, anon;
revoke all on function public.finance_unpaid_jobs(uuid, integer, integer) from public, anon;
revoke all on function public.finance_payment_history(date, integer, integer) from public, anon;
revoke all on function public.finance_freelancer_payment_settings() from public, anon;
revoke all on function public.finance_freelancer_bank_account(uuid) from public, anon;
revoke all on function public.finance_log_payment_proof_view(uuid) from public, anon;
revoke all on function public.record_freelancer_payment(uuid, timestamptz, text, text, text, jsonb) from public, anon;
revoke all on function public.void_freelancer_payment(uuid, text) from public, anon;
grant execute on function public.finance_monthly_payment_report(date) to authenticated, service_role;
grant execute on function public.finance_unpaid_jobs(uuid, integer, integer) to authenticated, service_role;
grant execute on function public.finance_payment_history(date, integer, integer) to authenticated, service_role;
grant execute on function public.finance_freelancer_payment_settings() to authenticated, service_role;
grant execute on function public.finance_freelancer_bank_account(uuid) to authenticated, service_role;
grant execute on function public.finance_log_payment_proof_view(uuid) to authenticated, service_role;
grant execute on function public.record_freelancer_payment(uuid, timestamptz, text, text, text, jsonb) to authenticated, service_role;
grant execute on function public.void_freelancer_payment(uuid, text) to authenticated, service_role;
