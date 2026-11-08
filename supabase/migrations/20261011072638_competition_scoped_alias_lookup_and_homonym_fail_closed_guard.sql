do $patch$
declare d text;
begin
select pg_get_functiondef('public.ft_alias_super_lookup(text,text,text,text)'::regprocedure) into d;
if position($old$and (rid='' and provider_team_id='' or rid<>'' and provider_team_id=rid)$old$ in d)=0 or position($old$rid:=coalesce(p_provider_team_id,'');$old$ in d)=0
then raise exception 'LOOKUP_FUNCTION_CONTRACT_MISMATCH';end if;
d:=replace(d,$old$and (rid='' and provider_team_id='' or rid<>'' and provider_team_id=rid)$old$,$new$and (rid='' and (provider_team_id='' or league_key<>'') or rid<>'' and provider_team_id=rid)$new$);
d:=replace(d,$old$rid:=coalesce(p_provider_team_id,'');$old$,$new$rid:=coalesce(p_provider_team_id,'');
 if rid='' and league_key='' and p_source in ('FLASHSCORE','FOTMOB')
 and (select count(distinct provider_team_id) from public.football_alias_supertable
 where source=p_source and alias_key=normalized and provider_team_id<>'')>1
 and (select count(distinct competition_key) from public.football_alias_supertable
 where source=p_source and alias_key=normalized and provider_team_id<>'')>1
 then
 return jsonb_build_object('source',p_source,'source_name',p_name,'status','AMBIGUOUS',
 'verified_team_key',null,'suggested_team_key',null,
 'reason','MULTIPLE_SOURCE_TEAM_IDS_DIFFERENT_LEAGUES');
 end if;$new$);
execute d;
end $patch$;
