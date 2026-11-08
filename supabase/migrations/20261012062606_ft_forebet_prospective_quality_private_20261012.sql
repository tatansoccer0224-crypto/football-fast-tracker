-- One source-auditable assessment over immutable pre-kickoff Forebet archive.
-- Read-only on demand; no new table, crawler, cron, or public Data API exposure.
CREATE OR REPLACE FUNCTION private.ft_forebet_prospective_assessment()
RETURNS jsonb
LANGUAGE sql STABLE
SECURITY INVOKER
SET search_path TO 'pg_catalog','public','private','pg_temp'
AS $fn$
WITH archival AS (
  SELECT DISTINCT ON (a.match_id)
    a.match_id,a.captured_at,a.kickoff_hkt,
    a.prob_home/100.0 AS ph,a.prob_draw/100.0 AS pd,a.prob_away/100.0 AS pa,
    a.prediction_1x2 AS prediction,a.raw->'verified_final_result' AS outcome
  FROM public.forebet_archive a
  WHERE a.raw->>'archive_origin'='VERIFIED_PREKICKOFF_FOREBET'
    AND a.match_id ~ '^FS:[A-Za-z0-9]{6,16}$'
    AND a.kickoff_hkt IS NOT NULL
    AND a.captured_at <= a.kickoff_hkt
    AND a.prob_home BETWEEN 0 AND 100
    AND a.prob_draw BETWEEN 0 AND 100
    AND a.prob_away BETWEEN 0 AND 100
    AND (a.prob_home+a.prob_draw+a.prob_away) BETWEEN 98 AND 102
  ORDER BY a.match_id,a.captured_at ASC
), checked AS (
 SELECT a.*,
 CASE WHEN outcome->>'source'='FLASHSCORE'
       AND outcome->>'identity_gate'='EXACT_FS_PROVIDER_ID_AND_KICKOFF'
       AND outcome->>'match_id'=a.match_id
       AND outcome->>'home_goals' ~ '^[0-9]{1,2}$'
       AND outcome->>'away_goals' ~ '^[0-9]{1,2}$'
       AND outcome->>'source_captured_at' ~ '^20[0-9]{2}-'
       AND (outcome->>'source_captured_at')::timestamptz >= a.kickoff_hkt
       AND abs(extract(epoch FROM(
         (outcome->>'kickoff_utc')::timestamptz-a.kickoff_hkt)))<=1200
     THEN CASE
       WHEN (outcome->>'home_goals')::int>(outcome->>'away_goals')::int THEN '1'
       WHEN (outcome->>'home_goals')::int<(outcome->>'away_goals')::int THEN '2'
       ELSE 'X' END
     ELSE NULL END AS actual
 FROM archival a
), scored AS (
 SELECT c.*, 
   POWER(c.ph - CASE WHEN actual='1' THEN 1 ELSE 0 END,2) +
   POWER(c.pd - CASE WHEN actual='X' THEN 1 ELSE 0 END,2) +
   POWER(c.pa - CASE WHEN actual='2' THEN 1 ELSE 0 END,2) AS brier_multiclass,
   -LN(GREATEST(0.001,CASE actual WHEN '1' THEN c.ph WHEN 'X' THEN c.pd ELSE c.pa END)) AS logloss_capped
 FROM checked c WHERE c.actual IS NOT NULL
), counts AS (
 SELECT (SELECT count(*) FROM public.forebet_archive) AS archived_rows,
        (SELECT count(*) FROM archival) AS eligible_unique_pregame,
        (SELECT count(*) FROM checked WHERE actual IS NULL) AS missing_final,
        count(*) AS verified_final_n,
        count(*) FILTER(WHERE prediction=actual) AS correctly_picked,
        round(avg(brier_multiclass),6) AS brier,
        round(avg(logloss_capped),6) AS logloss
 FROM scored
)
SELECT jsonb_build_object(
 'status',CASE WHEN verified_final_n>=100 THEN 'DESCRIPTIVE_SAMPLE_READY'
               ELSE 'INSUFFICIENT_PROSPECTIVE_SAMPLE' END,
 'minimum_finished',100,
 'archived_rows',archived_rows,
 'unique_eligible_pregame',eligible_unique_pregame,
 'verified_finished',verified_final_n,
 'missing_confirmed_final',missing_final,
 'forebet_picked_correct_count',correctly_picked,
 'evaluation',CASE WHEN verified_final_n>=100 THEN
       jsonb_build_object('correct_pick_fraction',
         round(correctly_picked::numeric/nullif(verified_final_n,0),6),
         'multiclass_brier_0_to_2',brier,'capped_log_loss',logloss)
       ELSE NULL END,
 'policy',jsonb_build_object(
   'deduplication','earliest qualified pre-kickoff capture per canonical FS match',
   'source','FOREBET_PREMATCH_AND_FLASHSCORE_EXACT_FINAL',
   'late_source_excluded',true,
   'loss_probability_floor',0.001,
   'min_sample_not_significance_proof',true)
) FROM counts;
$fn$;

REVOKE ALL ON FUNCTION private.ft_forebet_prospective_assessment()
FROM PUBLIC,anon,authenticated;
