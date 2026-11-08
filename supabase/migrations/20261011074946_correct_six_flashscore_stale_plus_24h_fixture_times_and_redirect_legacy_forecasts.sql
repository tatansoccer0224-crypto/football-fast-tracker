
with candidate as (
select fs.hkjc_event_id fs_id,fs.kickoff_hkt stored_kickoff,
s.external_event_id, s.kickoff_utc authoritative_kickoff,s.fetched_at,
s.home_name,s.away_name,s.league_name,
fb.hkjc_event_id legacy_id
from public.matches fs
join public.phase15_source_shadow_current s on
 s.source_key='FLASHSCORE' and fs.hkjc_event_id='FS:'||s.external_event_id
join public.matches fb on
 fb.hkjc_event_id like 'FB%'
 and abs(extract(epoch from (fb.kickoff_hkt-s.kickoff_utc))) <= 900
 and regexp_replace(lower(fb.home_en),'[^a-z0-9]','','g')=regexp_replace(lower(s.home_name),'[^a-z0-9]','','g')
 and regexp_replace(lower(fb.away_en),'[^a-z0-9]','','g')=regexp_replace(lower(s.away_name),'[^a-z0-9]','','g')
where abs(extract(epoch from (fs.kickoff_hkt-s.kickoff_utc))) between 82800 and 93600
 and s.fetched_at >= now()-interval '36 hours'
 and fb.kickoff_hkt between now()-interval '72 hours' and now()+interval '72 hours'
 and (s.match_id is null or s.match_id=fb.hkjc_event_id or s.match_id=fs.hkjc_event_id)
 and not exists (select 1 from public.fixture_identity_redirects d where d.source_match_id=fb.hkjc_event_id and d.active)
),
safe as (
select a.* from candidate a
where (select count(distinct legacy_id) from candidate b where b.fs_id=a.fs_id)=1
and (select count(distinct fs_id) from candidate b where b.legacy_id=a.legacy_id)=1
),
corrected as (
update public.matches fs
set kickoff_hkt=s.authoritative_kickoff,
    home_en=s.home_name,
    away_en=s.away_name,
    tournament=s.league_name,
    fetched_at=s.fetched_at,
    source_updated_at=s.fetched_at,
    updated_at=now(),
    raw=fs.raw||jsonb_build_object(
    'authoritative_fixture_provider','FLASHSCORE',
    'provider_event_id',s.external_event_id,
    'previous_kickoff_utc',s.stored_kickoff,
    'timestamp_correction','unique_same_event_id+exact_pair+independent_legacy_time',
    'provider_fetched_at',s.fetched_at)
from safe s where fs.hkjc_event_id=s.fs_id
returning fs.hkjc_event_id
),
linked as (
insert into public.fixture_identity_redirects (
 source_match_id,target_match_id,source_name,confidence,evidence,active
)
select s.legacy_id,s.fs_id,'FLASHSCORE_EXACT_TIME_RECONCILIATION',0.999,
jsonb_build_object('source','FLASHSCORE','source_event_id',s.external_event_id,
 'source_fetched_at',s.fetched_at,
 'corrected_kickoff',s.authoritative_kickoff,
 'identity_method','exact_pair+independent_legacy_time+source_id'),true
from safe s join corrected f on f.hkjc_event_id=s.fs_id
on conflict(source_match_id) do nothing
returning source_match_id,target_match_id
),
aligned as (
update public.phase15_source_shadow_current s
set match_id=r.target_match_id,identity_status='VERIFIED_IDENTITY',match_confidence=0.999,updated_at=now()
from linked r join safe v on v.legacy_id=r.source_match_id
where s.source_key='FLASHSCORE' and s.external_event_id=v.external_event_id
 and (s.match_id is null or s.match_id=r.source_match_id or s.match_id=r.target_match_id)
returning s.external_event_id
),
forebet as (
insert into public.forebet_predictions (
 hkjc_event_id,fetched_at,forebet_match_date,forebet_kickoff_text,
 forebet_league_short,forebet_home_team,forebet_away_team,
 prob_home,prob_draw,prob_away,prediction_1x2,predicted_score,avg_goals,
 forebet_detail_url,match_score,raw
)
select r.target_match_id,f.fetched_at,f.forebet_match_date,f.forebet_kickoff_text,
 f.forebet_league_short,f.forebet_home_team,f.forebet_away_team,
 f.prob_home,f.prob_draw,f.prob_away,f.prediction_1x2,f.predicted_score,
 f.avg_goals,f.forebet_detail_url,0.999,
 f.raw||jsonb_build_object('reanchored_from',r.source_match_id,'identity_authority','FLASHSCORE')
from linked r join public.forebet_predictions f on f.hkjc_event_id=r.source_match_id
where f.prob_home between 0 and 100 and f.prob_draw between 0 and 100
 and f.prob_away between 0 and 100
 and f.prob_home+f.prob_draw+f.prob_away between 98 and 102
 and f.avg_goals between 0.1 and 12
on conflict(hkjc_event_id) do nothing
returning hkjc_event_id
)
select jsonb_build_object(
'flashscore_timestamps_corrected',(select count(*) from corrected),
'legacy_redirects_added',(select count(*) from linked),
'source_matches_realigned',(select count(*) from aligned),
'forebet_predictions_preserved',(select count(*) from forebet)
) as result;
