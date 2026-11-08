SET LOCAL lock_timeout='2s';
ALTER TABLE public.phase2_match_lineup_evidence SET (autovacuum_vacuum_scale_factor=0.06, autovacuum_vacuum_threshold=1000, autovacuum_analyze_scale_factor=0.05, autovacuum_analyze_threshold=500);
