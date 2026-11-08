do $patch$
declare def text;old_text text;new_text text;
begin
select pg_get_functiondef('public.ft_ingest_forebet_firecrawl_batch(jsonb,text)'::regprocedure) into def;
old_text := $old$'https://www.forebet.com/en/prediction-lists/africa',$old$;
new_text := $new$'https://www.forebet.com/en/prediction-lists/africa',
 'https://www.forebet.com/en/prediction-lists/united-kingdom',
 'https://www.forebet.com/en/prediction-lists/australia',
 'https://www.forebet.com/en/prediction-lists/international',
 'https://www.forebet.com/en/prediction-lists/national-cups',
 'https://www.forebet.com/en/football-tips-and-predictions-for-the-weekend',
 'https://www.forebet.com/en/football-predictions-from-yesterday',$new$;
if position(old_text in def)=0 then raise exception 'FOREBET_SURFACE_FUNCTION_CHANGED';end if;
execute replace(def,old_text,new_text);
end $patch$;
