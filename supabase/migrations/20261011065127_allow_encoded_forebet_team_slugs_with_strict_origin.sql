do $patch$
declare def text;old_text text;new_text text;
begin
select pg_get_functiondef('public.ft_ingest_forebet_firecrawl_batch(jsonb,text)'::regprocedure) into def;
old_text := $old$^https://www[.]forebet[.]com/en/football/matches/[a-z0-9-]+-[0-9]{5,12}$$old$;
new_text := $new$^https://www[.]forebet[.]com/en/football/matches/[^/?#]{2,240}-[0-9]{5,12}$$new$;
if position(old_text in def)=0 then raise exception 'VALIDATOR_PATTERN_UNEXPECTED'; end if;
execute replace(def,old_text,new_text);
end $patch$;
