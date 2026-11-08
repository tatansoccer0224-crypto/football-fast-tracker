-- Extend the existing recent domestic-league form response with observed
-- outcomes from the same dated football-data.co.uk match rows. These are
-- historical results, never upcoming prices or forecasts.
CREATE OR REPLACE FUNCTION public.ft_historical_form_by_team(
  p_team_name text,
  p_league_name text,
  p_fixture_kickoff timestamp with time zone
)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
WITH league AS (
  SELECT CASE p_league_name
    WHEN 'Premier League' THEN 'E0'
    WHEN 'Championship' THEN 'E1'
    WHEN 'League One' THEN 'E2'
    WHEN 'League Two' THEN 'E3'
    WHEN 'Ligue 1' THEN 'F1'
    WHEN 'Ligue 2' THEN 'F2'
    WHEN 'Serie A' THEN 'I1'
    WHEN 'Serie B' THEN 'I2'
    WHEN 'LaLiga' THEN 'SP1'
    WHEN 'LaLiga 2' THEN 'SP2'
    WHEN 'Bundesliga' THEN 'D1'
    WHEN '2. Bundesliga' THEN 'D2'
    WHEN 'Eredivisie' THEN 'N1'
    WHEN 'Primeira Liga' THEN 'P1'
    WHEN 'Scottish Premiership' THEN 'SC0'
    ELSE NULL
  END AS league_code,
  regexp_replace(lower(coalesce(p_team_name,'')),'[^a-z0-9]','','g') AS team_name_key
),
prior AS (
  SELECT m.match_date,m.match_key,m.fthg,m.ftag,m.ftr,
    m.home_corners,m.away_corners,
    regexp_replace(lower(m.home_team),'[^a-z0-9]','','g')=(SELECT team_name_key FROM league) AS home_side
  FROM public.football_data_matches m
  WHERE m.source_kind='RESULTS'
    AND m.league_code=(SELECT league_code FROM league)
    AND (SELECT team_name_key FROM league)<>''
    AND m.match_date<(p_fixture_kickoff AT TIME ZONE 'Europe/London')::date
    AND m.ftr IN ('H','D','A') AND m.fthg IS NOT NULL AND m.ftag IS NOT NULL
    AND m.fthg>=0 AND m.ftag>=0
    AND (
      regexp_replace(lower(m.home_team),'[^a-z0-9]','','g')=(SELECT team_name_key FROM league)
      OR regexp_replace(lower(m.away_team),'[^a-z0-9]','','g')=(SELECT team_name_key FROM league)
    )
  ORDER BY m.match_date DESC,m.match_key DESC
  LIMIT 5
),
outcomes AS (
  SELECT match_date,match_key,
    CASE WHEN ftr='D' THEN 'D'
         WHEN (home_side AND ftr='H') OR (NOT home_side AND ftr='A') THEN 'W'
         ELSE 'L' END AS result,
    CASE WHEN home_side THEN fthg ELSE ftag END AS goals_for,
    CASE WHEN home_side THEN ftag ELSE fthg END AS goals_against,
    CASE WHEN home_side THEN home_corners ELSE away_corners END AS corners_for,
    CASE WHEN home_side THEN away_corners ELSE home_corners END AS corners_against,
    fthg+ftag AS total_goals,
    CASE WHEN home_corners IS NOT NULL AND away_corners IS NOT NULL
      THEN home_corners+away_corners END AS total_corners
  FROM prior
),
summary AS (
  SELECT count(*) AS n,
    string_agg(result,'' ORDER BY match_date DESC,match_key DESC) AS sequence,
    count(*) FILTER(WHERE result='W') AS wins,
    count(*) FILTER(WHERE result='D') AS draws,
    count(*) FILTER(WHERE result='L') AS losses,
    sum(goals_for) AS goals_for,
    sum(goals_against) AS goals_against,
    max(match_date) AS last_match_date,
    count(*) FILTER(WHERE total_goals>2) AS over25_count,
    round(100.0*count(*) FILTER(WHERE total_goals>2)/NULLIF(count(*),0),1) AS over25_rate,
    round(avg(total_goals),1) AS avg_total_goals,
    count(*) FILTER(WHERE total_corners IS NOT NULL) AS matches_with_corners,
    round(avg(corners_for) FILTER(WHERE corners_for IS NOT NULL),1) AS avg_corners_for,
    round(avg(corners_against) FILTER(WHERE corners_against IS NOT NULL),1) AS avg_corners_against,
    round(avg(total_corners),1) AS avg_total_corners
  FROM outcomes
)
SELECT CASE WHEN n>=3 THEN jsonb_build_object(
  'source','football-data.co.uk',
  'scope','domestic-league-results-only',
  'resultsNewestFirst',sequence,
  'matches',n,'wins',wins,'draws',draws,'losses',losses,
  'goalsFor',goals_for,'goalsAgainst',goals_against,
  'throughDate',last_match_date,
  'over25Count',over25_count,'over25Rate',over25_rate,
  'averageGoals',avg_total_goals,
  'matchesWithCorners',matches_with_corners,
  'averageCornersFor',avg_corners_for,
  'averageCornersAgainst',avg_corners_against,
  'averageTotalCorners',avg_total_corners,
  'limitedToFileCoverage',true
) ELSE NULL END
FROM summary;
$function$;
