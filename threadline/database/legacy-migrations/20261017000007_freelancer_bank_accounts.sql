-- Approved freelancers must provide a bank account before using operations.
-- Payout details are kept separately from the public profile and contact data.
create table if not exists public.freelancer_bank_accounts (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  bank_name text not null,
  account_number text not null,
  account_holder text not null,
  updated_at timestamptz not null default now(),
  constraint freelancer_bank_accounts_bank_name_check check (
    char_length(btrim(bank_name)) between 2 and 80
    and regexp_replace(lower(bank_name), '[^a-z0-9]+', ' ', 'g') !~
      '(^| )(go ?pay|ovo|dana|shopee ?pay|link ?aja|doku|sakuku|i ?saku|astra ?pay|motion ?pay|paytren|uangku)( |$)'
  ),
  constraint freelancer_bank_accounts_number_check check (account_number ~ '^[0-9]{5,30}$'),
  constraint freelancer_bank_accounts_holder_check check (char_length(btrim(account_holder)) between 2 and 100)
);

alter table public.freelancer_bank_accounts enable row level security;
revoke all on public.freelancer_bank_accounts from public, anon, authenticated;
grant select, insert, update on public.freelancer_bank_accounts to authenticated;

drop policy if exists freelancer_bank_accounts_admin_read on public.freelancer_bank_accounts;
create policy freelancer_bank_accounts_admin_read
  on public.freelancer_bank_accounts for select to authenticated
  using (public.is_admin());

drop policy if exists freelancer_bank_accounts_owner_read on public.freelancer_bank_accounts;
create policy freelancer_bank_accounts_owner_read
  on public.freelancer_bank_accounts for select to authenticated
  using (
    profile_id = auth.uid()
    and exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'freelance'
        and p.is_active and p.registration_status = 'approved'
    )
  );

drop policy if exists freelancer_bank_accounts_owner_insert on public.freelancer_bank_accounts;
create policy freelancer_bank_accounts_owner_insert
  on public.freelancer_bank_accounts for insert to authenticated
  with check (
    profile_id = auth.uid()
    and exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'freelance'
        and p.is_active and p.registration_status = 'approved'
    )
  );

drop policy if exists freelancer_bank_accounts_owner_update on public.freelancer_bank_accounts;
create policy freelancer_bank_accounts_owner_update
  on public.freelancer_bank_accounts for update to authenticated
  using (
    profile_id = auth.uid()
    and exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'freelance'
        and p.is_active and p.registration_status = 'approved'
    )
  )
  with check (
    profile_id = auth.uid()
    and exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'freelance'
        and p.is_active and p.registration_status = 'approved'
    )
  );

-- RLS policies across the app use is_freelance() for operational access.
-- Requiring saved bank details here prevents skipping the form via direct requests.
create or replace function public.is_freelance() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (
    select 1 from public.profiles p
    join public.freelancer_bank_accounts b on b.profile_id = p.id
    where p.id = auth.uid() and p.is_active and p.role = 'freelance'
      and p.registration_status = 'approved'
  )
$$;
