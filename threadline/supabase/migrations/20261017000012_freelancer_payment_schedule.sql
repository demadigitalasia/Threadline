-- Compensation amounts remain on the job. Finance only configures payout timing
-- and uses the freelancer's validated bank account for manual transfer.

drop function if exists public.finance_freelancer_compensation();
drop function if exists public.set_freelancer_compensation(uuid, text, bigint);

alter table public.freelancer_compensation rename to freelancer_payment_settings;
alter table public.freelancer_payment_settings rename column pay_scheme to payout_frequency;
alter table public.freelancer_payment_settings
  drop constraint if exists freelancer_compensation_amount_check;
alter table public.freelancer_payment_settings
  drop constraint if exists freelancer_compensation_pay_scheme_check;
alter table public.freelancer_payment_settings drop column amount;
alter table public.freelancer_payment_settings
  add constraint freelancer_payment_settings_payout_frequency_check
  check (payout_frequency in ('per_job', 'daily', 'weekly', 'monthly'));
alter table public.freelancer_payment_settings
  add column payout_method text not null default 'bank_transfer'
  check (payout_method = 'bank_transfer');
alter table public.freelancer_payment_settings
  rename constraint freelancer_compensation_pkey to freelancer_payment_settings_pkey;
alter table public.freelancer_payment_settings
  rename constraint freelancer_compensation_profile_id_fkey to freelancer_payment_settings_profile_id_fkey;
alter table public.freelancer_payment_settings
  rename constraint freelancer_compensation_updated_by_profile_id_fkey to freelancer_payment_settings_updated_by_profile_id_fkey;

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
    b.bank_name, b.account_number, b.account_holder, s.updated_at
  from public.profiles p
  left join public.freelancer_payment_settings s on s.profile_id = p.id
  left join public.freelancer_bank_accounts b on b.profile_id = p.id
  where public.is_finance()
    and p.role = 'freelance'
    and p.registration_status = 'approved'
  order by p.name, p.id
$$;
revoke all on function public.finance_freelancer_payment_settings() from public, anon;
grant execute on function public.finance_freelancer_payment_settings() to authenticated, service_role;

create or replace function public.set_freelancer_payment_schedule(
  p_profile uuid,
  p_payout_frequency text
) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  v_profile public.profiles%rowtype;
  v_old public.freelancer_payment_settings%rowtype;
  v_actor_label text;
  v_before jsonb;
  v_after jsonb;
begin
  if not public.is_finance() then
    return jsonb_build_object('ok', false, 'error', 'Hanya Finance yang dapat mengatur jadwal pembayaran.');
  end if;

  if p_payout_frequency is null or p_payout_frequency not in ('per_job', 'daily', 'weekly', 'monthly') then
    return jsonb_build_object('ok', false, 'error', 'Jadwal pembayaran tidak valid.');
  end if;

  select * into v_profile from public.profiles where id = p_profile for update;
  if not found or v_profile.role <> 'freelance' or v_profile.registration_status <> 'approved' then
    return jsonb_build_object('ok', false, 'error', 'Freelancer tidak ditemukan atau belum disetujui.');
  end if;

  select * into v_old from public.freelancer_payment_settings where profile_id = p_profile for update;
  if found and v_old.payout_frequency = p_payout_frequency then
    return jsonb_build_object('ok', true, 'changed', false);
  end if;
  v_before := case when found
    then jsonb_build_object('payout_frequency', v_old.payout_frequency, 'payout_method', v_old.payout_method)
    else jsonb_build_object('payout_frequency', 'per_job', 'payout_method', 'bank_transfer') end;

  insert into public.freelancer_payment_settings(
    profile_id, payout_frequency, payout_method, updated_by_profile_id, updated_at
  ) values (p_profile, p_payout_frequency, 'bank_transfer', auth.uid(), now())
  on conflict (profile_id) do update set
    payout_frequency = excluded.payout_frequency,
    payout_method = excluded.payout_method,
    updated_by_profile_id = excluded.updated_by_profile_id,
    updated_at = excluded.updated_at;
  v_after := jsonb_build_object('payout_frequency', p_payout_frequency, 'payout_method', 'bank_transfer');

  select name into v_actor_label from public.profiles where id = auth.uid();
  insert into public.admin_audit_events(
    event_type, target_profile_id, target_label, actor_profile_id, actor_label,
    before_data, after_data, reason
  ) values (
    'freelancer_payment_schedule_updated', p_profile, v_profile.name, auth.uid(), coalesce(v_actor_label, 'Finance'),
    coalesce(v_before, '{}'::jsonb), coalesce(v_after, '{}'::jsonb), 'Perubahan jadwal pembayaran freelancer'
  );
  return jsonb_build_object('ok', true, 'changed', true);
end $$;
revoke all on function public.set_freelancer_payment_schedule(uuid, text) from public, anon;
grant execute on function public.set_freelancer_payment_schedule(uuid, text) to authenticated, service_role;
