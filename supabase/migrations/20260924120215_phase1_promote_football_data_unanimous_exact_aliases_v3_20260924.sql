insert into public.team_name_master (source,source_name,source_key,team_key,hkjc_name_en,hkjc_name_zh,status,confidence,event_count,first_seen_at,last_seen_at,evidence_sources,updated_at)
select 'FOOTBALL_DATA', g.source_name, regexp_replace(lower(g.source_name),'[^a-z0-9]+','','g'), min(m.team_key), max(m.hkjc_name_en), max(m.hkjc_name_zh), 'VERIFIED', 1.0, g.event_count, g.first_seen_at, g.last_seen_at, jsonb_agg(distinct m.source), now()
from public.phase1_football_data_league_identity_gap_v g
join public.team_name_master m on m.status='VERIFIED' and m.source<>'FOOTBALL_DATA' and m.source_key=regexp_replace(lower(g.source_name),'[^a-z0-9]+','','g')
where g.action='NEEDS_TEAM_IDENTITY' and not exists (select 1 from public.team_name_master z where z.source='FOOTBALL_DATA' and z.source_key=regexp_replace(lower(g.source_name),'[^a-z0-9]+','','g'))
group by g.league_code,g.source_name,g.event_count,g.first_seen_at,g.last_seen_at
having count(distinct m.team_key)=1;
