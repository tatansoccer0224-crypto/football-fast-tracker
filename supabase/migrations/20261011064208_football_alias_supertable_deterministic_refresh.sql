
create or replace function private.ft_refresh_football_alias_supertable()
returns jsonb
language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_total int; v_verified int; v_candidate int; v_unmatched int; v_ambiguous int;
begin
with raw_rows as (
 select t.source, t.source_name as provider_name, t.source_key as alias_key,
 ''::text as source_competition,''::text as provider_team_id,null::text as example_event,
 null::text as detail_url,t.last_seen_at as seen_at,'MASTER'::text as origin
 from public.team_name_master t where t.source_name is not null and t.source_key is not null
 union all
 select c.source,c.source_name,c.source_key,c.source_competition,''::text,
 null::text,null::text,c.last_seen_at,'CONTEXT'
 from public.team_name_context_master c
 union all
 select s.source_key,s.home_name,
 coalesce(nullif(regexp_replace(lower(s.home_name),'[^a-z0-9]','','g'),''),'u:'||md5(lower(s.home_name))),
 coalesce(s.league_name,''),coalesce(s.home_external_id,''),s.external_event_id,
 s.raw->>'source_url',s.fetched_at,'OBSERVED'
 from public.phase15_source_shadow_current s where s.home_name is not null and length(trim(s.home_name))>0
 union all
 select s.source_key,s.away_name,
 coalesce(nullif(regexp_replace(lower(s.away_name),'[^a-z0-9]','','g'),''),'u:'||md5(lower(s.away_name))),
 coalesce(s.league_name,''),coalesce(s.away_external_id,''),s.external_event_id,
 s.raw->>'source_url',s.fetched_at,'OBSERVED'
 from public.phase15_source_shadow_current s where s.away_name is not null and length(trim(s.away_name))>0
),
groups as (
 select source,alias_key,
 regexp_replace(lower(source_competition),'[^a-z0-9]','','g') as competition_key,
 provider_team_id,max(provider_name) provider_name,max(source_competition) source_competition,
 count(*)::int observations,max(example_event) source_event_id_example,
 max(detail_url) source_detail_url,max(seen_at) last_observed_at,
 bool_or(origin='OBSERVED') has_observation,
 bool_or(origin='MASTER') has_master,
 bool_or(origin='CONTEXT') has_context
 from raw_rows where alias_key<>'' and provider_name<>'' and source not in ('','UNKNOWN')
 group by 1,2,3,4
),
r as (select source,alias_key,
 case when count(distinct team_key) filter (where status='VERIFIED')=1 then min(team_key) filter(where status='VERIFIED') end team_key,
 count(distinct team_key) filter(where status='VERIFIED') verified_count
 from public.team_alias_registry_v2 group by 1,2),
m as (select source,source_key alias_key,
 case when count(distinct team_key) filter (where status='VERIFIED')=1 then min(team_key) filter(where status='VERIFIED') end team_key,
 count(distinct team_key) filter (where status='VERIFIED') verified_count
 from public.team_name_master group by 1,2),
ctx as (select source,source_key alias_key,competition_key,
 case when count(distinct team_key) filter(where status='VERIFIED')=1 then min(team_key) filter(where status='VERIFIED') end team_key,
 count(distinct team_key) filter(where status='VERIFIED') verified_count
 from public.team_name_context_master where competition_key<>'' group by 1,2,3),
ids as (select alias_key,
 case when count(distinct team_key) filter(where status='VERIFIED')=1 then min(team_key) filter(where status='VERIFIED') end team_key,
 count(distinct team_key) filter(where status='VERIFIED') verified_count
 from public.team_alias_registry_v2 where source='FLASHSCORE_TEAM_ID' group by 1),
cross_sources as (select alias_key,
 case when count(distinct team_key)=1 and count(distinct source)>=2 then min(team_key) end team_key,
 count(distinct team_key) different_teams,
 count(distinct source) n_sources
 from public.team_alias_registry_v2 where status='VERIFIED'
 and source not in ('CANONICAL_EN','CANONICAL_ZH','REEP_CC0','FLASHSCORE_TEAM_ID')
 group by 1),
