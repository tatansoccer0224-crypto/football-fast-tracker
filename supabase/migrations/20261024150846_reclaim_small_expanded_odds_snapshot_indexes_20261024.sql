SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '12000ms';
REINDEX TABLE public.odds_snapshots;
