
create table if not exists public.bet365_browser_live_current (
  provider_event_id text primary key,
  fixture_id text,
  canonical_match_id text references public.matches(hkjc_event_id) on delete set null,
  captured_at timestamptz not null,
  event_name text not null,
  league text not null,
  home text not null,
  away text not null,
  home_score integer,
  away_score integer,
  minute integer,
  second integer,
  period text,
  stats jsonb not null default '{}'::jsonb,
  markets jsonb not null default '[]'::jsonb,
  identity_status text not null default 'UNRESOLVED'
    check (identity_status in ('VERIFIED','UNRESOLVED','AMBIGUOUS')),
  raw jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  check (home_score is null or home_score >= 0),
  check (away_score is null or away_score >= 0),
  check (minute is null or minute between 0 and 180),
  check (second is null or second between 0 and 59)
);

create table if not exists public.bet365_browser_quote_current (
  quote_key text primary key,
  provider_event_id text not null,
  canonical_match_id text references public.matches(hkjc_event_id) on delete set null,
  market_key text not null
    check (market_key in ('HDA','GOALS','CORNERS','ASIAN_HANDICAP','UNKNOWN')),
  market_id text,
  market_name text,
  selection_key text,
  selection_name text,
  line numeric,
  raw_od text,
  decimal_price numeric,
  suspended boolean not null default false,
  captured_at timestamptz not null,
  identity_status text not null default 'UNRESOLVED'
    check (identity_status in ('VERIFIED','UNRESOLVED','AMBIGUOUS')),
  raw jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  check (decimal_price is null or decimal_price > 1)
);

create table if not exists public.bet365_browser_quote_history (
  id bigint generated always as identity primary key,
  quote_key text not null,
  provider_event_id text not null,
  canonical_match_id text references public.matches(hkjc_event_id) on delete set null,
  market_key text not null
    check (market_key in ('HDA','GOALS','CORNERS','ASIAN_HANDICAP','UNKNOWN')),
  market_id text,
  market_name text,
  selection_key text,
  selection_name text,
  line numeric,
  raw_od text,
  decimal_price numeric,
  suspended boolean not null default false,
  captured_at timestamptz not null,
  identity_status text not null default 'UNRESOLVED'
    check (identity_status in ('VERIFIED','UNRESOLVED','AMBIGUOUS')),
  raw jsonb not null default '{}'::jsonb,
  inserted_at timestamptz not null default now(),
  check (decimal_price is null or decimal_price > 1)
);

create index if not exists bet365_browser_live_canonical_idx
  on public.bet365_browser_live_current(canonical_match_id, captured_at desc);
create index if not exists bet365_browser_quote_current_match_idx
  on public.bet365_browser_quote_current(canonical_match_id, market_key, captured_at desc);
create index if not exists bet365_browser_quote_history_match_idx
  on public.bet365_browser_quote_history(canonical_match_id, market_key, captured_at desc);
create index if not exists bet365_browser_quote_history_event_idx
  on public.bet365_browser_quote_history(provider_event_id, captured_at desc);

alter table public.bet365_browser_live_current enable row level security;
alter table public.bet365_browser_quote_current enable row level security;
alter table public.bet365_browser_quote_history enable row level security;

revoke all on table public.bet365_browser_live_current from anon, authenticated;
revoke all on table public.bet365_browser_quote_current from anon, authenticated;
revoke all on table public.bet365_browser_quote_history from anon, authenticated;
