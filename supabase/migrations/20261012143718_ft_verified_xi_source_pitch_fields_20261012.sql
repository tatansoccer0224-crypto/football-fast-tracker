-- Preserve official XI identity rules and use stored provider pitch fields; no tables or crawlers.
CREATE OR REPLACE FUNCTION public.ft_verified_lineup_fast(p_match_id text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
with candidates as (
 select l.source_name,
   count(*) filter(where l.team_side='H') h,
   count(*) filter(where l.team_side='A') a,
   count(distinct l.player_key) distinct_players,
   count(*) filter(where p.player_key is not null and
     regexp_replace(lower(trim(p.canonical_name)),'[^a-z0-9]','','g') =
     regexp_replace(lower(trim(l.player_name)),'[^a-z0-9]','','g')
   ) canonical_matched,
   max(l.source_updated_at) observed_at
 from public.phase2_match_lineup_evidence l
 left join public.phase2_players p on p.player_key=l.player_key
 where l.match_id=p_match_id and p_match_id like 'FS:%'
   and l.starter=true and l.confirmed=true
   and l.team_side in('H','A')
   and l.source_name in('FOTMOB_OFFICIAL','FLASHSCORE_OFFICIAL')
   and length(coalesce(l.player_key,''))>=4
 group by l.source_name
), verified as(
 select * from candidates
 where h=11 and a=11 and distinct_players=22
 and observed_at between now()-interval '72 hours' and now()+interval '5 minutes'
 and ((source_name='FOTMOB_OFFICIAL' and canonical_matched=22)
       or source_name='FLASHSCORE_OFFICIAL')
 order by (canonical_matched=22) desc,
      (source_name='FOTMOB_OFFICIAL') desc,observed_at desc
 limit 1
)
select jsonb_build_object(
 'source',v.source_name,
 'confirmedAt',v.observed_at,
 'homeStarters',v.h,'awayStarters',v.a,
 'canonicalIdentitiesVerified',(v.canonical_matched=22),
 'sourceConfirmed',true,
 'rows',(
  select coalesce(jsonb_agg(jsonb_build_object(
    'player_name', l.player_name,
    'player_key', l.player_key,
    'canonical_player_key', case when v.canonical_matched=22 then p.player_key else null end,
    'canonical_player_name', case when v.canonical_matched=22 then p.canonical_name else null end,
    'team_side',l.team_side,
    'shirt_number',l.shirt_number,
    'formation_slot', case when l.formation_slot ~ '^[1-5][:.-][1-5]$' then l.formation_slot else null end,
    'formation', nullif(l.raw->>'formation',''),
    'position_x', case when l.source_name='FOTMOB_OFFICIAL' and jsonb_typeof(l.raw #> '{verticalLayout,x}')='number' then (l.raw #>> '{verticalLayout,x}')::numeric else null end,
    'position_y', case when l.source_name='FOTMOB_OFFICIAL' and jsonb_typeof(l.raw #> '{verticalLayout,y}')='number' then (l.raw #>> '{verticalLayout,y}')::numeric else null end,
    'role',coalesce(l.role,case when v.canonical_matched=22 then p.position else null end),
    'starter',true,'confirmed',true,
    'source_name',l.source_name,
    'source_updated_at',l.source_updated_at,
    'fact_status',case when v.canonical_matched=22 then 'CONFIRMED' else 'SOURCE_CONFIRMED_IDENTITY_UNRESOLVED' end
   ) order by l.team_side,l.shirt_number,l.player_name),'[]'::jsonb)
  from public.phase2_match_lineup_evidence l
  left join public.phase2_players p on p.player_key=l.player_key
  where l.match_id=p_match_id and l.source_name=v.source_name
   and l.starter and l.confirmed and l.team_side in('H','A')
 )
) from verified v;
$function$

