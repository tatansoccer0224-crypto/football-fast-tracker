-- Future-only, zero-ingest operational health contract (Phase 53).
-- No table writes, new cron jobs, historical replay, HKJC, or forecast promotion.
BEGIN;
SET LOCAL lock_timeout='1500ms';
SET LOCAL statement_timeout='12000ms';

CREATE OR REPLACE FUNCTION public.ft_future_health_snapshot(
    p_database_quota_bytes bigint DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO pg_catalog, public, private
AS $fn$
DECLARE
    v_now timestamptz := now();
    v_season text;
    v_files integer := 0;
    v_files_ok integer := 0;
    v_files_fresh integer := 0;
    v_fd_latest timestamptz;
    v_fd_oldest timestamptz;
    v_fs_latest timestamptz;
    v_fs_soon integer := 0;
    v_freezes integer := 0;
    v_freezes_before_kickoff integer := 0;
    v_last_freeze timestamptz;
    v_db_bytes bigint;
    v_fd_state text;
    v_fs_state text;
BEGIN
    IF p_database_quota_bytes IS NOT NULL AND p_database_quota_bytes < 1 THEN
        RAISE EXCEPTION 'DATABASE_QUOTA_MUST_BE_POSITIVE' USING ERRCODE='22023';
    END IF;

    SELECT MAX(season) INTO v_season
    FROM public.football_data_files
    WHERE source_kind='RESULTS' AND status='OK';

    SELECT COUNT(*)::integer,
           COUNT(*) FILTER (WHERE status='OK')::integer,
           COUNT(*) FILTER (
             WHERE status='OK'
               AND last_success_at BETWEEN v_now - interval '36 hours' AND v_now + interval '5 minutes'
           )::integer,
           MAX(last_success_at),
           MIN(last_success_at) FILTER (WHERE status='OK')
      INTO v_files,v_files_ok,v_files_fresh,v_fd_latest,v_fd_oldest
    FROM public.football_data_files
    WHERE source_kind='RESULTS' AND season=v_season;

    v_fd_state := CASE
      WHEN v_files = 0 THEN 'UNKNOWN'
      WHEN v_files >= 22 AND v_files_ok=v_files AND v_files_fresh=v_files THEN 'HEALTHY'
      ELSE 'DEGRADED'
    END;

    SELECT MAX(fetched_at),
           COUNT(*) FILTER (
             WHERE kickoff_hkt > v_now AND kickoff_hkt < v_now + interval '48 hours'
           )::integer
      INTO v_fs_latest,v_fs_soon
    FROM public.flashscore_primary_fixture_current
    WHERE kickoff_hkt BETWEEN v_now - interval '12 hours' AND v_now + interval '48 hours';

    v_fs_state := CASE
      WHEN v_fs_latest IS NULL THEN 'UNKNOWN'
      WHEN v_fs_latest >= v_now - interval '30 minutes'
       AND v_fs_latest <= v_now + interval '5 minutes' THEN 'HEALTHY'
      ELSE 'STALE'
    END;

    SELECT COUNT(*)::integer,
           COUNT(*) FILTER (WHERE frozen_at < kickoff_utc)::integer,
           MAX(frozen_at)
      INTO v_freezes,v_freezes_before_kickoff,v_last_freeze
    FROM private.ft_native_prospective_frozen;

    SELECT pg_database_size(current_database()) INTO v_db_bytes;

    RETURN jsonb_build_object(
      'schemaVersion', 1,
      'checkedAt', v_now,
      'sources', jsonb_build_object(
        'footballData', jsonb_build_object(
          'state', v_fd_state,
          'season', v_season,
          'expectedMinimumFiles', 22,
          'trackedFiles', v_files,
          'okFiles', v_files_ok,
          'freshFiles', v_files_fresh,
          'lastSuccessAt', v_fd_latest,
          'oldestFileSuccessAt', v_fd_oldest,
          'freshnessWindowHours', 36
        ),
        'flashscore', jsonb_build_object(
          'state', v_fs_state,
          'next48hFixtures', v_fs_soon,
          'lastFixtureFetchAt', v_fs_latest,
          'freshnessWindowMinutes', 30
        )
      ),
      'prospective', jsonb_build_object(
        'frozenPredictions', v_freezes,
        'frozenBeforeKickoff', v_freezes_before_kickoff,
        'lastFrozenAt', v_last_freeze,
        'publicationState', 'NOT_AUTHORIZED_BY_HEALTH_CHECK',
        'validationState', CASE
          WHEN v_freezes_before_kickoff=0 THEN 'NO_PROSPECTIVE_EVIDENCE'
          ELSE 'PROSPECTIVE_SAMPLE_UNASSESSED'
        END
      ),
      'database', jsonb_build_object(
        'bytes', v_db_bytes,
        'quotaBytes', p_database_quota_bytes,
        'usagePercent', CASE WHEN p_database_quota_bytes IS NULL THEN NULL
                        ELSE round(v_db_bytes::numeric * 100 / p_database_quota_bytes,2) END,
        'quotaState', CASE
          WHEN p_database_quota_bytes IS NULL THEN 'UNKNOWN'
          WHEN v_db_bytes::numeric * 100 >= p_database_quota_bytes::numeric * 80 THEN 'AT_OR_ABOVE_80_PERCENT'
          ELSE 'BELOW_80_PERCENT'
        END
      ),
      'semantics', 'UNKNOWN_IS_NOT_ZERO; SCHEDULER_SUCCESS_IS_NOT_SOURCE_FRESHNESS; HEALTH_IS_NOT_MODEL_APPROVAL'
    );
END;
$fn$;

REVOKE ALL ON FUNCTION public.ft_future_health_snapshot(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ft_future_health_snapshot(bigint) TO service_role;
COMMENT ON FUNCTION public.ft_future_health_snapshot(bigint) IS
 'Internal read-only, zero-ingest future source/freeze/quota health snapshot. Service-role only. NULL quota remains UNKNOWN. Never authorizes model publishing.';
COMMIT;
