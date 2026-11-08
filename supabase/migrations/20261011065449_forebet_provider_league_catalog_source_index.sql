
create table if not exists public.football_provider_league_catalog(
 source text not null,
 league_url text not null,
 league_name text not null,
 region_slug text,
 league_slug text,
 catalog_status text not null default 'LISTED_UNVERIFIED',
 first_seen_at timestamptz not null default now(),
 last_seen_at timestamptz not null default now(),
 evidence_source_url text,
 primary key(source,league_url),
 constraint ft_league_status check(catalog_status in ('LISTED_UNVERIFIED','VERIFIED')),
 constraint ft_league_source_domain check(league_url like 'https://www.forebet.com/en/%')
);
alter table public.football_provider_league_catalog enable row level security;
revoke all on public.football_provider_league_catalog from public,anon,authenticated;
grant select,insert,update on public.football_provider_league_catalog to service_role;
comment on table public.football_provider_league_catalog is 'Discoverable original provider competition URLs and names. LISTED_UNVERIFIED means link seen in provider navigation; never automatically equated with canonical league IDs.';
