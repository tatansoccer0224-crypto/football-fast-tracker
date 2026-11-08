
create table if not exists public.flashscore_fixture_current (
  provider_event_id text primary key,
  captured_at timestamptz not null,
  fixture_date date,
  kickoff_utc timestamptz,
  league text,
  home text not null,
  away text not null,
  canonical_match_id text references public.matches(hkjc_event_id) on delete set null,
  identity_status text not null
    check (identity_status in ('EXACT_EXISTING','CREATED','DEFERRED_NEARBY','INVALID_TIME','AMBIGUOUS')),
  raw jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create index if not exists flashscore_fixture_current_canonical_idx
  on public.flashscore_fixture_current(canonical_match_id)
  where canonical_match_id is not null;

create index if not exists flashscore_fixture_current_kickoff_idx
  on public.flashscore_fixture_current(kickoff_utc);

alter table public.flashscore_fixture_current enable row level security;
revoke all on public.flashscore_fixture_current from anon, authenticated;
grant all on public.flashscore_fixture_current to service_role;

comment on table public.flashscore_fixture_current is
  'Current Flashscore fixture discovery map. Service-only. New FS: canonical IDs are created only when exact existing identity is absent and no nearby one-team-overlap duplicate risk exists.';
