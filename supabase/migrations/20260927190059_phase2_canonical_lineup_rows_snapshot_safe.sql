create or replace view public.phase2_canonical_lineup_rows_current as
with upcoming as (
  select hkjc_event_id from public.hkjc_upcoming_current
  where kickoff_hkt >= now()-interval '2 hours' and kickoff_hkt < now()+interval '48 hours'
), latest_fetch as (
  select l.hkjc_event_id,l.source_name,max(l.fetched_at) fetched_at
  from public.phase2_match_lineup_evidence l join upcoming u using(hkjc_event_id)
  group by l.hkjc_event_id,l.source_name
), latest_rows as (
  select l.* from public.phase2_match_lineup_evidence l
  join latest_fetch f on f.hkjc_event_id=l.hkjc_event_id and f.source_name=l.source_name and f.fetched_at=l.fetched_at
), stats as (
  select hkjc_event_id,source_name,max(fetched_at) fetched_at,
    count(*) filter(where starter and team_side='H') home_starters,
    count(*) filter(where starter and team_side='A') away_starters,
    count(*) filter(where confirmed) confirmed_rows,
    case when source_name='API_FOOTBALL' then 400 when source_name='FLASHSCORE_OFFICIAL' then 350 when source_name ilike '%PREDICTED%' then 150 else 200 end priority
  from latest_rows group by hkjc_event_id,source_name
), ranked as (
 select *,row_number() over(partition by hkjc_event_id order by
   (case when home_starters=11 and away_starters=11 then 1 else 0 end) desc,
   confirmed_rows desc,priority desc,fetched_at desc) rn
 from stats
), chosen as (select * from ranked where rn=1)
select l.*,
  case when c.home_starters=11 and c.away_starters=11 and c.confirmed_rows>=22 then 'CONFIRMED'
       when c.home_starters=11 and c.away_starters=11 then 'PREDICTED_FULL'
       else 'PARTIAL' end as canonical_status,
  case when c.home_starters=11 and c.away_starters=11 and
    count(*) filter(where l.starter and l.formation_slot is not null) over(partition by l.hkjc_event_id)=22
    then 'FORMATION_READY' else 'FORMATION_UNAVAILABLE' end as formation_status
from latest_rows l join chosen c on c.hkjc_event_id=l.hkjc_event_id and c.source_name=l.source_name and c.fetched_at=l.fetched_at;
