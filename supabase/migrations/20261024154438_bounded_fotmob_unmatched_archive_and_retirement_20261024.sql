
-- FotMob cold source retention: read-only bounded candidates.
CREATE OR REPLACE FUNCTION public.ft_fotmob_cold_unmatched_candidates(p_limit integer DEFAULT 40)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public,private,pg_temp
AS $fn$
DECLARE v_rows jsonb;
BEGIN
 IF p_limit<1 OR p_limit>40 THEN RAISE EXCEPTION 'FOTMOB_COLD_READ_LIMIT'; END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY c.kickoff_utc,c.external_event_id),'[]'::jsonb)
 INTO v_rows
 FROM (
  SELECT s.* FROM public.phase15_source_shadow_current s
  WHERE s.source_key='FOTMOB'
    AND s.identity_status='UNMATCHED'
    AND s.match_id IS NULL
    AND s.kickoff_utc<now()-interval '7 days'
    AND s.fetched_at<now()-interval '7 days'
    AND s.updated_at<now()-interval '6 days'
    AND s.external_event_id~'^[0-9]{5,16}$'
    AND NOT EXISTS(SELECT 1 FROM public.phase2_match_lineup_evidence l
      WHERE l.match_id IN ('FM:'||s.external_event_id,'FOTMOB:'||s.external_event_id))
    AND NOT EXISTS(SELECT 1 FROM public.fixture_identity_redirects rd
      WHERE rd.source_match_id IN ('FM:'||s.external_event_id,'FOTMOB:'||s.external_event_id)
         OR rd.target_match_id IN ('FM:'||s.external_event_id,'FOTMOB:'||s.external_event_id))
  ORDER BY s.kickoff_utc,s.external_event_id LIMIT p_limit
 ) c;
 RETURN v_rows;
END $fn$;

