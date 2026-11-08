
create or replace function public.ft_ingest_forebet_firecrawl_batch(p_rows jsonb,p_surface text)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare n int; inserted_n int; valid_n int;
begin
 if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) < 1 or jsonb_array_length(p_rows)>300
 then raise exception 'INVALID_SOURCE_BATCH_SIZE'; end if;
 if p_surface not in (
 'https://www.forebet.com/en/football-tips-and-predictions-for-today',
 'https://www.forebet.com/en/football-tips-and-predictions-for-tomorrow',
 'https://www.forebet.com/en/prediction-lists/top-europe',
 'https://www.forebet.com/en/prediction-lists/all-europe',
 'https://www.forebet.com/en/prediction-lists/america',
 'https://www.forebet.com/en/prediction-lists/asia',
 'https://www.forebet.com/en/prediction-lists/africa',
 'https://www.forebet.com/en/football-predictions'
 ) then raise exception 'INVALID_ALLOWED_SURFACE'; end if;
 with incoming as (
 select value x from jsonb_array_elements(p_rows) as value
 ),
 normalized as (
 select x->>'source_event_id' event_id,
 x->>'home' home,x->>'away' away,x->>'league' league,x->>'source_date' source_date,
 x->>'source_time' source_time,x->>'source_url' source_url,
 x->>'predicted_score' predicted_score,
 case when x->>'prob_home'~'^[0-9]{1,3}$' then (x->>'prob_home')::int end ph,
 case when x->>'prob_draw'~'^[0-9]{1,3}$' then (x->>'prob_draw')::int end pd,
 case when x->>'prob_away'~'^[0-9]{1,3}$' then (x->>'prob_away')::int end pa,
 case when x->>'avg_goals'~'^[0-9]+(\.[0-9]+)?$' then (x->>'avg_goals')::numeric end avg_goals
 from incoming
 ),
 validated as (
 select *,
 event_id ~ '^[0-9]{5,12}$' and length(home) between 2 and 140 and length(away) between 2 and 140
 and lower(home)<>lower(away) and length(coalesce(league,'')) between 1 and 64
 and source_date ~ '^20[0-9]{2}-[0-9]{2}-[0-9]{2}$'
 and source_url ~ '^https://www[.]forebet[.]com/en/football/matches/[a-z0-9-]+-[0-9]{5,12}$'
 and right(source_url,length(event_id)+1)='-'||event_id
 and ph between 0 and 100 and pd between 0 and 100 and pa between 0 and 100
 and ph+pd+pa between 98 and 102
 and predicted_score ~ '^[0-9]{1,2}-[0-9]{1,2}$'
 and avg_goals>0 and avg_goals<=12 as ok
 from normalized
 )
 select count(*),count(*) filter(where ok) into n,valid_n from validated;
 if n<>valid_n then raise exception 'INVALID_SOURCE_ROWS: % of % valid',valid_n,n; end if;
 with incoming as (
 select x from jsonb_array_elements(p_rows) as x
 ), input_rows as (
 select (x->>'source_event_id') event_id,
 x->>'home' home,x->>'away' away,x->>'league' league,
 x->>'source_date' source_date,x->>'source_time' source_time,x->>'source_url' source_url,
 (x->>'prob_home')::int ph,(x->>'prob_draw')::int pd,(x->>'prob_away')::int pa,
 x->>'predicted_score' predicted_score,(x->>'avg_goals')::numeric avg_goals
 from incoming
 ), unique_rows as (
 select distinct on(event_id) * from input_rows order by event_id, source_url
 ), inserted as (
 insert into public.phase15_source_shadow_current (
 source_key,external_event_id,fetched_at,league_name,home_name,away_name,identity_status,raw,updated_at)
 select 'FOREBET',event_id,now(),league,home,away,'UNMATCHED',
 jsonb_build_object('source','FOREBET','capture_method','FIRECRAWL_EDGE_V2',
 'source_url',source_url,'listing_page',p_surface,'source_fixture_date',source_date,
 'source_display_time',source_time,'prob_home_pct',ph,'prob_draw_pct',pd,
 'prob_away_pct',pa,'predicted_score',predicted_score,'avg_goals',avg_goals,
 'kickoff_timezone_known',false,'captured_at',now()),now()
 from unique_rows
 on conflict(source_key,external_event_id)
 do update set fetched_at=now(),
 league_name=excluded.league_name,home_name=excluded.home_name,away_name=excluded.away_name,
 raw=phase15_source_shadow_current.raw || excluded.raw,
 updated_at=now()
 returning 1
 )
 select count(*) into inserted_n from inserted;
 return jsonb_build_object('source','FOREBET','accepted',n,'stored_or_updated',inserted_n,'surface',p_surface,'canonical_fixture_writes',0,'at',now());
end $$;
revoke all on function public.ft_ingest_forebet_firecrawl_batch(jsonb,text) from public,anon,authenticated;
grant execute on function public.ft_ingest_forebet_firecrawl_batch(jsonb,text) to service_role;
comment on function public.ft_ingest_forebet_firecrawl_batch(jsonb,text) is 'Service-only validated, idempotent Firecrawl source evidence ingestion. Identity columns/confirmed match IDs are never overwritten; no prediction promotion.';
