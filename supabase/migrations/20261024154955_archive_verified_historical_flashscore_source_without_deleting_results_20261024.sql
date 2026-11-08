
-- Candidate read: only >14-day FINISHED native sources with EXACT historical
-- result match, no canonical fixture, no identity redirect. Preserve model rows.
CREATE OR REPLACE FUNCTION public.ft_result_backed_shadow_cold_candidates(p_limit integer DEFAULT 40)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public,private,pg_temp
AS $fn$
DECLARE rows_out jsonb;
BEGIN
 IF p_limit<1 OR p_limit>40 THEN RAISE EXCEPTION 'RESULT_BACKED_CANDIDATE_LIMIT'; END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.kickoff_utc,x.external_event_id),'[]'::jsonb)
 INTO rows_out
 FROM (
   SELECT s.* FROM public.phase15_source_shadow_current s
   JOIN private.ft_verified_flashscore_results v
   ON v.match_id='FS:'||s.external_event_id
   AND v.kickoff_utc=s.kickoff_utc AND v.home_name=s.home_name
   AND v.away_name=s.away_name AND v.league_id=s.league_external_id
   AND v.home_team_id=s.home_external_id AND v.away_team_id=s.away_external_id
   AND s.raw->>'AG'=v.home_goals::text AND s.raw->>'AH'=v.away_goals::text
   WHERE s.source_key='FLASHSCORE'
     AND s.identity_status='UNMATCHED' AND s.match_id IS NULL
     AND s.raw->>'AB'='3' AND s.raw->>'AC'='3'
     AND s.kickoff_utc<now()-interval '14 days'
     AND s.fetched_at<now()-interval '14 days'
     AND s.updated_at<now()-interval '13 days'
     AND NOT EXISTS (SELECT 1 FROM public.matches m
       WHERE m.canonical_event_id='FS:'||s.external_event_id)
     AND NOT EXISTS (SELECT 1 FROM public.fixture_identity_redirects rd
       WHERE rd.source_match_id='FS:'||s.external_event_id
          OR rd.target_match_id='FS:'||s.external_event_id)
   ORDER BY s.kickoff_utc,s.external_event_id
   LIMIT p_limit
 ) x;
 RETURN rows_out;
END $fn$;

