do $patch$
declare def text;old_text text;new_text text;
begin
select pg_get_functiondef('private.ft_refresh_football_alias_supertable()'::regprocedure) into def;
old_text := $old$select count(*),
 count(*) filter(where resolution_status='VERIFIED'),
 count(*) filter(where resolution_status='CANDIDATE'),
 count(*) filter(where resolution_status='UNMATCHED'),
 count(*) filter(where resolution_status='AMBIGUOUS')
 into v_total,v_verified,v_candidate,v_unmatched,v_ambiguous
 from written;$old$;
new_text := $new$select count(*) into v_total from written;$new$;
if position(old_text in def)=0 then raise exception 'REFRESH_PATCH_BODY_UNEXPECTED'; end if;
execute replace(def,old_text,new_text);
end $patch$;
