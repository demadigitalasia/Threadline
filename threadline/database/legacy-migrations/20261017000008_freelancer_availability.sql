-- Availability is a freelancer's current check-in intent. Online/offline
-- presence continues to come from the existing last_seen heartbeat.
alter table public.profiles
  add column if not exists availability_status text not null default 'pending',
  add column if not exists availability_updated_at timestamptz not null default now();

alter table public.profiles
  drop constraint if exists profiles_availability_status_check;
alter table public.profiles
  add constraint profiles_availability_status_check
  check (availability_status in ('pending', 'ready', 'unavailable'));

comment on column public.profiles.availability_status is
  'Freelancer check-in intent: pending response, ready to receive work, or unavailable.';
comment on column public.profiles.availability_updated_at is
  'Last time the freelancer changed their check-in availability.';
