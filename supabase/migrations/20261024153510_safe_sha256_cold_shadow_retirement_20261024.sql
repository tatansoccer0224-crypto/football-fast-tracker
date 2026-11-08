
-- Retire ONLY full SHA256-backed obsolete unmatched Flashscore source records.
-- Never retire active/linked matches, canonical fixtures or verified results.
CREATE OR REPLACE FUNCTION public.ft_retire_verified_shadow_cold_batch(
  p_rows jsonb,
  p_storage_path text,
  p_archive_sha text,
  p_archive_bytes integer
) RETURNS integer
LANGUAGE plpgsql
SET search_path = pg_catalog, public, private, storage, pg_temp
AS $function$
DECLARE
  v_expected integer;
  v_distinct integer;
  v_eligible integer;
  v_deleted integer;
BEGIN
  PERFORM pg_advisory_xact_lock(20261024, 77);
  IF p_archive_sha !~ '^[a-f0-9]{64}$'
     OR p_storage_path !~ '^shadow-cold/v1/FLASHSCORE/[0-9]{4}-[0-9]{2}-[0-9]{2}/[a-f0-9]{64}[.]jsonl[.]txt$'
     OR right(p_storage_path,length(p_archive_sha || '.jsonl.txt')) <> p_archive_sha || '.jsonl.txt'
  THEN RAISE EXCEPTION 'INVALID_SHADOW_ARCHIVE_SHA_PATH'; END IF;

  IF p_archive_bytes < 100 OR p_archive_bytes > 2800000
     OR NOT EXISTS (
       SELECT 1 FROM storage.objects o
       WHERE o.bucket_id='fast-tracker-ingest'
         AND o.name=p_storage_path
         AND o.metadata->>'size'=p_archive_bytes::text
     )
  THEN RAISE EXCEPTION 'SHADOW_ARCHIVE_OBJECT_NOT_PRESENT'; END IF;

  IF jsonb_typeof(p_rows)<>'array'
  THEN RAISE EXCEPTION 'INVALID_SHADOW_BATCH'; END IF;
  v_expected:=jsonb_array_length(p_rows);
  IF v_expected < 1 OR v_expected > 80
  THEN RAISE EXCEPTION 'SHADOW_BATCH_BOUND_EXCEEDED'; END IF;

  SELECT count(DISTINCT e->>'external_event_id') INTO v_distinct
  FROM jsonb_array_elements(p_rows) e
  WHERE e->>'source_key'='FLASHSCORE'
    AND e->>'external_event_id' ~ '^[A-Za-z0-9_-]{5,32}$'
    AND e->>'match_id' IS NULL
    AND e->>'identity_status'='UNMATCHED';
  IF v_distinct<>v_expected
  THEN RAISE EXCEPTION 'DUPLICATE_OR_UNSAFE_SHADOW_EVENT_IDS'; END IF;

  WITH evidence AS (
    SELECT x.source_key,x.external_event_id,x.fetched_at,x.kickoff_utc,
           x.updated_at,x.match_id,x.identity_status,x.raw,x.detail_raw
    FROM jsonb_to_recordset(p_rows) AS x(
      source_key text,external_event_id text,
      fetched_at timestamptz,kickoff_utc timestamptz,
      updated_at timestamptz,match_id text,identity_status text,
      raw jsonb,detail_raw jsonb
    )
  )
  SELECT count(*) INTO v_eligible
  FROM evidence e JOIN public.phase15_source_shadow_current s
       ON s.source_key=e.source_key AND s.external_event_id=e.external_event_id
  WHERE s.source_key='FLASHSCORE'
    AND s.identity_status='UNMATCHED' AND s.match_id IS NULL
    AND s.kickoff_utc<now()-interval '7 days'
    AND s.fetched_at<now()-interval '7 days'
    AND s.updated_at<now()-interval '6 days'
    AND s.kickoff_utc=e.kickoff_utc AND s.fetched_at=e.fetched_at
    AND s.updated_at=e.updated_at
    AND s.raw IS NOT DISTINCT FROM e.raw
    AND s.detail_raw IS NOT DISTINCT FROM e.detail_raw
    AND NOT EXISTS (SELECT 1 FROM public.matches m
      WHERE m.canonical_event_id='FS:'||s.external_event_id)
    AND NOT EXISTS (SELECT 1 FROM private.ft_verified_flashscore_results r
      WHERE r.match_id='FS:'||s.external_event_id)
    AND NOT EXISTS (SELECT 1 FROM public.fixture_identity_redirects rd
      WHERE rd.source_match_id='FS:'||s.external_event_id
         OR rd.target_match_id='FS:'||s.external_event_id);
  IF v_eligible<>v_expected
  THEN RAISE EXCEPTION 'ARCHIVED_SHADOW_SOURCE_CHANGED_OR_PROTECTED'; END IF;

  WITH evidence AS (
    SELECT x.source_key,x.external_event_id,x.fetched_at,x.kickoff_utc,
           x.updated_at,x.raw,x.detail_raw
    FROM jsonb_to_recordset(p_rows) AS x(
      source_key text,external_event_id text,
      fetched_at timestamptz,kickoff_utc timestamptz,
      updated_at timestamptz,raw jsonb,detail_raw jsonb
    )
  ), removed AS (
    DELETE FROM public.phase15_source_shadow_current s USING evidence e
    WHERE s.source_key=e.source_key AND s.external_event_id=e.external_event_id
      AND s.source_key='FLASHSCORE'
      AND s.identity_status='UNMATCHED' AND s.match_id IS NULL
      AND s.kickoff_utc<now()-interval '7 days'
      AND s.fetched_at<now()-interval '7 days'
      AND s.updated_at<now()-interval '6 days'
      AND s.kickoff_utc=e.kickoff_utc AND s.fetched_at=e.fetched_at
      AND s.updated_at=e.updated_at
      AND s.raw IS NOT DISTINCT FROM e.raw
      AND s.detail_raw IS NOT DISTINCT FROM e.detail_raw
      AND NOT EXISTS (SELECT 1 FROM public.matches m
        WHERE m.canonical_event_id='FS:'||s.external_event_id)
      AND NOT EXISTS (SELECT 1 FROM private.ft_verified_flashscore_results r
        WHERE r.match_id='FS:'||s.external_event_id)
      AND NOT EXISTS (SELECT 1 FROM public.fixture_identity_redirects rd
        WHERE rd.source_match_id='FS:'||s.external_event_id
           OR rd.target_match_id='FS:'||s.external_event_id)
    RETURNING s.external_event_id
  )
  SELECT count(*) INTO v_deleted FROM removed;
  IF v_deleted<>v_expected THEN RAISE EXCEPTION 'SHADOW_RETIRE_ROLLBACK'; END IF;
  RETURN v_deleted;
END
$function$;

REVOKE ALL ON FUNCTION public.ft_retire_verified_shadow_cold_batch(jsonb,text,text,integer)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ft_retire_verified_shadow_cold_batch(jsonb,text,text,integer)
TO service_role;
