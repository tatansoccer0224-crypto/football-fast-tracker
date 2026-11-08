
do $patch$
declare def text; old_text text; new_text text;
begin
 select pg_get_functiondef('private.ft_refresh_football_alias_supertable()'::regprocedure) into def;
 old_text := $old$into v_total,v_verified,v_candidate,v_unmatched,v_ambiguous
 from public.football_alias_supertable;$old$;
 new_text := $new$into v_total,v_verified,v_candidate,v_unmatched,v_ambiguous
 from written;
 select count(*),
 count(*) filter(where resolution_status='VERIFIED'),
 count(*) filter(where resolution_status='CANDIDATE'),
 count(*) filter(where resolution_status='UNMATCHED'),
 count(*) filter(where resolution_status='AMBIGUOUS')
 into v_total,v_verified,v_candidate,v_unmatched,v_ambiguous
 from public.football_alias_supertable;$new$;
 if position(old_text in def)=0 then raise exception 'FUNCTION_BODY_MISMATCH_NO_PATCH'; end if;
 def:= replace(def,old_text,new_text);
 execute def;
end $patch$;
