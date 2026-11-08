
-- Internal candidate selector. A read-only SECURITY DEFINER path is needed
-- because the protection guards reference private verified result history.
CREATE OR REPLACE FUNCTION public.ft_shadow_cold_unmatched_candidates(p_limit integer DEFAULT 80)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, pg_temp
AS $function$
DECLARE answer jsonb;
BEGIN
  IF p_limit < 1 OR p_limit > 80
  THEN RAISE EXCEPTION 'SHADOW_RETENTION_READ_BOUND_EXCEEDED'; END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.kickoff_utc,c.external_event_id),'[]'::jsonb)
    INTO answer
  FROM (
    SELECT s.*
    FROM public.phase15_source_shadow_current s
    WHERE s.source_key='FLASHSCORE'
      AND s.identity_status='UNMATCHED'
      AND s.match_id IS NULL
      AND s.kickoff_utc<now()-interval '7 days'
      AND s.fetched_at<now()-interval '7 days'
      AND s.updated_at<now()-interval '6 days'
      AND NOT EXISTS (SELECT 1 FROM public.matches m
        WHERE m.canonical_event_id='FS:'||s.external_event_id)
      AND NOT EXISTS (SELECT 1 FROM private.ft_verified_flashscore_results r
        WHERE r.match_id='FS:'||s.external_event_id)
      AND NOT EXISTS (SELECT 1 FROM public.fixture_identity_redirects rd
        WHERE rd.source_match_id='FS:'||s.external_event_id
           OR rd.target_match_id='FS:'||s.external_event_id)
    ORDER BY s.kickoff_utc,s.external_event_id
    LIMIT p_limit
  ) AS c;
  RETURN answer;
END
$function$;
REVOKE ALL ON FUNCTION public.ft_shadow_cold_unmatched_candidates(integer)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ft_shadow_cold_unmatched_candidates(integer) TO service_role;
