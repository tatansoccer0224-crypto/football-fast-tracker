DO $$
DECLARE f_def text;
BEGIN
 f_def := pg_get_functiondef('public.ft_retire_verified_lineup_batch(text,text,integer,jsonb)'::regprocedure);
 IF (select count(*) from regexp_matches(f_def, '14 days', 'g')) <> 2
    OR f_def NOT LIKE '%ARCHIVED_LINEUP_OBJECT_NOT_PRESENT%'
    OR f_def NOT LIKE '%ARCHIVED_LINEUP_SOURCE_CHANGED_OR_STILL_ACTIVE%'
    OR f_def NOT LIKE '%flashscore_primary_fixture_current%'
    OR f_def NOT LIKE '%canonical_fixture_current%'
 THEN RAISE EXCEPTION 'RETENTION_FUNCTION_UNEXPECTED_REJECTED'; END IF;
 EXECUTE replace(f_def,'14 days','7 days');
END $$;
COMMENT ON FUNCTION public.ft_retire_verified_lineup_batch(text,text,integer,jsonb)
 IS 'Exact SHA256-archived and readback-verified retired lineups: older than 7 days and not in current Flashscore or recent canonical fixture. Service role only.';
