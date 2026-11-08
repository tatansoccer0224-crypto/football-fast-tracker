-- On-demand, source-exact prospective evaluation; no result data is
-- copied back into immutable forecasts and no extra recurring work.
CREATE OR REPLACE FUNCTION private.ft_native_prospective_assessment()
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER
SET search_path TO 'pg_catalog','private','public','pg_temp'
AS $fn$
WITH frozen AS(
 SELECT f.*,r.home_goals,r.away_goals,r.kickoff_utc result_kickoff,
 r.source_captured_at result_capture,r.league_id result_league,
 r.home_team_id result_home,r.away_team_id result_away
 FROM private.ft_native_prospective_frozen f
 LEFT JOIN private.ft_verified_flashscore_results r ON r.match_id=f.canonical_event_id
  AND r.kickoff_utc BETWEEN f.kickoff_utc-interval '1 minute'
                        AND f.kickoff_utc+interval '1 minute'
  AND r.source_captured_at>=f.kickoff_utc
  AND r.league_id=f.fs_league_id
  AND r.home_team_id=f.evidence->>'flashscore_home_team_id'
  AND r.away_team_id=f.evidence->>'flashscore_away_team_id'
), scored AS(
 SELECT f.*,
 CASE WHEN home_goals>away_goals THEN 'H'
      WHEN home_goals=away_goals THEN 'D'
      WHEN home_goals<away_goals THEN 'A' ELSE NULL END outcome
 FROM frozen f
), counts AS(
 SELECT count(*) total_frozen,
 count(*) FILTER (WHERE kickoff_utc>now()) upcoming,
 count(*) FILTER (WHERE outcome IS NOT NULL) verified_finished,
 count(*) FILTER (WHERE kickoff_utc<now()-interval '4 hours'
                  AND outcome IS NULL) unverified_past,
 count(*) FILTER (WHERE outcome IS NOT NULL AND
  CASE outcome WHEN 'H' THEN (score_probability->>'home')::numeric
    >=greatest((score_probability->>'draw')::numeric,
              (score_probability->>'away')::numeric)
    WHEN 'D' THEN (score_probability->>'draw')::numeric
    >=greatest((score_probability->>'home')::numeric,
              (score_probability->>'away')::numeric)
    ELSE (score_probability->>'away')::numeric
    >=greatest((score_probability->>'home')::numeric,
              (score_probability->>'draw')::numeric) END) correct_picks,
 avg(
 power((score_probability->>'home')::numeric-(outcome='H')::int,2)+
 power((score_probability->>'draw')::numeric-(outcome='D')::int,2)+
 power((score_probability->>'away')::numeric-(outcome='A')::int,2)
 ) FILTER (WHERE outcome IS NOT NULL) model_brier,
 avg(
 power((score_probability->>'baselineHome')::numeric-(outcome='H')::int,2)+
 power((score_probability->>'baselineDraw')::numeric-(outcome='D')::int,2)+
 power((score_probability->>'baselineAway')::numeric-(outcome='A')::int,2)
 ) FILTER (WHERE outcome IS NOT NULL) baseline_brier
 FROM scored
)
SELECT jsonb_build_object(
 'status',CASE WHEN verified_finished>=100 THEN 'DESCRIPTIVE_SAMPLE_READY'
               ELSE 'INSUFFICIENT_PROSPECTIVE_SAMPLE' END,
 'minimum_finished',100,'total_frozen',total_frozen,
 'upcoming',upcoming,'verified_finished',verified_finished,
 'unverified_past',unverified_past,
 'metrics',CASE WHEN verified_finished>=100 THEN
   jsonb_build_object('correct_pick_rate',round(correct_picks::numeric/verified_finished,6),
     'model_multiclass_brier',round(model_brier,6),
     'league_baseline_multiclass_brier',round(baseline_brier,6))
   ELSE NULL END,
 'source','IMMUTABLE_PREMATCH_FOOTBALL_DATA_SCORE_WITH_EXACT_FS_RESULTS',
 'warning','EXPERIMENTAL_NON_CROSS_VALIDATED; 100 EVENTS DOES NOT PROVE_CALIBRATION')
 FROM counts;
$fn$;
REVOKE ALL ON FUNCTION private.ft_native_prospective_assessment()
FROM PUBLIC,anon,authenticated;
