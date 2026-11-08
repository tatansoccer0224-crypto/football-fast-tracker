SET LOCAL lock_timeout='2s';
SET LOCAL statement_timeout='25000ms';
REINDEX TABLE public.team_name_master;