-- Exact-row guarded deletion, service-role only, after SHA-256 archive readback.
CREATE OR REPLACE FUNCTION public.ft_retire_verified_fotmob_cold_batch(
p_rows jsonb,p_storage_path text,p_archive_sha text,p_archive_bytes integer
) RETURNS integer LANGUAGE plpgsql
SET search_path=pg_catalog,public,private,storage,pg_temp
AS $fn$
DECLARE expected_n integer;unique_n integer;eligible_n integer;deleted_n integer;
BEGIN
 PERFORM pg_advisory_xact_lock(20261024,78);
 IF p_archive_sha !~ '^[a-f0-9]{64}$'
  OR p_storage_path !~ '^shadow-cold/v1/FOTMOB/[0-9]{4}-[0-9]{2}-[0-9]{2}/[a-f0-9]{64}[.]jsonl[.]txt$'
  OR right(p_storage_path,length(p_archive_sha||'.jsonl.txt'))<>p_archive_sha||'.jsonl.txt'
 THEN RAISE EXCEPTION 'INVALID_FOTMOB_ARCHIVE_PATH'; END IF;
 IF p_archive_bytes<100 OR p_archive_bytes>2600000 OR NOT EXISTS(
  SELECT 1 FROM storage.objects o
  WHERE o.bucket_id='fast-tracker-ingest' AND o.name=p_storage_path
  AND o.metadata->>'size'=p_archive_bytes::text
 ) THEN RAISE EXCEPTION 'FOTMOB_ARCHIVE_NOT_IN_STORAGE'; END IF;
 IF jsonb_typeof(p_rows)<>'array' THEN RAISE EXCEPTION 'FOTMOB_BATCH_NOT_ARRAY'; END IF;
 expected_n:=jsonb_array_length(p_rows);
 IF expected_n<1 OR expected_n>40 THEN RAISE EXCEPTION 'FOTMOB_BATCH_TOO_LARGE'; END IF;

 SELECT count(DISTINCT e->>'external_event_id') INTO unique_n
 FROM jsonb_array_elements(p_rows) e
 WHERE e->>'source_key'='FOTMOB' AND e->>'external_event_id'~'^[0-9]{5,16}$'
 AND e->>'match_id' IS NULL AND e->>'identity_status'='UNMATCHED';
 IF unique_n<>expected_n THEN RAISE EXCEPTION 'DUPLICATE_OR_UNSAFE_FOTMOB_ID'; END IF;

 WITH evidence AS (
  SELECT x.* FROM jsonb_to_recordset(p_rows) x(
   source_key text,external_event_id text,fetched_at timestamptz,
   kickoff_utc timestamptz,updated_at timestamptz,match_id text,
   identity_status text,raw jsonb,detail_raw jsonb)
 )
 SELECT count(*) INTO eligible_n
 FROM evidence e JOIN public.phase15_source_shadow_current s
 ON s.source_key=e.source_key AND s.external_event_id=e.external_event_id
 WHERE s.source_key='FOTMOB' AND s.match_id IS NULL
  AND s.identity_status='UNMATCHED'
  AND s.kickoff_utc<now()-interval '7 days'
  AND s.fetched_at<now()-interval '7 days'
  AND s.updated_at<now()-interval '6 days'
  AND s.fetched_at=e.fetched_at
  AND s.kickoff_utc=e.kickoff_utc
  AND s.updated_at=e.updated_at
  AND s.raw IS NOT DISTINCT FROM e.raw
  AND s.detail_raw IS NOT DISTINCT FROM e.detail_raw
  AND NOT EXISTS(SELECT 1 FROM public.phase2_match_lineup_evidence l
    WHERE l.match_id IN ('FM:'||s.external_event_id,'FOTMOB:'||s.external_event_id))
  AND NOT EXISTS(SELECT 1 FROM public.fixture_identity_redirects rd
    WHERE rd.source_match_id IN ('FM:'||s.external_event_id,'FOTMOB:'||s.external_event_id)
       OR rd.target_match_id IN ('FM:'||s.external_event_id,'FOTMOB:'||s.external_event_id));
 IF eligible_n<>expected_n THEN RAISE EXCEPTION 'FOTMOB_COLD_ROW_CHANGED_OR_PROTECTED'; END IF;

 WITH evidence AS (
  SELECT x.* FROM jsonb_to_recordset(p_rows) x(
   source_key text,external_event_id text,fetched_at timestamptz,
   kickoff_utc timestamptz,updated_at timestamptz,raw jsonb,detail_raw jsonb)
 ), deleted AS (
  DELETE FROM public.phase15_source_shadow_current s USING evidence e
  WHERE s.source_key=e.source_key AND s.external_event_id=e.external_event_id
   AND s.source_key='FOTMOB' AND s.match_id IS NULL AND s.identity_status='UNMATCHED'
   AND s.kickoff_utc<now()-interval '7 days'
   AND s.fetched_at<now()-interval '7 days'
   AND s.updated_at<now()-interval '6 days'
   AND s.fetched_at=e.fetched_at AND s.kickoff_utc=e.kickoff_utc
   AND s.updated_at=e.updated_at
   AND s.raw IS NOT DISTINCT FROM e.raw
   AND s.detail_raw IS NOT DISTINCT FROM e.detail_raw
   AND NOT EXISTS(SELECT 1 FROM public.phase2_match_lineup_evidence l
    WHERE l.match_id IN ('FM:'||s.external_event_id,'FOTMOB:'||s.external_event_id))
   AND NOT EXISTS(SELECT 1 FROM public.fixture_identity_redirects rd
    WHERE rd.source_match_id IN ('FM:'||s.external_event_id,'FOTMOB:'||s.external_event_id)
       OR rd.target_match_id IN ('FM:'||s.external_event_id,'FOTMOB:'||s.external_event_id))
  RETURNING s.external_event_id
 ) SELECT count(*) INTO deleted_n FROM deleted;
 IF deleted_n<>expected_n THEN RAISE EXCEPTION 'FOTMOB_COLD_RETIRE_ROLLED_BACK'; END IF;
 RETURN deleted_n;
END $fn$;

REVOKE ALL ON FUNCTION public.ft_fotmob_cold_unmatched_candidates(integer)
 FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.ft_retire_verified_fotmob_cold_batch(jsonb,text,text,integer)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ft_fotmob_cold_unmatched_candidates(integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.ft_retire_verified_fotmob_cold_batch(jsonb,text,text,integer) TO service_role;
