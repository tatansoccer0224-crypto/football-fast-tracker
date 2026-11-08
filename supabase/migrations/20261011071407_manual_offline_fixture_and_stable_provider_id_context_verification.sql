
create or replace function private.ft_verify_offline_context_aliases()
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare added_count int;
begin
with anchored as (
select s.source_key src,s.external_event_id eid,s.match_id,s.league_name,s.home_name,s.away_name,
s.home_external_id hid,s.away_external_id aid,m.home_en,m.away_en,m.tournament,m.kickoff_hkt
from public.phase15_source_shadow_current s join public.matches m on m.hkjc_event_id=s.match_id
where s.source_key in ('FLASHSCORE','FOTMOB')
and s.identity_status in ('VERIFIED_IDENTITY','EXACT_PAIR')
and s.match_confidence>=0.985
and s.kickoff_utc is not null and abs(extract(epoch from (s.kickoff_utc-m.kickoff_hkt)))<=7200
and coalesce(length(s.league_name),0)>1
and (select count(*) from public.phase15_source_shadow_current q
 where q.source_key=s.source_key and q.match_id=s.match_id
 and q.identity_status in ('VERIFIED_IDENTITY','EXACT_PAIR'))=1
),
sides as (
select src,eid,match_id,league_name,tournament,home_name name,hid pid,home_en canonical from anchored
union all
select src,eid,match_id,league_name,tournament,away_name,aid,away_en from anchored
),
entities as (
select x.*,regexp_replace(lower(name),'[^a-z0-9]','','g') nk,
regexp_replace(lower(league_name),'[^a-z0-9]','','g') competition_key,
e.team_key,e.hkjc_name_en,e.hkjc_name_zh
from sides x join public.team_entities_v2 e
on e.name_key=regexp_replace(lower(x.canonical),'[^a-z0-9]','','g')
where pid is not null and length(pid)>=4
and length(regexp_replace(lower(name),'[^a-z0-9]','','g'))>=4
and (select count(distinct team_key) from public.team_entities_v2 e2 where e2.name_key=e.name_key)=1
),
global_ids as (
select src,nk,count(distinct pid) n
from (
select source_key src,regexp_replace(lower(home_name),'[^a-z0-9]','','g') nk,home_external_id pid
from public.phase15_source_shadow_current where source_key in ('FLASHSCORE','FOTMOB')
union all
select source_key,regexp_replace(lower(away_name),'[^a-z0-9]','','g'),away_external_id
from public.phase15_source_shadow_current where source_key in ('FLASHSCORE','FOTMOB')
) x group by 1,2
),
safe as (
select x.* from entities x join global_ids g on g.src=x.src and g.nk=x.nk and g.n=1
where (select count(distinct team_key) from entities z
 where z.src=x.src and z.nk=x.nk and z.competition_key=x.competition_key)=1
and (select count(distinct team_key) from entities z where z.src=x.src and z.pid=x.pid)=1
and not exists(select 1 from public.team_alias_registry_v2 a
 where a.source=x.src and a.alias_key=x.nk and a.status='VERIFIED' and a.team_key<>x.team_key)
and not exists(select 1 from public.team_alias_registry_v2 a
 where a.source=x.src||'_TEAM_ID'
 and a.alias_key=regexp_replace(lower(x.pid),'[^a-z0-9]','','g')
 and a.status='VERIFIED' and a.team_key<>x.team_key)
),
deduped as (
select distinct on(src,nk,competition_key,tournament,team_key)
src,nk,competition_key,tournament,team_key,name,league_name,
hkjc_name_en,hkjc_name_zh,eid,pid
from safe order by src,nk,competition_key,tournament,team_key,eid
),
inserted as(
insert into public.team_name_context_master
(source,source_name,source_key,source_competition,competition_key,canonical_tournament,
team_key,hkjc_name_en,hkjc_name_zh,status,confidence,event_count,
first_seen_at,last_seen_at,evidence_sources,updated_at)
select src,name,nk,league_name,competition_key,tournament,team_key,hkjc_name_en,hkjc_name_zh,
'VERIFIED',0.985,1,now(),now(),
jsonb_build_array('OFFLINE_VERIFIED_FIXTURE','STABLE_PROVIDER_TEAM_ID','EVENT:'||eid,'PROVIDER_TEAM_ID:'||pid),now()
from deduped
on conflict(source,source_key,competition_key,canonical_tournament,team_key) do nothing
returning source
)
select count(*) into added_count from inserted;
return jsonb_build_object('verified_scoped_contexts_inserted',added_count,'as_of',now());
end $$;
revoke all on function private.ft_verify_offline_context_aliases() from public,anon,authenticated;
grant execute on function private.ft_verify_offline_context_aliases() to service_role;
