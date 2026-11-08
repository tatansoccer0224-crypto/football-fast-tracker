create index if not exists odds_snapshots_flashscore_ml_idx on public.odds_snapshots (match_id,captured_at desc) where source='FLASHSCORE_BET365' and market='ML'
