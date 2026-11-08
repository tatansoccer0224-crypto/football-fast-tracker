
create or replace function private.ft_seed_offline_backwards_fixture_aliases()
returns jsonb language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_inserted int:=0; v_suggested int:=0;
begin
with known as (
select source,alias_key,min(verified_team_key) team_key
from public.football_alias_supertable where resolution_status='VERIFIED'
group by 1,2 having count(distinct verified_team_key)=1
),
obs as (
select s.source_key src,s.external_event_id eid,
case when s.source_key='FOREBET'
then (s.raw->>'source_fixture_date')::date
else (s.kickoff_utc at time zone 'Asia/Taipei')::date end fixture_date,
s.league_name,s.home_name,s.away_name,
regexp_replace(lower(s.home_name),'[^a-z0-9]','','g') hk,
regexp_replace(lower(s.away_name),'[^a-z0-9]','','g') ak
from public.phase15_source_shadow_current s
where s.source_key in ('FOREBET','FLASHSCORE','FOTMOB')
and (s.source_key<>'FOREBET' or s.raw->>'source_fixture_date'~'^20[0-9]{2}-[0-9]{2}-[0-9]{2}$')
),
e as (
select o.*,kh.team_key ht,ka.team_key at from obs o
left join known kh on kh.source=o.src and kh.alias_key=o.hk
left join known ka on ka.source=o.src and ka.alias_key=o.ak
),
pairs as (
select a.src ssrc,a.eid seid,a.fixture_date d,a.league_name comp,
a.home_name sh,a.away_name sa,a.hk shk,a.ak sak,a.ht sht,a.at sat,
b.src rsrc,b.eid reid,b.home_name rh,b.away_name ra,b.hk rhk,b.ak rak,b.ht rht,b.at rat
from e a join e b on a.src='FOREBET' and b.src in ('FLASHSCORE','FOTMOB')
and b.fixture_date between a.fixture_date-1 and a.fixture_date+1
and (a.ht=b.ht and a.ht is not null or a.at=b.at and a.at is not null)
),
possibilities as (
select ssrc source,seid eid,rsrc reference_source,reid reference_eid,
sa alias_name,sak alias_key,ra reference_name,rat target_team,d,comp,
length(least(sak,rak))::numeric/nullif(length(greatest(sak,rak)),0) ratio
from pairs where sht=rht and sat is null and rat is not null and sak<>'' and rak<>''
and (position(sak in rak)>0 or position(rak in sak)>0)
union all
select ssrc,seid,rsrc,reid,sh,shk,rh,rht,d,comp,
length(least(shk,rhk))::numeric/nullif(length(greatest(shk,rhk)),0)
from pairs where sat=rat and sht is null and rht is not null and shk<>'' and rhk<>''
and (position(shk in rhk)>0 or position(rhk in shk)>0)
union all
select rsrc,reid,ssrc,seid,ra,rak,sa,sat,d,comp,
length(least(sak,rak))::numeric/nullif(length(greatest(sak,rak)),0)
from pairs where sht=rht and rat is null and sat is not null and sak<>'' and rak<>''
and (position(sak in rak)>0 or position(rak in sak)>0)
union all
select rsrc,reid,ssrc,seid,rh,rhk,sh,sht,d,comp,
length(least(shk,rhk))::numeric/nullif(length(greatest(shk,rhk)),0)
from pairs where sat=rat and rht is null and sht is not null and shk<>'' and rhk<>''
and (position(shk in rhk)>0 or position(rhk in shk)>0)
),
eligible as (
select * from possibilities p where ratio>=0.48 and length(alias_key)>=5
and length(regexp_replace(lower(reference_name),'[^a-z0-9]','','g'))>=5
and (select count(distinct (reference_source,reference_eid)) from possibilities x where x.source=p.source and x.eid=p.eid)=1
and (select count(distinct (source,eid)) from possibilities x where x.reference_source=p.reference_source and x.reference_eid=p.reference_eid)=1
and (select count(distinct target_team) from possibilities x where x.source=p.source and x.alias_key=p.alias_key)=1
and not exists (select 1 from public.team_alias_registry_v2 r where r.source=p.source and r.alias_key=p.alias_key and r.status='VERIFIED')
),
added as (
insert into public.football_alias_offline_pair_evidence(
source,source_event_id,alias_key,alias,reference_source,reference_event_id,
reference_name,proposed_team_key,fixture_date,source_competition,
lexical_ratio,confidence,status,method,evidence)
select source,eid,alias_key,alias_name,reference_source,reference_eid,
reference_name,target_team,d,comp,ratio,
case when ratio>=0.90 then 0.87::numeric else 0.77::numeric end,
'CANDIDATE','opponent_fixture_date_source_pair_offline',
jsonb_build_object('source_event',eid,'reference_event',reference_eid,'shared_verified_opponent',true,'uniquely_paired',true,'name_containment_ratio',round(ratio,3))
from eligible
on conflict(source,source_event_id,alias_key,reference_source,reference_event_id) do nothing
returning source
)
select count(*) into v_inserted from added;
with consensus as (
select source,alias_key,min(proposed_team_key) team_key,
count(distinct proposed_team_key) target_count,
count(distinct source_event_id) event_count,
max(confidence) confidence,
max(reference_source) reference_source
from public.football_alias_offline_pair_evidence
where status='CANDIDATE'
group by source,alias_key
having count(distinct proposed_team_key)=1
),
updated as (
update public.football_alias_supertable st
set suggested_team_key=c.team_key,
resolution_status='CANDIDATE',confidence=greatest(st.confidence,c.confidence),
resolution_method='offline_backward_fixture_opponent_candidate',
evidence=st.evidence||jsonb_build_object('offline_pair_evidence',true,'offline_pair_events',c.event_count,'offline_pair_source',c.reference_source),
refreshed_at=now()
from consensus c
where st.source=c.source and st.alias_key=c.alias_key
and st.resolution_status in ('UNMATCHED','CANDIDATE')
and st.verified_team_key is null
and (st.suggested_team_key is null or st.suggested_team_key=c.team_key)
returning st.source
)
select count(*) into v_suggested from updated;
return jsonb_build_object('new_offline_evidence',v_inserted,'supertable_candidates_enriched',v_suggested,'at',now());
end $$;
revoke all on function private.ft_seed_offline_backwards_fixture_aliases() from public,anon,authenticated;
grant execute on function private.ft_seed_offline_backwards_fixture_aliases() to service_role;
