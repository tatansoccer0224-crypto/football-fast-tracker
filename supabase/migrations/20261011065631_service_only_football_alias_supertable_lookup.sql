
create or replace function public.ft_alias_super_lookup(
 p_source text,p_name text,p_competition text default null,p_provider_team_id text default null)
returns jsonb language plpgsql stable security definer
set search_path=public,pg_temp
as $$
declare normalized text; league_key text; rid text; verified text; suggested text; matches_count int; match_status text;
begin
 if p_source is null or p_name is null or length(trim(p_name))=0
    or length(p_name)>180 or length(p_source)>90
    or coalesce(length(p_competition),0)>150 or coalesce(length(p_provider_team_id),0)>90
 then return jsonb_build_object('status','INVALID_INPUT'); end if;
 normalized:=coalesce(nullif(regexp_replace(lower(p_name),'[^a-z0-9]','','g'),''),'u:'||md5(lower(p_name)));
 league_key:=regexp_replace(lower(coalesce(p_competition,'')),'[^a-z0-9]','','g');
 rid:=coalesce(p_provider_team_id,'');
 -- A supplied stable ID is an identity gate, never silently ignored.
 with ranked as (
 select *,
 case when rid<>'' and provider_team_id=rid then 0
      when rid='' and league_key<>'' and competition_key=league_key then 0
      when rid='' and competition_key='' then 1
      else 5 end tier
 from public.football_alias_supertable
 where source=p_source and alias_key=normalized
 and (rid='' and provider_team_id='' or rid<>'' and provider_team_id=rid)
 and (league_key='' or competition_key in ('',league_key))
 ),
 first_tier as (select * from ranked where tier=(select min(tier) from ranked)),
 result as(
 select count(*) n,count(distinct verified_team_key) filter(where resolution_status='VERIFIED') verified_n,
 min(verified_team_key) filter(where resolution_status='VERIFIED') verified_team,
 count(distinct suggested_team_key) filter(where resolution_status='CANDIDATE') candidate_n,
 min(suggested_team_key) filter(where resolution_status='CANDIDATE') candidate_team,
 count(*) filter(where resolution_status='AMBIGUOUS') ambiguous_n
 from first_tier
 )
 select n,case when verified_n=1 and ambiguous_n=0 then verified_team else null end,
 case when verified_n=0 and candidate_n=1 and ambiguous_n=0 then candidate_team else null end,
 case when verified_n>1 or ambiguous_n>0 then 'AMBIGUOUS'
      when verified_n=1 then 'VERIFIED'
      when candidate_n=1 then 'CANDIDATE'
      else 'UNMATCHED' end
 into matches_count,verified,suggested,match_status
 from result;
 return jsonb_build_object('source',p_source,'source_name',p_name,'competition',p_competition,
 'provider_team_id',p_provider_team_id,'status',match_status,'verified_team_key',verified,
 'suggested_team_key',suggested,'matches_examined',coalesce(matches_count,0));
end $$;
revoke all on function public.ft_alias_super_lookup(text,text,text,text) from public,anon,authenticated;
grant execute on function public.ft_alias_super_lookup(text,text,text,text) to service_role;
comment on function public.ft_alias_super_lookup(text,text,text,text) is 'Service-only fail-closed supertable lookup. Verified team key returned only for unique identity, candidates kept distinct. If provider team ID supplied, never ignore it.';
