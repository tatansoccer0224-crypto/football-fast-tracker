-- Phase 41: service-role-only, read-only historical source snapshot backup source.
-- No DELETE/UPDATE, no new recurring capture, no anonymous/private schema exposure.
CREATE OR REPLACE FUNCTION public.ft_source_day_archive_read(p_source_key text,p_source_day date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path TO pg_catalog,public,private,pg_temp
AS $fn$
DECLARE
  v_today date := (now() at time zone 'Asia/Hong_Kong')::date;
  v_payload jsonb;
BEGIN
  IF p_source_key NOT IN ('FLASHSCORE','FOREBET')
     OR p_source_day IS NULL
     OR p_source_day < v_today-30
     OR p_source_day > v_today
  THEN RAISE EXCEPTION 'ARCHIVE_SOURCE_OR_DATE_OUT_OF_BOUNDS' USING errcode='22023'; END IF;
  SELECT to_jsonb(s) INTO v_payload
  FROM private.ft_source_day_snapshot s
  WHERE s.source_key=p_source_key AND s.source_day=p_source_day;
  RETURN v_payload;
END;
$fn$;
REVOKE ALL ON FUNCTION public.ft_source_day_archive_read(text,date) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ft_source_day_archive_read(text,date) TO service_role;

-- Read-only restore feasibility test on the exact downloaded snapshot.
-- It proves all 11 columns, row count, HKT window and source MD5 survive JSON
-- serialization; it does NOT mutate the production snapshot table.
CREATE OR REPLACE FUNCTION public.ft_source_day_archive_restore_check(p_snapshot jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path TO pg_catalog,public,private,pg_temp
AS $fn$
DECLARE
 v_key text;
 v_day date;
 v_start timestamptz;
 v_end timestamptz;
 v_count integer;
 v_rows jsonb;
 v_original jsonb;
BEGIN
 IF jsonb_typeof(p_snapshot)<>'object' THEN
   RAISE EXCEPTION 'INVALID_ARCHIVE_OBJECT'; END IF;
 IF (SELECT count(*) FROM jsonb_object_keys(p_snapshot))<>11 THEN
   RAISE EXCEPTION 'ARCHIVE_COLUMNS_CHANGED'; END IF;
 v_key:=p_snapshot->>'source_key';
 v_day:=(p_snapshot->>'source_day')::date;
 v_start:=(p_snapshot->>'window_start_utc')::timestamptz;
 v_end:=(p_snapshot->>'window_end_utc')::timestamptz;
 v_count:=(p_snapshot->>'record_count')::integer;
 v_rows:=p_snapshot->'source_rows';
 IF v_key NOT IN ('FLASHSCORE','FOREBET')
    OR v_day IS NULL OR v_day<(now() at time zone 'Asia/Hong_Kong')::date-30
    OR v_day>(now() at time zone 'Asia/Hong_Kong')::date
    OR v_start IS DISTINCT FROM (v_day::timestamp at time zone 'Asia/Hong_Kong')
    OR v_end IS DISTINCT FROM v_start + interval '24 hours'
    OR v_count NOT BETWEEN 1 AND 5000
    OR jsonb_typeof(v_rows)<>'array' OR jsonb_array_length(v_rows)<>v_count
    OR p_snapshot->>'capture_origin' NOT IN
       ('EXISTING_SOURCE_SHADOW_BACKFILL','EXISTING_FOREBET_HISTORY_BACKFILL','DIRECT_AUTHORIZED_SOURCE_CAPTURE')
    OR jsonb_typeof(p_snapshot->'coverage_complete')<>'boolean'
    OR p_snapshot->>'content_md5' !~ '^[a-f0-9]{32}$'
    OR md5(v_rows::text)<>p_snapshot->>'content_md5'
 THEN RAISE EXCEPTION 'ARCHIVE_RESTORE_CONSTRAINT_OR_MD5_FAILURE'; END IF;
 SELECT to_jsonb(s) INTO v_original FROM private.ft_source_day_snapshot s
 WHERE s.source_key=v_key AND s.source_day=v_day;
 IF v_original IS DISTINCT FROM p_snapshot THEN
   RAISE EXCEPTION 'ARCHIVE_RESTORE_DIFFERS_FROM_ORIGINAL'; END IF;
 RETURN jsonb_build_object('restoreDryRunValid',true,'sourceKey',v_key,
   'sourceDay',v_day,'recordCount',v_count,'sourceJsonMd5',md5(v_rows::text),
   'matchesCurrentDbRow',true);
END;
$fn$;
REVOKE ALL ON FUNCTION public.ft_source_day_archive_restore_check(jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ft_source_day_archive_restore_check(jsonb) TO service_role;
