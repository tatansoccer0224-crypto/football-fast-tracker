create index if not exists phase15_shadow_fotmob_hkjc_lookup_idx on public.phase15_source_shadow_current (matched_hkjc_event_id, match_confidence desc) where source_key = 'FOTMOB';
