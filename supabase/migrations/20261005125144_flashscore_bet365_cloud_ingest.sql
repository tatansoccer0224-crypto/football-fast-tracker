
create table if not exists public.flashscore_bet365_current (
  provider_event_id text primary key,
  captured_at timestamptz not null,
  fixture_date date,
  kickoff_utc timestamptz,
  league text,
  home text not null,
  away text not null,
  home_price numeric,
  draw_price numeric,
  away_price numeric,
  opening_home numeric,
  opening_draw numeric,
  opening_away numeric,
  canonical_match_id text references public.matches(hkjc_event_id) on delete set null,
  identity_status text not null default 'UNRESOLVED'
    check (identity_status in ('VERIFIED','UNRESOLVED','AMBIGUOUS')),
  raw jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create index if not exists flashscore_bet365_current_canonical_idx
  on public.flashscore_bet365_current (canonical_match_id)
  where canonical_match_id is not null;

create index if not exists flashscore_bet365_current_captured_idx
  on public.flashscore_bet365_current (captured_at desc);

alter table public.flashscore_bet365_current enable row level security;
revoke all on public.flashscore_bet365_current from anon, authenticated;
grant all on public.flashscore_bet365_current to service_role;

comment on table public.flashscore_bet365_current is
  'Cloud Flashscore-derived Bet365 complete HDA snapshots. Service-only staging; canonical promotion requires exact unique fixture identity.';
