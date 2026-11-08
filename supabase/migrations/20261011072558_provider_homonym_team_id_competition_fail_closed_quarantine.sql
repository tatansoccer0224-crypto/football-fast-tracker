
create or replace function private.ft_quarantine_provider_name_collisions()
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare affected int:=0; ambiguous_keys int:=0;
begin
with conflicting as(
select source,alias_key,count(distinct provider_team_id) ids,count(distinct competition_key) leagues
from public.football_alias_supertable
where source in ('FLASHSCORE','FOTMOB') and provider_team_id<>''
group by 1,2 having count(distinct provider_team_id)>1 and count(distinct competition_key)>1
),fixed as (
update public.football_alias_supertable t
set resolution_status='AMBIGUOUS', suggested_team_key=null,
confidence=0,resolution_method='multiple_provider_team_ids_across_leagues',
evidence=t.evidence||jsonb_build_object('cross_league_name_collision',true,'provider_ids_involved',c.ids,'competitions_involved',c.leagues),
refreshed_at=now()
from conflicting c where t.source=c.source and t.alias_key=c.alias_key
and t.resolution_status<>'VERIFIED'
and (t.resolution_status<>'AMBIGUOUS' or t.suggested_team_key is not null)
returning t.source
)
select count(*) into affected from fixed;
select count(*) into ambiguous_keys
from (
select source,alias_key from public.football_alias_supertable
where source in ('FLASHSCORE','FOTMOB') and provider_team_id<>''
group by 1,2 having count(distinct provider_team_id)>1 and count(distinct competition_key)>1
) c;
return jsonb_build_object('collision_name_keys',ambiguous_keys,'nonverified_rows_quarantined',affected,'at',now());
end $$;
revoke all on function private.ft_quarantine_provider_name_collisions() from public,anon,authenticated;
grant execute on function private.ft_quarantine_provider_name_collisions() to service_role;
