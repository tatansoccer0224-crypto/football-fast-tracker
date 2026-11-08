CREATE OR REPLACE VIEW public.system_health_current_v WITH (security_invoker=true) AS  WITH expected(source, metric, component, max_age_minutes, priority) AS (
         VALUES ('FLASHSCORE_SCORE'::text,'verified_score_only'::text,'Native Live Score'::text,25,1), ('LIVE_LAYER_GUARD'::text,'heartbeat'::text,'Live Layer'::text,3,1), ('LIVE_SOURCE_SHADOW'::text,'heartbeat'::text,'Live Shadow Source'::text,5,2), ('LIVE_SHADOW_COMPARE'::text,'heartbeat'::text,'Live Shadow Compare'::text,3,2), ('FRONTEND_ROUTE_GUARD'::text,'heartbeat'::text,'Frontend Routes'::text,10,1), ('PHASE1_COVERAGE_GUARD'::text,'48h'::text,'Phase 1 Coverage'::text,30,2), ('API_FOOTBALL_PHASE2'::text,'base'::text,'Phase 2 Base'::text,390,2), ('API_FOOTBALL_PHASE2'::text,'detail'::text,'Phase 2 Detail'::text,45,2), ('TEAM_ALIAS_V2'::text,'registry'::text,'Alias Registry'::text,90,2), ('GITHUB_OIDC_INGEST'::text,'forebet_current.csv'::text,'Forebet Feed'::text,1560,2), ('FOOTBALL_DATA_EDGE'::text,'heartbeat'::text,'Football-Data'::text,1620,3), ('PHASE1_CORE_REFRESH'::text,'decoupled'::text,'Prematch Core'::text,30,1), ('PHASE15_FLASHSCORE_SCOUT'::text,'6h'::text,'Flashscore Scout'::text,45,1), ('FLASHSCORE_BET365'::text,'odds_pipeline_health'::text,'Prematch Odds'::text,25,2), ('FOREBET_COVERAGE'::text,'verified_upcoming_72h'::text,'Forebet Coverage'::text,65,2), ('PHASE2_LINEUP_COVERAGE'::text,'hourly'::text,'Lineup Coverage'::text,95,2), ('SUPABASE_DATABASE'::text,'capacity_500mb'::text,'Database Capacity'::text,95,1)
        ), source_rows AS (
         SELECT e.component,
            e.priority,
            e.max_age_minutes,
            h.source,
            h.metric,
            h.status AS raw_status,
            h.value_text,
            h.notes,
            h.observed_at,
                CASE
                    WHEN (h.observed_at IS NULL) THEN NULL::numeric
                    ELSE round((EXTRACT(epoch FROM (now() - h.observed_at)) / 60.0), 1)
                END AS age_minutes
           FROM (expected e
             LEFT JOIN source_health h ON (((h.source = e.source) AND (h.metric = e.metric))))
        ), normalized AS (
         SELECT source_rows.component,
            source_rows.priority,
            source_rows.source,
            source_rows.metric,
            source_rows.raw_status,
            source_rows.value_text,
            source_rows.notes,
            source_rows.observed_at,
            source_rows.age_minutes,
            source_rows.max_age_minutes,
                CASE
                    WHEN (source_rows.observed_at IS NULL) THEN 'MISSING'::text
                    WHEN (source_rows.age_minutes > (source_rows.max_age_minutes)::numeric) THEN 'STALE'::text
                    WHEN (upper(COALESCE(source_rows.raw_status, ''::text)) = ANY (ARRAY['FAIL'::text, 'FAILED'::text, 'ERROR'::text, 'STALE'::text, 'CRITICAL'::text])) THEN 'FAIL'::text
                    WHEN (upper(COALESCE(source_rows.raw_status, ''::text)) = ANY (ARRAY['WARN'::text, 'WARNING'::text, 'DEGRADED'::text, 'PARTIAL'::text])) THEN 'WARN'::text
                    WHEN (upper(COALESCE(source_rows.raw_status, ''::text)) = ANY (ARRAY['OK'::text, 'PASS'::text, 'SUCCESS'::text, 'ACTIVE'::text, 'IDLE'::text, 'WAITING_LINEUP'::text, 'QUOTA_GUARD'::text, 'INFO'::text])) THEN 'OK'::text
                    ELSE 'INFO'::text
                END AS health_state
           FROM source_rows
        ), polymarket AS (
         SELECT 'Polymarket'::text AS component,
            2 AS priority,
            'POLYMARKET'::text AS source,
            'market_quotes'::text AS metric,
            p.last_status AS raw_status,
            (p.last_row_count)::text AS value_text,
            p.last_error AS notes,
            COALESCE(p.last_success_at, p.last_attempt_at, p.updated_at) AS observed_at,
                CASE
                    WHEN (COALESCE(p.last_success_at, p.last_attempt_at, p.updated_at) IS NULL) THEN NULL::numeric
                    ELSE round((EXTRACT(epoch FROM (now() - COALESCE(p.last_success_at, p.last_attempt_at, p.updated_at))) / 60.0), 1)
                END AS age_minutes,
            (5)::numeric AS max_age_minutes,
                CASE
                    WHEN (COALESCE(p.last_success_at, p.last_attempt_at, p.updated_at) IS NULL) THEN 'MISSING'::text
                    WHEN ((EXTRACT(epoch FROM (now() - COALESCE(p.last_success_at, p.last_attempt_at, p.updated_at))) / 60.0) > (5)::numeric) THEN 'STALE'::text
                    WHEN (upper(COALESCE(p.last_status, ''::text)) = ANY (ARRAY['FAIL'::text, 'FAILED'::text, 'ERROR'::text])) THEN 'FAIL'::text
                    WHEN (upper(COALESCE(p.last_status, ''::text)) = ANY (ARRAY['WARN'::text, 'WARNING'::text, 'DEGRADED'::text])) THEN 'WARN'::text
                    WHEN (upper(COALESCE(p.last_status, ''::text)) = 'SUCCESS'::text) THEN 'OK'::text
                    ELSE 'INFO'::text
                END AS health_state
           FROM phase4.provider_ingest_health p
          WHERE (p.provider_id = 'POLYMARKET'::text)
        )
 SELECT normalized.component,
    normalized.priority,
    normalized.source,
    normalized.metric,
    normalized.raw_status,
    normalized.value_text,
    normalized.notes,
    normalized.observed_at,
    normalized.age_minutes,
    normalized.max_age_minutes,
    normalized.health_state
   FROM normalized
UNION ALL
 SELECT polymarket.component,
    polymarket.priority,
    polymarket.source,
    polymarket.metric,
    polymarket.raw_status,
    polymarket.value_text,
    polymarket.notes,
    polymarket.observed_at,
    polymarket.age_minutes,
    polymarket.max_age_minutes,
    polymarket.health_state
   FROM polymarket;
