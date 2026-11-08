
create table if not exists public.football_alias_supertable (
 source text not null,
 alias_key text not null,
 competition_key text not null default '',
 provider_team_id text not null default '',
 provider_name text not null,
 source_competition text not null default '',
 canonical_competition text,
 verified_team_key text references public.team_entities_v2(team_key),
 suggested_team_key text references public.team_entities_v2(team_key),
 canonical_name_en text,
 canonical_name_zh text,
 resolution_status text not null check(resolution_status in ('VERIFIED','CANDIDATE','AMBIGUOUS','UNMATCHED')),
 confidence numeric not null default 0 check (confidence>=0 and confidence<=1),
 resolution_method text not null,
 observations integer not null default 0,
 source_event_id_example text,
 source_detail_url text,
 last_observed_at timestamptz,
 evidence jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now(),
 refreshed_at timestamptz not null default now(),
 primary key(source,alias_key,competition_key,provider_team_id),
 constraint ft_super_verified_only check (resolution_status <> 'VERIFIED' or verified_team_key is not null),
 constraint ft_super_candidate_only check (resolution_status <> 'CANDIDATE' or suggested_team_key is not null)
);
create index if not exists ft_super_match_lookup on public.football_alias_supertable(source, resolution_status, alias_key);
create index if not exists ft_super_team_lookup on public.football_alias_supertable(verified_team_key) where verified_team_key is not null;
create index if not exists ft_super_source_team_id_idx on public.football_alias_supertable(source,provider_team_id) where provider_team_id<>'';
create index if not exists ft_super_comp_lookup on public.football_alias_supertable(source,competition_key);
alter table public.football_alias_supertable enable row level security;
revoke all on public.football_alias_supertable from public, anon, authenticated;
grant select,insert,update on public.football_alias_supertable to service_role;
comment on table public.football_alias_supertable is 'Read-only-for-clients combined football provider name/league/ID coverage. VERIFIED must trace to pre-existing verified source or stable ID; cross-source and name-only suggestions are CANDIDATE. Refresh daily, no fixture promotion.';
