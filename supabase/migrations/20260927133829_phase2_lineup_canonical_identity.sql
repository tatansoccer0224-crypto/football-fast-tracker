create unique index if not exists phase2_lineup_source_player_uidx
on public.phase2_match_lineup_evidence (hkjc_event_id,team_side,source_name,player_key)
where player_key is not null;
