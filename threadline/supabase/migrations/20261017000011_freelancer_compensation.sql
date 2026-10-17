-- Let Finance assign a current compensation scheme to approved freelancers.
-- Per-job compensation follows the job fee frozen when its preview is approved.

create table if not exists public.freelancer_compensation (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  pay_scheme text not null check (pay_scheme in ('per_job', 'daily', 'weekly', 'monthly')),
  amount bigint,
  updated_by_profile_id uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now(),
  constraint freelancer_compensation_amount_check check (
    (pay_scheme = 'per_job' and amount is null)
    or (pay_scheme in ('daily', 'weekly', 'monthly') and amount between 1 and 1000000000000)
  )
);

alter table public.freelancer_compensation enable row level security;
revoke all on public.freelancer_compensation from public, anon, authenticated;
grant all on public.freelancer_compensation to service_role;

create or replace function public.finance_freelancer_compensation()
returns table(
  profile_id uuid,
  profile_name text,
  is_active boolean,
  pay_scheme text,
  amount bigint,
  updated_at timestamptz
)
language sql stable security definer set search_path = public as $$
  select p.id, p.name, p.is_active, c.pay_scheme, c.amount, c.updated_at
  from public.profiles p
  left join public.freelancer_compensation c on c.profile_id = p.id
  where public.is_finance()
    and p.role = 'freelance'
    and p.registration_status = 'approved'
  order by p.name, p.id
$$;
revoke all on function public.finance_freelancer_compensation() from public, anon;
grant execute on function public.finance_freelancer_compensation() to authenticated, service_role;

create or replace function public.set_freelancer_compensation(
  p_profile uuid,
  p_pay_scheme text,
  p_amount bigint
) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  v_profile public.profiles%rowtype;
  v_old public.freelancer_compensation%rowtype;
  v_actor_label text;
  v_before jsonb;
  v_after jsonb;
begin
  if not public.is_finance() then
    return jsonb_build_object('ok', false, 'error', 'Hanya Finance yang dapat mengatur skema upah.');
  end if;

  select * into v_profile from public.profiles where id = p_profile for update;
  if not found or v_profile.role <> 'freelance' or v_profile.registration_status <> 'approved' then
    return jsonb_build_object('ok', false, 'error', 'Freelancer tidak ditemukan atau belum disetujui.');
  end if;

  select * into v_old from public.freelancer_compensation where profile_id = p_profile for update;
  if p_pay_scheme is null then
    if not found then return jsonb_build_object('ok', true, 'changed', false); end if;
    v_before := jsonb_build_object('pay_scheme', v_old.pay_scheme, 'amount', v_old.amount);
    delete from public.freelancer_compensation where profile_id = p_profile;
    v_after := '{}'::jsonb;
  else
    if p_pay_scheme not in ('per_job', 'daily', 'weekly', 'monthly') then
      return jsonb_build_object('ok', false, 'error', 'Skema upah tidak valid.');
    end if;
    if p_pay_scheme = 'per_job' then
      if p_amount is not null then return jsonb_build_object('ok', false, 'error', 'Skema per job mengikuti fee pada setiap job.'); end if;
    elsif p_amount is null or p_amount < 1 or p_amount > 1000000000000 then
      return jsonb_build_object('ok', false, 'error', 'Nominal upah wajib berupa angka bulat lebih dari Rp0.');
    end if;

    if found and v_old.pay_scheme = p_pay_scheme and v_old.amount is not distinct from p_amount then
      return jsonb_build_object('ok', true, 'changed', false);
    end if;

    v_before := case when found
      then jsonb_build_object('pay_scheme', v_old.pay_scheme, 'amount', v_old.amount)
      else '{}'::jsonb end;
    insert into public.freelancer_compensation(profile_id, pay_scheme, amount, updated_by_profile_id, updated_at)
    values (p_profile, p_pay_scheme, p_amount, auth.uid(), now())
    on conflict (profile_id) do update set
      pay_scheme = excluded.pay_scheme,
      amount = excluded.amount,
      updated_by_profile_id = excluded.updated_by_profile_id,
      updated_at = excluded.updated_at;
    v_after := jsonb_build_object('pay_scheme', p_pay_scheme, 'amount', p_amount);
  end if;

  select name into v_actor_label from public.profiles where id = auth.uid();
  insert into public.admin_audit_events(
    event_type, target_profile_id, target_label, actor_profile_id, actor_label,
    before_data, after_data, reason
  ) values (
    'freelancer_compensation_updated', p_profile, v_profile.name, auth.uid(), coalesce(v_actor_label, 'Finance'),
    coalesce(v_before, '{}'::jsonb), coalesce(v_after, '{}'::jsonb), 'Perubahan skema upah freelancer'
  );
  return jsonb_build_object('ok', true, 'changed', true);
end $$;
revoke all on function public.set_freelancer_compensation(uuid, text, bigint) from public, anon;
grant execute on function public.set_freelancer_compensation(uuid, text, bigint) to authenticated, service_role;
