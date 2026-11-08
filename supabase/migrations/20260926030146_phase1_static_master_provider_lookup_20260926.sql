create index if not exists team_name_master_verified_provider_lookup_idx on public.team_name_master (source, source_key) where status = 'VERIFIED';