-- Transactional exact-row delete after independently verified Storage readback.
CREATE OR REPLACE FUNCTION public.ft_retire_result_backed_shadow_cold_batch(
p_rows jsonb,p_storage_path text,p_archive_sha text,p_archive_bytes integer
) RETURNS integer LANGUAGE plpgsql
SET search_path=pg_catalog,public,private,storage,pg_temp
AS $fn$
DECLARE expected_n integer;unique_n integer;eligible_n integer;deleted_n integer;
BEGIN
 PERFORM pg_advisory_xact_lock(20261024,79);
 IF p_archive_sha !~ '^[a-f0-9]{64}$'
  OR p_storage_path !~ '^shadow-result-backed/v1/FLASHSCORE/[0-9]{4}-[0-9]{2}-[0-9]{2}/[a-f0-9]{64}[.]jsonl[.]txt$'
  OR right(p_storage_path,length(p_archive_sha||'.jsonl.txt'))<>p_archive_sha||'.jsonl.txt'
 THEN RAISE EXCEPTION 'INVALID_VERIFIED_RESULT_ARCHIVE_PATH'; END IF;
 IF p_archive_bytes<100 OR p_archive_bytes>2600000 OR NOT EXISTS(
  SELECT 1 FROM storage.objects o WHERE o.bucket_id='fast-tracker-ingest'
    AND o.name=p_storage_path AND o.metadata->>'size'=p_archive_bytes::text
 ) THEN RAISE EXCEPTION 'RESULT_SOURCE_ARCHIVE_NOT_FOUND'; END IF;
 IF jsonb_typeof(p_rows)<>'array' THEN RAISE EXCEPTION 'RESULT_BATCH_NOT_ARRAY'; END IF;
 expected_n:=jsonb_array_length(p_rows);
 IF expected_n<1 OR expected_n>40 THEN RAISE EXCEPTION 'RESULT_BATCH_TOO_LARGE'; END IF;
 SELECT count(DISTINCT e->>'external_event_id') INTO unique_n
 FROM jsonb_array_elements(p_rows) e
 WHERE e->>'source_key'='FLASHSCORE'
   AND e->>'external_event_id'~'^[A-Za-z0-9_-]{5,32}$'
   AND e->>'identity_status'='UNMATCHED'
   AND e->>'match_id' IS NULL;
 IF unique_n<>expected_n THEN RAISE EXCEPTION 'RESULT_BATCH_IDENTITIES_UNSAFE'; END IF;

 WITH evidence AS (
  SELECT x.* FROM jsonb_to_recordset(p_rows) x(
   source_key text,external_event_id text,fetched_at timestamptz,kickoff_utc timestamptz,
   updated_at timestamptz,match_id text,identity_status text,raw jsonb,detail_raw jsonb)
 )
 SELECT count(*) INTO eligible_n
 FROM evidence e JOIN public.phase15_source_shadow_current s
  ON s.source_key=e.source_key AND s.external_event_id=e.external_event_id
 JOIN private.ft_verified_flashscore_results v
  ON v.match_id='FS:'||s.external_event_id
  AND v.kickoff_utc=s.kickoff_utc
  AND v.home_name=s.home_name AND v.away_name=s.away_name
  AND v.league_id=s.league_external_id
  AND v.home_team_id=s.home_external_id AND v.away_team_id=s.away_external_id
  AND s.raw->>'AG'=v.home_goals::text AND s.raw->>'AH'=v.away_goals::text
 WHERE s.source_key='FLASHSCORE'
  AND s.match_id IS NULL AND s.identity_status='UNMATCHED'
  AND s.raw->>'AB'='3' AND s.raw->>'AC'='3'
  AND s.kickoff_utc<now()-interval '14 days'
  AND s.fetched_at<now()-interval '14 days'
  AND s.updated_at<now()-interval '13 days'
  AND s.fetched_at=e.fetched_at AND s.kickoff_utc=e.kickoff_utc
  AND s.updated_at=e.updated_at
  AND s.raw IS NOT DISTINCT FROM e.raw
  AND s.detail_raw IS NOT DISTINCT FROM e.detail_raw
  AND NOT EXISTS(SELECT 1 FROM public.matches m
    WHERE m.canonical_event_id='FS:'||s.external_event_id)
  AND NOT EXISTS(SELECT 1 FROM public.fixture_identity_redirects rd
    WHERE rd.source_match_id='FS:'||s.external_event_id
       OR rd.target_match_id='FS:'||s.external_event_id);
 IF eligible_n<>expected_n THEN RAISE EXCEPTION 'HISTORICAL_SOURCE_OR_RESULT_CHANGED'; END IF;

 WITH evidence AS (
  SELECT x.* FROM jsonb_to_recordset(p_rows) x(
   source_key text,external_event_id text,fetched_at timestamptz,kickoff_utc timestamptz,
   updated_at timestamptz,raw jsonb,detail_raw jsonb)
 ), removed AS (
  DELETE FROM public.phase15_source_shadow_current s USING evidence e
  WHERE s.source_key=e.source_key AND s.external_event_id=e.external_event_id
    AND s.source_key='FLASHSCORE' AND s.match_id IS NULL
    AND s.identity_status='UNMATCHED'
    AND s.raw->>'AB'='3' AND s.raw->>'AC'='3'
    AND s.kickoff_utc<now()-interval '14 days'
    AND s.fetched_at<now()-interval '14 days'
    AND s.updated_at<now()-interval '13 days'
    AND s.fetched_at=e.fetched_at AND s.kickoff_utc=e.kickoff_utc
    AND s.updated_at=e.updated_at
    AND s.raw IS NOT DISTINCT FROM e.raw
    AND s.detail_raw IS NOT DISTINCT FROM e.detail_raw
    AND EXISTS (
      SELECT 1 FROM private.ft_verified_flashscore_results v
      WHERE v.match_id='FS:'||s.external_event_id
        AND v.kickoff_utc=s.kickoff_utc
        AND v.home_name=s.home_name AND v.away_name=s.away_name
        AND v.league_id=s.league_external_id
        AND v.home_team_id=s.home_external_id AND v.away_team_id=s.away_external_id
        AND s.raw->>'AG'=v.home_goals::text AND s.raw->>'AH'=v.away_goals::text
    )
    AND NOT EXISTS (SELECT 1 FROM public.matches m
      WHERE m.canonical_event_id='FS:'||s.external_event_id)
    AND NOT EXISTS (SELECT 1 FROM public.fixture_identity_redirects rd
      WHERE rd.source_match_id='FS:'||s.external_event_id
         OR rd.target_match_id='FS:'||s.external_event_id)
    RETURNING s.external_event_id
 ) SELECT count(*) INTO deleted_n FROM removed;
 IF deleted_n<>expected_n THEN RAISE EXCEPTION 'VERIFIED_RESULT_COLD_DELETE_ROLLED_BACK'; END IF;
 RETURN deleted_n;
END $fn$;

REVOKE ALL ON FUNCTION public.ft_result_backed_shadow_cold_candidates(integer)
  FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.ft_retire_result_backed_shadow_cold_batch(jsonb,text,text,integer)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ft_result_backed_shadow_cold_candidates(integer)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.ft_retire_result_backed_shadow_cold_batch(jsonb,text,text,integer)
  TO service_role;
