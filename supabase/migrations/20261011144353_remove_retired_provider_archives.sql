-- Owner explicitly ordered complete retirement on 2026-10-11.
-- Inspected recursive dependencies: only these six legacy views consume the four archives.
-- RESTRICT makes unexpected dependencies fail and roll back, never cascade into native fixtures.
SET lock_timeout = '5s';
DROP VIEW IF EXISTS public.live_expected_actual_feed_current;
DROP VIEW IF EXISTS public.phase3_legacy_live_authority_health_v;
DROP VIEW IF EXISTS public.phase3_legacy_live_authority_v;
DROP VIEW IF EXISTS public.live_expected_actual_current;
DROP VIEW IF EXISTS public.market_odds_current;
DROP VIEW IF EXISTS public.team_power_current;
DROP TABLE IF EXISTS public.legacy_fixture_authority_archive;
DROP TABLE IF EXISTS public.legacy_bookmaker_odds_archive;
DROP TABLE IF EXISTS public.legacy_live_market_archive;
DROP TABLE IF EXISTS public.legacy_team_power_archive;
DELETE FROM public.source_health WHERE source ILIKE '%HKJC%';
NOTIFY pgrst, 'reload schema';
