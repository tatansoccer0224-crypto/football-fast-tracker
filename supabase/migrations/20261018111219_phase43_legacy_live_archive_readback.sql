-- Phase 43: full backup/read-only restore check of obsolete Oct 7-10 LIVE rows.
-- 15 rows in each legacy table; no current Flashscore FS IDs or recent fixtures.
-- No data mutation. Service-role only.
CREATE OR REPLACE FUNCTION public.ft_legacy_live_archive_read(p_kind text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path TO pg_catalog,public,private,pg_temp
AS $fn$
DECLARE v_rows jsonb;
BEGIN
 IF p_kind='score' THEN
   SELECT jsonb_agg(to_jsonb(t) ORDER BY canonical_event_id) INTO v_rows
   FROM public.live_score_current t;
 ELSIF p_kind='stats' THEN
   SELECT jsonb_agg(to_jsonb(t) ORDER BY canonical_event_id) INTO v_rows
   FROM public.live_stats_current t;
 ELSE RAISE EXCEPTION 'UNSUPPORTED_LEGACY_LIVE_TABLE'; END IF;
 RETURN coalesce(v_rows,'[]'::jsonb);
END;
$fn$;
REVOKE ALL ON FUNCTION public.ft_legacy_live_archive_read(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ft_legacy_live_archive_read(text) TO service_role;

CREATE OR REPLACE FUNCTION public.ft_legacy_live_archive_restore_check(
  p_kind text,p_rows jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path TO pg_catalog,public,private,pg_temp
AS $fn$
DECLARE v_original jsonb;
DECLARE v_count integer;
BEGIN
 IF p_kind NOT IN ('score','stats') OR jsonb_typeof(p_rows)<>'array'
 THEN RAISE EXCEPTION 'INVALID_ARCHIVE_KIND_OR_ARRAY'; END IF;
 v_count:=jsonb_array_length(p_rows);
 IF v_count<>15 THEN RAISE EXCEPTION 'LEGACY_LIVE_ROW_COUNT_CHANGED'; END IF;
 IF EXISTS(
  SELECT 1 FROM jsonb_array_elements(p_rows) r
  WHERE r->>'canonical_event_id' !~ '^FB[0-9]{4,}$'
    OR (r->>'kickoff_hkt')::timestamptz >= now()-interval '7 days'
    OR (r->>'source') NOT IN ('FOOTBALL_LIVE_API_SELF_HOSTED','SPORTSCORE')
 ) THEN RAISE EXCEPTION 'ACTIVE_OR_NONLEGACY_ROW_IN_BACKUP'; END IF;
 IF EXISTS(
  SELECT 1 FROM jsonb_array_elements(p_rows) r
  JOIN public.flashscore_primary_fixture_current f
    ON f.match_id=r->>'canonical_event_id'
 ) THEN RAISE EXCEPTION 'CURRENT_FLASHSCORE_MATCH_IN_ARCHIVE'; END IF;
 v_original:=public.ft_legacy_live_archive_read(p_kind);
 IF v_original IS DISTINCT FROM p_rows THEN
   RAISE EXCEPTION 'LEGACY_LIVE_RESTORE_JSONB_ROW_MISMATCH'; END IF;
 RETURN jsonb_build_object('restoreDryRunValid',true,'kind',p_kind,
   'rowCount',v_count,'allRowsMatchDb',true,'staleLegacyOnly',true);
END;
$fn$;
REVOKE ALL ON FUNCTION public.ft_legacy_live_archive_restore_check(text,jsonb)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ft_legacy_live_archive_restore_check(text,jsonb) TO service_role;
