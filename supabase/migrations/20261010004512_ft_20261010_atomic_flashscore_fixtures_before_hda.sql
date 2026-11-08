create or replace function public.ft_publish_flashscore_hda_with_fixtures(
 p_new_fixtures jsonb,p_rows jsonb,p_health jsonb
) returns jsonb
language plpgsql security definer
set search_path = public,pg_temp
as $$
declare
 v_created integer := 0;
 v_result jsonb;
begin
 if jsonb_typeof(p_new_fixtures) not in ('array','null')
   or jsonb_typeof(p_rows) <> 'array' then
   raise exception 'invalid_flashscore_publication_input';
 end if;
 if jsonb_typeof(p_new_fixtures)='array'
   and jsonb_array_length(p_new_fixtures)>0 then
   -- Create only the provider-identified exact fixture IDs already admitted
   -- by the Edge identity gate. Never manufacture an alias or promote nearby
   -- ambiguous fixtures simply to bypass bookmaker FK integrity.
   if exists(
     select 1 from jsonb_to_recordset(p_new_fixtures) as x(
       match_id text,provider_match_id text,kickoff_hkt timestamptz,
       status text,raw jsonb
     )
     where x.provider_match_id is null
       or x.match_id is distinct from 'FS:'||x.provider_match_id
       or x.status <> 'PREEVENT'
       or x.kickoff_hkt < now()-interval '10 minutes'
       or x.kickoff_hkt > now()+interval '7 days'
       or x.raw->>'source' is distinct from 'FLASHSCORE'
       or x.raw->>'identity_origin' is distinct from 'PROVIDER_CANONICAL_CREATED'
   ) then
     raise exception 'unsafe_flashscore_canonical_create';
   end if;
   v_created := public.ft_upsert_canonical_fixtures_generic(p_new_fixtures);
 end if;
 -- This does an atomic FK-checked replace of genuinely verified bookmaker
 -- quotes and the ingest health heartbeat. A failure rolls both back.
 v_result := public.ft_publish_flashscore_hda_current(
   p_rows,coalesce(p_health,'{}'::jsonb)
     || jsonb_build_object('canonical_created',v_created)
 );
 return v_result||jsonb_build_object('created_fixtures',v_created);
end;
$$;
revoke all on function public.ft_publish_flashscore_hda_with_fixtures(jsonb,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.ft_publish_flashscore_hda_with_fixtures(jsonb,jsonb,jsonb) to service_role;
