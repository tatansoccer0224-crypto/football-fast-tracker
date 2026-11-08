create index if not exists phase1_h2h_event_map_hkjc_provider_status_idx
on public.phase1_h2h_provider_event_map (hkjc_event_id, provider, mapping_status);

create index if not exists phase1_h2h_event_map_team_pair_comp_kickoff_idx
on public.phase1_h2h_provider_event_map (provider, home_team_key, away_team_key, competition_key, kickoff_hkt);

create index if not exists phase1_h2h_meetings_event_recent_idx
on public.phase1_h2h_provider_meetings (hkjc_event_id, provider, meeting_kickoff desc)
where quality in ('VERIFIED','PARTIAL');
