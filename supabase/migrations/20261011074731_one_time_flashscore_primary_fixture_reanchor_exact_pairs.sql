
create or replace function private.ft_reanchor_recent_legacy_fixtures_to_flashscore()
returns jsonb
language plpgsql security definer set search_path=public,pg_temp
as $$
declare n_new int:=0; n_redirect int:=0; n_evidence int:=0; n_fb int:=0;
begin
with candidate as (
select m.hkjc_event_id old_id, m.kickoff_hkt old_time,m.status old_status,
m.home_en old_home,m.away_en old_away,m.home_zh,m.away_zh,
s.external_event_id provider_id,s.kickoff_utc,s.league_name,
s.home_name,s.away_name,s.fetched_at
from public.matches m join public.phase15_source_shadow_current s
 on s.source_key='FLASHSCORE'
 and s.kickoff_utc between m.kickoff_hkt-interval '15 minutes' and m.kickoff_hkt+interval '15 minutes'
 and regexp_replace(lower(m.home_en),'[^a-z0-9]','','g')=regexp_replace(lower(s.home_name),'[^a-z0-9]','','g')
 and regexp_replace(lower(m.away_en),'[^a-z0-9]','','g')=regexp_replace(lower(s.away_name),'[^a-z0-9]','','g')
where m.hkjc_event_id like 'FB%'
 and m.kickoff_hkt between now()-interval '72 hours' and now()+interval '72 hours'
 and s.fetched_at>now()-interval '36 hours'
 and s.external_event_id ~ '^[A-Za-z0-9]{7,12}$'
 and (s.match_id is null or s.match_id=m.hkjc_event_id)
 and not exists(select 1 from public.fixture_identity_redirects x where x.source_match_id=m.hkjc_event_id and x.active)
 and not exists(select 1 from public.matches newer where newer.hkjc_event_id='FS:'||s.external_event_id)
),safe as(
 select x.* from candidate x
 where (select count(distinct provider_id) from candidate y where y.old_id=x.old_id)=1
 and (select count(distinct old_id) from candidate y where y.provider_id=x.provider_id)=1
),added as(
 insert into public.matches (
 hkjc_event_id,kickoff_hkt,status,tournament,home_en,away_en,home_zh,away_zh,
 in_play,selling,pool_status,fetched_at,source_updated_at,raw,updated_at
 )
 select 'FS:'||provider_id,kickoff_utc,coalesce(old_status,'SCHEDULED'),league_name,home_name,away_name,home_zh,away_zh,
 false,false,null,fetched_at,fetched_at,
 jsonb_build_object('identity_authority','FLASHSCORE','provider_event_id',provider_id,'source','FLASHSCORE_SOURCE_SHADOW',
 'legacy_fixture_key',old_id,'evidence','unique_exact_pair+kickoff_within_15min','source_fetched_at',fetched_at),now()
 from safe
 on conflict(hkjc_event_id) do nothing
 returning hkjc_event_id
),redirects as(
 insert into public.fixture_identity_redirects(source_match_id,target_match_id,source_name,confidence,evidence,active)
 select x.old_id,z.hkjc_event_id,'FLASHSCORE_CANONICAL_REANCHOR',0.999,
 jsonb_build_object('provider','FLASHSCORE','provider_event_id',x.provider_id,'evidence',
 'one_to_one_exact_pair_and_kickoff','old_time',x.old_time,'flashscore_time',x.kickoff_utc,'source_fetched_at',x.fetched_at),true
 from safe x join added z on z.hkjc_event_id='FS:'||x.provider_id
 on conflict(source_match_id) do nothing
 returning source_match_id,target_match_id
),evidence_updated as (
 update public.phase15_source_shadow_current s
 set match_id=r.target_match_id,match_confidence=0.999,identity_status='VERIFIED_IDENTITY',updated_at=now()
 from redirects r join safe x on x.old_id=r.source_match_id
 where s.source_key='FLASHSCORE' and s.external_event_id=x.provider_id
 and (s.match_id is null or s.match_id=r.source_match_id)
 returning s.external_event_id
),forebet_copied as(
 insert into public.forebet_predictions(
 hkjc_event_id,fetched_at,forebet_match_date,forebet_kickoff_text,forebet_league_short,
 forebet_home_team,forebet_away_team,prob_home,prob_draw,prob_away,
 prediction_1x2,predicted_score,avg_goals,forebet_detail_url,match_score,raw
 )
 select r.target_match_id,fb.fetched_at,fb.forebet_match_date,fb.forebet_kickoff_text,fb.forebet_league_short,
 fb.forebet_home_team,fb.forebet_away_team,fb.prob_home,fb.prob_draw,fb.prob_away,
 fb.prediction_1x2,fb.predicted_score,fb.avg_goals,fb.forebet_detail_url,0.999,
 fb.raw||jsonb_build_object('canonical_reanchored_from',r.source_match_id,'canonical_authority','FLASHSCORE')
 from redirects r join public.forebet_predictions fb on fb.hkjc_event_id=r.source_match_id
 where fb.prob_home between 0 and 100 and fb.prob_draw between 0 and 100 and fb.prob_away between 0 and 100
 and fb.prob_home+fb.prob_draw+fb.prob_away between 98 and 102
 and fb.predicted_score ~ '^[0-9]{1,2} *- *[0-9]{1,2}$'
 and fb.avg_goals between 0.1 and 12
 on conflict(hkjc_event_id) do nothing
 returning hkjc_event_id
)
select (select count(*) from added),(select count(*) from redirects),
 (select count(*) from evidence_updated),(select count(*) from forebet_copied)
into n_new,n_redirect,n_evidence,n_fb;
return jsonb_build_object('new_flashscore_fixture_keys',n_new,'redirects',n_redirect,
'source_identity_updates',n_evidence,'forebet_migrated',n_fb,'at',now());
end $$;
revoke all on function private.ft_reanchor_recent_legacy_fixtures_to_flashscore() from public,anon,authenticated;
grant execute on function private.ft_reanchor_recent_legacy_fixtures_to_flashscore() to service_role;