canonical as (
 select regexp_replace(lower(hkjc_name_en),'[^a-z0-9]','','g') alias_key,
 case when count(distinct team_key)=1 then min(team_key) end team_key,
 count(distinct team_key) team_count
 from public.team_entities_v2
 group by 1
),
leagues as (
 select source,source_key,
 case when count(distinct canonical_tournament) filter(where status='VERIFIED')=1 then min(canonical_tournament) filter(where status='VERIFIED') end tournament
 from public.competition_name_master group by 1,2
),
linked as (
 select g.*,rr.team_key reg_team,rr.verified_count reg_count,
 mm.team_key master_team,mm.verified_count master_count,
 cc.team_key context_team,cc.verified_count context_count,
 ii.team_key id_team,ii.verified_count id_count,
 cs.team_key consensus_team,cs.different_teams,cs.n_sources,
 ca.team_key exact_team,ca.team_count exact_count,
 lg.tournament canonical_competition
 from groups g
 left join r rr on rr.source=g.source and rr.alias_key=g.alias_key
 left join m mm on mm.source=g.source and mm.alias_key=g.alias_key
 left join ctx cc on cc.source=g.source and cc.alias_key=g.alias_key and cc.competition_key=g.competition_key
 left join ids ii on g.source='FLASHSCORE' and g.provider_team_id<>'' and ii.alias_key=regexp_replace(lower(g.provider_team_id),'[^a-z0-9]','','g')
 left join cross_sources cs on cs.alias_key=g.alias_key
 left join canonical ca on ca.alias_key=g.alias_key
 left join leagues lg on lg.source=g.source and lg.source_key=g.competition_key
),
targets as (
 select l.*,
 array(select distinct z from unnest(array[l.reg_team,l.master_team,l.context_team,l.id_team]) as z where z is not null) verified_targets
 from linked l
),
resolved as (
 select t.*,
 case when coalesce(reg_count,0)>1 or coalesce(master_count,0)>1
     or coalesce(context_count,0)>1 or coalesce(id_count,0)>1
     or cardinality(verified_targets)>1 then 'AMBIGUOUS'
      when cardinality(verified_targets)=1 then 'VERIFIED'
      when coalesce(different_teams,0)>1 then 'AMBIGUOUS'
      when consensus_team is not null or exact_team is not null then 'CANDIDATE'
      else 'UNMATCHED' end status,
 case when cardinality(verified_targets)=1 and coalesce(reg_count,0)<=1 and coalesce(master_count,0)<=1
      and coalesce(context_count,0)<=1 and coalesce(id_count,0)<=1
      then verified_targets[1] end verified_resolved
 from targets t
),
prepared as (
 select source,alias_key,competition_key,provider_team_id,provider_name,source_competition,
 canonical_competition,
 case when status='VERIFIED' then verified_resolved end verified_team_key,
 case when status='CANDIDATE' then coalesce(consensus_team,exact_team) end suggested_team_key,
 status as resolution_status,
 case when status='VERIFIED' then
      case when id_team is not null then 0.97::numeric
           when context_team is not null then 0.97::numeric
           else 0.95::numeric end
      when status='CANDIDATE' then case when consensus_team is not null then 0.84::numeric else 0.72::numeric end
      else 0::numeric end as confidence,
 case when status='AMBIGUOUS' then 'conflicting_identity_or_cross_source'
      when status='VERIFIED' then
       case when id_team is not null then 'verified_provider_team_id'
            when context_team is not null then 'verified_competition_context'
            when reg_team is not null then 'existing_verified_registry'
            else 'existing_verified_master' end
      when consensus_team is not null then 'candidate_two_source_consensus'
      when exact_team is not null then 'candidate_unique_canonical_name'
      else 'unmatched' end resolution_method,
 observations,source_event_id_example,source_detail_url,last_observed_at,
 jsonb_build_object('has_observation',has_observation,'has_master',has_master,'has_context',has_context,
 'source_consensus_count',coalesce(n_sources,0),'distinct_verification_targets',cardinality(verified_targets)) evidence
 from resolved
),
written as (
 insert into public.football_alias_supertable(
 source,alias_key,competition_key,provider_team_id,provider_name,source_competition,canonical_competition,
 verified_team_key,suggested_team_key,resolution_status,confidence,resolution_method,observations,
 source_event_id_example,source_detail_url,last_observed_at,evidence)
 select source,alias_key,competition_key,provider_team_id,provider_name,source_competition,
 canonical_competition,verified_team_key,suggested_team_key,resolution_status,confidence,resolution_method,
 observations,source_event_id_example,source_detail_url,last_observed_at,evidence from prepared
 on conflict(source,alias_key,competition_key,provider_team_id)
 do update set
 provider_name=excluded.provider_name,
 source_competition=excluded.source_competition,
 canonical_competition=excluded.canonical_competition,
 verified_team_key=excluded.verified_team_key,
 suggested_team_key=excluded.suggested_team_key,
 resolution_status=excluded.resolution_status,
 confidence=excluded.confidence,
 resolution_method=excluded.resolution_method,
 observations=excluded.observations,
 source_event_id_example=excluded.source_event_id_example,
 source_detail_url=excluded.source_detail_url,
 last_observed_at=excluded.last_observed_at,
 evidence=excluded.evidence,
 refreshed_at=now()
 where (football_alias_supertable.provider_name,football_alias_supertable.source_competition,
 football_alias_supertable.canonical_competition,football_alias_supertable.verified_team_key,
 football_alias_supertable.suggested_team_key,football_alias_supertable.resolution_status,
 football_alias_supertable.confidence,football_alias_supertable.resolution_method,
 football_alias_supertable.observations,football_alias_supertable.source_event_id_example,
 football_alias_supertable.source_detail_url,football_alias_supertable.last_observed_at,
 football_alias_supertable.evidence)
 is distinct from
 (excluded.provider_name,excluded.source_competition,excluded.canonical_competition,
 excluded.verified_team_key,excluded.suggested_team_key,excluded.resolution_status,
 excluded.confidence,excluded.resolution_method,excluded.observations,
 excluded.source_event_id_example,excluded.source_detail_url,excluded.last_observed_at,excluded.evidence)
 returning source
)
select count(*),
 count(*) filter(where resolution_status='VERIFIED'),
 count(*) filter(where resolution_status='CANDIDATE'),
 count(*) filter(where resolution_status='UNMATCHED'),
 count(*) filter(where resolution_status='AMBIGUOUS')
 into v_total,v_verified,v_candidate,v_unmatched,v_ambiguous
 from public.football_alias_supertable;
return jsonb_build_object('total',v_total,'verified',v_verified,'candidate',v_candidate,'unmatched',v_unmatched,'ambiguous',v_ambiguous,'at',now());
end $$;
revoke all on function private.ft_refresh_football_alias_supertable() from public, anon,authenticated;
grant execute on function private.ft_refresh_football_alias_supertable() to service_role;
