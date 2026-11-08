SET LOCAL lock_timeout = '2s';
SET LOCAL statement_timeout = '30000ms';
REINDEX TABLE public.phase2_match_lineup_evidence;
