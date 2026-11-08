
create table if not exists public.fixture_identity_redirects (
  source_match_id text primary key references public.matches(hkjc_event_id) on delete restrict,
  target_match_id text not null references public.matches(hkjc_event_id) on delete restrict,
  source_name text not null,
  confidence numeric not null check (confidence >= 0 and confidence <= 1),
  evidence jsonb not null default '{}'::jsonb,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (source_match_id <> target_match_id)
);

create index if not exists fixture_identity_redirects_target_idx
  on public.fixture_identity_redirects(target_match_id)
  where active=true;

alter table public.fixture_identity_redirects enable row level security;
revoke all on public.fixture_identity_redirects from anon, authenticated;
grant select,insert,update on public.fixture_identity_redirects to service_role;

create or replace view public.active_canonical_fixture_current
with (security_invoker = true)
as
select
  m.hkjc_event_id as match_id,
  m.kickoff_hkt,
  m.status,
  m.tournament as league,
  m.home_en,
  m.away_en,
  m.home_zh,
  m.away_zh,
  m.in_play,
  m.selling,
  m.pool_status,
  m.fetched_at,
  m.source_updated_at,
  m.updated_at
from public.matches m
where not exists (
  select 1
  from public.fixture_identity_redirects r
  where r.source_match_id=m.hkjc_event_id
    and r.active=true
);

revoke all on public.active_canonical_fixture_current from anon, authenticated;
grant select on public.active_canonical_fixture_current to service_role;
