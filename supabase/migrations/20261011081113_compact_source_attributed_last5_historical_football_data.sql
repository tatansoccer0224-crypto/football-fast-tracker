
create or replace function public.ft_historical_form_by_team(
  p_team_name text, p_league_name text, p_fixture_kickoff timestamptz
)
returns jsonb
language sql stable security invoker
set search_path=public,pg_temp
as $$
with league as (
  select case p_league_name
    when 'Premier League' then 'E0'
    when 'Championship' then 'E1'
    when 'League One' then 'E2'
    when 'League Two' then 'E3'
    when 'Ligue 1' then 'F1'
    when 'Ligue 2' then 'F2'
    when 'Serie A' then 'I1'
    when 'Serie B' then 'I2'
    when 'LaLiga' then 'SP1'
    when 'LaLiga 2' then 'SP2'
    when 'Bundesliga' then 'D1'
    when '2. Bundesliga' then 'D2'
    when 'Eredivisie' then 'N1'
    when 'Primeira Liga' then 'P1'
    when 'Scottish Premiership' then 'SC0'
    else null end league_code,
    regexp_replace(lower(coalesce(p_team_name,'')),'[^a-z0-9]','','g') team_name_key
),
prior as (
select m.match_date,m.match_key,m.fthg,m.ftag,m.ftr,
  regexp_replace(lower(m.home_team),'[^a-z0-9]','','g')=(select team_name_key from league) as home_side
from public.football_data_matches m
where m.source_kind='RESULTS'
  and m.league_code=(select league_code from league)
  and (select team_name_key from league)<>''
  and m.match_date<(p_fixture_kickoff at time zone 'Europe/London')::date
  and m.ftr in ('H','D','A') and m.fthg is not null and m.ftag is not null
  and m.fthg>=0 and m.ftag>=0
  and (
    regexp_replace(lower(m.home_team),'[^a-z0-9]','','g')=(select team_name_key from league)
    or regexp_replace(lower(m.away_team),'[^a-z0-9]','','g')=(select team_name_key from league)
  )
order by m.match_date desc,m.match_key desc
limit 5
),
outcomes as (
select match_date,match_key,
  case when ftr='D' then 'D'
       when (home_side and ftr='H') or (not home_side and ftr='A') then 'W'
       else 'L' end result,
  case when home_side then fthg else ftag end goals_for,
  case when home_side then ftag else fthg end goals_against
from prior
),
summary as (
select count(*) n,
  string_agg(result,'' order by match_date desc,match_key desc) sequence,
  count(*) filter(where result='W') wins,
  count(*) filter(where result='D') draws,
  count(*) filter(where result='L') losses,
  sum(goals_for) goals_for,sum(goals_against) goals_against,
  max(match_date) last_match_date
from outcomes
)
select case when n>=3 then jsonb_build_object(
  'source','football-data.co.uk',
  'scope','domestic-league-results-only',
  'resultsNewestFirst',sequence,
  'matches',n,'wins',wins,'draws',draws,'losses',losses,
  'goalsFor',goals_for,'goalsAgainst',goals_against,
  'throughDate',last_match_date,
  'limitedToFileCoverage',true
) else null end from summary;
$$;
revoke all on function public.ft_historical_form_by_team(text,text,timestamptz) from public,anon,authenticated;
grant execute on function public.ft_historical_form_by_team(text,text,timestamptz) to service_role;
comment on function public.ft_historical_form_by_team(text,text,timestamptz) is
'Compact observed last-five played domestic league results, by exact normalized team and source league code, strictly before fixture, >=3 observations. Not live stats, not current strength, no guessing aliases.';
