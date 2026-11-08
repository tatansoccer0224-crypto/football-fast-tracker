
create table if not exists public.football_alias_offline_pair_evidence (
 source text not null,
 source_event_id text not null,
 alias_key text not null,
 alias text not null,
 reference_source text not null,
 reference_event_id text not null,
 reference_name text not null,
 proposed_team_key text not null references public.team_entities_v2(team_key),
 fixture_date date not null,
 source_competition text,
 lexical_ratio numeric not null check(lexical_ratio between 0 and 1),
 confidence numeric not null check(confidence between 0 and 1),
 status text not null default 'CANDIDATE' check(status in ('CANDIDATE','VERIFIED','REJECTED','CONFLICT')),
 method text not null,
 evidence jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now(),
 primary key(source,source_event_id,alias_key,reference_source,reference_event_id)
);
create index if not exists ft_alias_offline_lookup on public.football_alias_offline_pair_evidence(source,alias_key,status);
create index if not exists ft_alias_offline_target on public.football_alias_offline_pair_evidence(proposed_team_key);
alter table public.football_alias_offline_pair_evidence enable row level security;
revoke all on public.football_alias_offline_pair_evidence from public,anon,authenticated;
grant select,insert,update on public.football_alias_offline_pair_evidence to service_role;
comment on table public.football_alias_offline_pair_evidence is 'One-off backward fixture/opponent alias evidence; one-to-one event safety, date gate, lexical similarity; no automatic verified promotion.';
