CREATE OR REPLACE FUNCTION private.ft_native_model_training_slice(p_source text, p_league text, p_asof timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog', 'private', 'public', 'pg_temp'
AS $function$
DECLARE n integer; payload jsonb;
BEGIN
 IF p_source NOT IN ('FS_VERIFIED','FOOTBALL_DATA') 
   OR p_league IS NULL OR p_league !~ '^[A-Za-z0-9]{1,16}$'
   OR p_asof IS NULL OR p_asof<now()-interval '1 day'
   OR p_asof>now()+interval '1 minute'
 THEN RAISE EXCEPTION 'INVALID_NATIVE_MODEL_SOURCE_OR_CUTOFF'; END IF;
 WITH both_sources AS(
   SELECT r.kickoff_utc played_at,
     jsonb_build_object(
       'source','FS_VERIFIED','league',r.league_id,
       'homeId',r.home_team_id,'awayId',r.away_team_id,
       'hg',r.home_goals,'ag',r.away_goals,
       'hc',r.home_corners,'ac',r.away_corners,
       'playedAt',r.kickoff_utc,'capturedAt',r.source_captured_at,
       'provenance','FLASHSCORE_EXACT_PROVIDER_FINAL') row
   FROM private.ft_verified_flashscore_results r
   WHERE p_source='FS_VERIFIED' AND r.league_id=p_league
     AND r.kickoff_utc<p_asof AND r.source_captured_at<=p_asof
     AND r.kickoff_utc>p_asof-interval '365 days'
   UNION ALL
   SELECT (d.match_date::timestamp AT TIME ZONE 'UTC') played_at,
     jsonb_build_object(
       'source','FOOTBALL_DATA','league',d.league_code,
       'homeId',d.home_team,'awayId',d.away_team,
       'hg',d.fthg,'ag',d.ftag,
       'hc',d.home_corners,'ac',d.away_corners,
       'playedAt',(d.match_date::timestamp AT TIME ZONE 'UTC'),
       'capturedAt',d.fetched_at,
       'provenance','FOOTBALL_DATA_ORIGINAL_CSV_SCORING') row
   FROM public.football_data_matches d
   WHERE p_source='FOOTBALL_DATA' AND d.league_code=p_league
     AND d.source_kind='RESULTS'
     AND d.match_date<(p_asof AT TIME ZONE 'UTC')::date
     AND d.fetched_at<=p_asof
     AND d.match_date>(p_asof AT TIME ZONE 'UTC')::date-365
     AND d.fthg BETWEEN 0 AND 20 AND d.ftag BETWEEN 0 AND 20
     AND d.match_key IS NOT NULL AND d.source_file IS NOT NULL
 ), bounded AS (
   SELECT row,played_at FROM both_sources ORDER BY played_at DESC LIMIT 250
 )
 SELECT count(*),coalesce(jsonb_agg(row ORDER BY played_at ASC),'[]'::jsonb)
 INTO n,payload FROM bounded;
 RETURN jsonb_build_object(
   'source',p_source,'league',p_league,
   'asOf',p_asof,
   'count',n,'status',CASE WHEN n>=60 THEN 'TRAINING_SAMPLE_AVAILABLE'
          ELSE 'INSUFFICIENT_LEAGUE_RESULTS' END,
   'rows',payload,
   'model_contract','FAST_TRACKER_INDEPENDENT_POISSON_V0');
END;
$function$
;
