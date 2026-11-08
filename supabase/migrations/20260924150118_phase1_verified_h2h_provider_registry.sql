create table if not exists public.phase1_h2h_provider_event_map (
  hkjc_event_id text not null,
  provider text not null,
  provider_event_id text not null,
  provider_home_team_id text,
  provider_away_team_id text,
  home_team_key text,
  away_team_key text,
  competition_key text,
  kickoff_hkt timestamptz,
  mapping_status text not null default 'CANDIDATE' check (mapping_status in ('VERIFIED','CANDIDATE','AMBIGUOUS','REJECTED')),
  mapping_method text,
  evidence jsonb not null default '{}'::jsonb,
  evidence_count integer not null default 0,
  verified_at timestamptz,
  fetched_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (provider, provider_event_id),
  unique (provider, hkjc_event_id)
);
create index if not exists phase1_h2h_provider_event_map_hkjc_idx on public.phase1_h2h_provider_event_map(hkjc_event_id);
create index if not exists phase1_h2h_provider_event_map_status_idx on public.phase1_h2h_provider_event_map(provider,mapping_status);

create table if not exists public.phase1_h2h_provider_meetings (
  provider text not null,
  provider_meeting_id text not null,
  hkjc_event_id text not null,
  provider_event_id text,
  meeting_kickoff timestamptz,
  canonical_home_team_key text,
  canonical_away_team_key text,
  provider_home_team_id text,
  provider_away_team_id text,
  home_score integer,
  away_score integer,
  competition_key text,
  orientation text not null default 'CANONICAL' check (orientation in ('CANONICAL','REVERSED')),
  quality text not null default 'VERIFIED' check (quality in ('VERIFIED','PARTIAL','REJECTED')),
  source_url text,
  raw jsonb,
  fetched_at timestamptz not null default now(),
  primary key (provider, provider_meeting_id, hkjc_event_id)
);
create index if not exists phase1_h2h_provider_meetings_event_idx on public.phase1_h2h_provider_meetings(hkjc_event_id,meeting_kickoff desc);

create or replace view public.phase1_h2h_status_v as
select
  h.hkjc_event_id,
  case
    when h.quality='H2H_OK' and coalesce(h.h2h_games,0)>0 then 'H2H_OK'
    when h.quality='NO_PREVIOUS_H2H_IN_AVAILABLE_HISTORY' then 'NO_HISTORY'
    when h.quality='HISTORY_PARTIAL' then 'HISTORY_PARTIAL'
    else 'HISTORY_PARTIAL'
  end as display_status,
  coalesce(h.h2h_games,0) as hkjc_games,
  h.quality as hkjc_quality,
  m.provider,
  m.provider_event_id,
  m.mapping_status,
  m.evidence_count,
  (select count(*) from public.phase1_h2h_provider_meetings pm where pm.hkjc_event_id=h.hkjc_event_id and pm.provider=m.provider and pm.quality='VERIFIED') as provider_verified_meetings
from public.match_h2h_current h
left join public.phase1_h2h_provider_event_map m
  on m.hkjc_event_id=h.hkjc_event_id and m.mapping_status='VERIFIED';

comment on table public.phase1_h2h_provider_event_map is 'Phase 1 persistent verified HKJC-to-provider event identity registry for deep H2H sources such as Sofascore; never fuzzy-force.';
comment on table public.phase1_h2h_provider_meetings is 'Phase 1 normalized verified direct-meeting history, stored in current HKJC home/away canonical orientation.';
