create or replace view public.phase2_lineup_coverage_current as
select u.hkjc_event_id,u.home_zh,u.away_zh,u.kickoff_hkt,
 count(l.id) as lineup_rows,
 count(l.id) filter(where l.starter=true and l.team_side='H') as home_starters,
 count(l.id) filter(where l.starter=true and l.team_side='A') as away_starters,
 count(l.id) filter(where l.confirmed=true) as confirmed_rows,
 count(distinct l.source_name) as source_count,
 case when count(l.id) filter(where l.starter=true and l.team_side='H')=11 and count(l.id) filter(where l.starter=true and l.team_side='A')=11 then case when count(l.id) filter(where l.confirmed=true)>=22 then 'CONFIRMED' else 'PREDICTED_FULL' end when count(l.id)>0 then 'PARTIAL' else 'MISSING' end as lineup_status
from public.hkjc_upcoming_current u
left join public.phase2_match_lineup_evidence l on l.hkjc_event_id=u.hkjc_event_id
where u.kickoff_hkt>=now()-interval '2 hours' and u.kickoff_hkt<now()+interval '48 hours'
group by u.hkjc_event_id,u.home_zh,u.away_zh,u.kickoff_hkt;

select cron.schedule('phase2-lineup-source-refresh','12 * * * *',$$select net.http_get(url := 'https://hekqxhgjexzxnecwhyao.supabase.co/functions/v1/phase15-flashscore-scout?force=1',timeout_milliseconds := 60000);$$);
select cron.schedule('phase2-lineup-official-upgrade','42 * * * *',$$select net.http_get(url := 'https://hekqxhgjexzxnecwhyao.supabase.co/functions/v1/api-football-phase2-detail',timeout_milliseconds := 60000);$$);
