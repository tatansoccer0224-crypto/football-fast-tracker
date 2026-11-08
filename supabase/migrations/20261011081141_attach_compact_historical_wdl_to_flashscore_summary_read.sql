do $patch$
declare def text;needle text;repl text;
begin
select pg_get_functiondef('public.ft_fast_flashscore_summary(integer)'::regprocedure) into def;
needle := $old$'forebet_avg_goals',fb.avg_goals,$old$;
repl := $new$'forebet_avg_goals',fb.avg_goals,
   'historical_form_home',public.ft_historical_form_by_team(f.home_en,f.league,f.kickoff_hkt),
   'historical_form_away',public.ft_historical_form_by_team(f.away_en,f.league,f.kickoff_hkt),$new$;
if position(needle in def)=0 or (length(def)-length(replace(def,needle,'')))<>length(needle)
then raise exception 'FAST_SUMMARY_CONTRACT_CHANGED_REFUSE_PATCH';end if;
execute replace(def,needle,repl);
end $patch$;
