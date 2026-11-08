create or replace view public.phase2_lineup_coverage_current
with (security_invoker = true)
as
with cohort as (
  select f.match_id, f.home_en, f.away_en, f.kickoff_hkt
  from public.canonical_fixture_current f
  where coalesce(f.in_play, false) = false
    and f.kickoff_hkt >= now()
    and f.kickoff_hkt < now() + interval '48 hours'
),
canon as (
  select r.*
  from public.phase2_canonical_lineup_rows_current r
  join cohort c using (match_id)
),
a as (
  select c.match_id, c.home_en, c.away_en, c.kickoff_hkt,
    count(x.id) as lineup_rows,
    count(*) filter (where x.starter and x.team_side = 'H') as home_starters,
    count(*) filter (where x.starter and x.team_side = 'A') as away_starters,
    count(*) filter (where x.confirmed) as confirmed_rows,
    count(distinct x.source_name) as source_count,
    max(x.source_name) as canonical_source
  from cohort c
  left join canon x using (match_id)
  group by c.match_id, c.home_en, c.away_en, c.kickoff_hkt
)
select match_id, home_en, away_en, kickoff_hkt,
  lineup_rows, home_starters, away_starters, confirmed_rows, source_count,
  case
    when home_starters = 11 and away_starters = 11 and confirmed_rows >= 22 then 'CONFIRMED'::text
    when home_starters = 11 and away_starters = 11 then 'PREDICTED_FULL'::text
    when home_starters = 0 and away_starters = 0 then 'MISSING'::text
    else 'PARTIAL'::text
  end as lineup_status,
  canonical_source
from a;
