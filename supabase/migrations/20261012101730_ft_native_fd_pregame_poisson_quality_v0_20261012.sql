-- Runtime equivalent of FAST_TRACKER_INDEPENDENT_POISSON_V0 for a
-- verified FOOTBALL_DATA league and strict as-of historical source capture.
-- Private experimental use only. Does not feed public prediction columns.
CREATE OR REPLACE FUNCTION private.ft_native_fd_poisson(
 p_league text,p_home text,p_away text,p_asof timestamptz)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path TO 'pg_catalog','public','private','pg_temp'
AS $fn$
DECLARE
 v_n integer; v_hbase double precision; v_abase double precision;
 v_latest date; v_latest_capture timestamptz; v_input_hash text;
 h_tot integer; a_tot integer; h_n integer; a_n integer;
 h_for double precision; h_against double precision; a_for double precision; a_against double precision;
 lh double precision; la double precision;
 i integer;j integer;
 p double precision; mass double precision:=0; ph double precision:=0; pd double precision:=0; pa double precision:=0;
 ov double precision:=0; largest double precision:=-1; score text;
 ph_base double precision:=0;pd_base double precision:=0;pa_base double precision:=0;prior_p double precision;
 c_league integer;c_home integer;c_away integer;
 mean_league double precision; mean_home double precision; mean_away double precision;
 corner_mu double precision;corner_under double precision;corner_payload jsonb:=null;
BEGIN
 IF p_league IS NULL OR p_league !~ '^[A-Za-z0-9]{1,12}$'
   OR p_home IS NULL OR p_away IS NULL OR p_home=p_away
   OR p_asof IS NULL OR p_asof>now()+interval '1 minute'
   OR p_asof<now()-interval '1 day'
 THEN RETURN jsonb_build_object('status','INVALID_IDENTITY_OR_ASOF'); END IF;
 SELECT count(*)::integer,avg(fthg::double precision),avg(ftag::double precision),
 max(match_date),max(fetched_at),
 md5(string_agg(match_key||':'||row_hash,'|' ORDER BY match_key))
 INTO v_n,v_hbase,v_abase,v_latest,v_latest_capture,v_input_hash
 FROM public.football_data_matches
 WHERE league_code=p_league AND source_kind='RESULTS'
   AND match_date<(p_asof AT TIME ZONE 'UTC')::date
   AND match_date>(p_asof AT TIME ZONE 'UTC')::date-365
   AND fetched_at<=p_asof AND first_seen_at<=p_asof
   AND fthg BETWEEN 0 AND 20 AND ftag BETWEEN 0 AND 20
   AND match_key IS NOT NULL AND source_file IS NOT NULL;
 IF v_n<60 THEN
  RETURN jsonb_build_object('status','INSUFFICIENT_LEAGUE_RESULTS','trainingCount',v_n);
 END IF;
 IF v_latest<(p_asof AT TIME ZONE 'UTC')::date-30 THEN
  RETURN jsonb_build_object('status','STALE_TRAINING_DATA','latestResultDate',v_latest,'trainingCount',v_n);
 END IF;
 IF v_hbase NOT BETWEEN 0.4 AND 5 OR v_abase NOT BETWEEN 0.4 AND 5
 THEN RETURN jsonb_build_object('status','INVALID_LEAGUE_BASELINE'); END IF;

 SELECT count(*) FILTER (WHERE home_team=p_home OR away_team=p_home),
        count(*) FILTER (WHERE home_team=p_home),
        coalesce(sum(fthg) FILTER (WHERE home_team=p_home),0),
        coalesce(sum(ftag) FILTER (WHERE home_team=p_home),0),
        count(*) FILTER (WHERE home_team=p_away OR away_team=p_away),
        count(*) FILTER (WHERE away_team=p_away),
        coalesce(sum(ftag) FILTER (WHERE away_team=p_away),0),
        coalesce(sum(fthg) FILTER (WHERE away_team=p_away),0)
 INTO h_tot,h_n,h_for,h_against,a_tot,a_n,a_for,a_against
 FROM public.football_data_matches
 WHERE league_code=p_league AND source_kind='RESULTS'
   AND match_date<(p_asof AT TIME ZONE 'UTC')::date
   AND match_date>(p_asof AT TIME ZONE 'UTC')::date-365
   AND fetched_at<=p_asof AND first_seen_at<=p_asof
   AND fthg BETWEEN 0 AND 20 AND ftag BETWEEN 0 AND 20
   AND match_key IS NOT NULL AND source_file IS NOT NULL;
 IF h_tot<6 OR a_tot<6 OR h_n<2 OR a_n<2
 THEN RETURN jsonb_build_object('status','INSUFFICIENT_TEAM_HISTORY',
       'trainingCount',v_n,'homeGames',h_tot,'awayGames',a_tot); END IF;

 lh:=greatest(0.35,least(4.2,
   v_hbase*((h_for+7*v_hbase)/(h_n+7)/v_hbase)*
           ((a_against+7*v_hbase)/(a_n+7)/v_hbase)));
 la:=greatest(0.35,least(4.2,
   v_abase*((a_for+7*v_abase)/(a_n+7)/v_abase)*
           ((h_against+7*v_abase)/(h_n+7)/v_abase)));
 FOR i IN 0..14 LOOP
   FOR j IN 0..14 LOOP
     p:=exp(-lh)*power(lh,i)/factorial(i)::double precision *
       exp(-la)*power(la,j)/factorial(j)::double precision;
     mass:=mass+p;
     IF i>j THEN ph:=ph+p; ELSIF i=j THEN pd:=pd+p; ELSE pa:=pa+p; END IF;
     IF i+j>=3 THEN ov:=ov+p; END IF;
     IF p>largest THEN largest:=p;score:=i::text||'-'||j::text;END IF;
     prior_p:=exp(-v_hbase)*power(v_hbase,i)/factorial(i)::double precision *
              exp(-v_abase)*power(v_abase,j)/factorial(j)::double precision;
     IF i>j THEN ph_base:=ph_base+prior_p;
     ELSIF i=j THEN pd_base:=pd_base+prior_p;
     ELSE pa_base:=pa_base+prior_p; END IF;
   END LOOP;
 END LOOP;
 IF mass<0.999 THEN RETURN jsonb_build_object('status','INVALID_DISTRIBUTION'); END IF;

 SELECT count(*) FILTER (WHERE home_corners BETWEEN 0 AND 30 AND away_corners BETWEEN 0 AND 30),
        avg((home_corners+away_corners)::double precision) FILTER (WHERE home_corners BETWEEN 0 AND 30 AND away_corners BETWEEN 0 AND 30),
        count(*) FILTER (WHERE (home_team=p_home OR away_team=p_home) AND home_corners BETWEEN 0 AND 30 AND away_corners BETWEEN 0 AND 30),
        avg((home_corners+away_corners)::double precision) FILTER (WHERE (home_team=p_home OR away_team=p_home) AND home_corners BETWEEN 0 AND 30 AND away_corners BETWEEN 0 AND 30),
        count(*) FILTER (WHERE (home_team=p_away OR away_team=p_away) AND home_corners BETWEEN 0 AND 30 AND away_corners BETWEEN 0 AND 30),
        avg((home_corners+away_corners)::double precision) FILTER (WHERE (home_team=p_away OR away_team=p_away) AND home_corners BETWEEN 0 AND 30 AND away_corners BETWEEN 0 AND 30)
 INTO c_league,mean_league,c_home,mean_home,c_away,mean_away
 FROM public.football_data_matches
 WHERE league_code=p_league AND source_kind='RESULTS'
   AND match_date<(p_asof AT TIME ZONE 'UTC')::date
   AND match_date>(p_asof AT TIME ZONE 'UTC')::date-365
   AND fetched_at<=p_asof AND first_seen_at<=p_asof
   AND fthg BETWEEN 0 AND 20 AND ftag BETWEEN 0 AND 20
   AND match_key IS NOT NULL AND source_file IS NOT NULL;
 IF c_league>=60 AND c_home>=6 AND c_away>=6 THEN
   corner_mu:=greatest(5,least(17,
     (12*mean_league+c_home*mean_home+c_away*mean_away)/
     (12+c_home+c_away)));
   SELECT sum(exp(-corner_mu)*power(corner_mu,k)/factorial(k)::double precision)
   INTO corner_under FROM generate_series(0,9) k;
   corner_payload:=jsonb_build_object('over95',1-corner_under,
      'under95',corner_under,'expectedCorners',corner_mu,'observedCornerGames',c_league);
 END IF;

 RETURN jsonb_build_object('status','EXPERIMENTAL_UNCALIBRATED',
  'modelVersion','FAST_TRACKER_INDEPENDENT_POISSON_V0_SQL_EXPERIMENTAL',
  'trainingSource','FOOTBALL_DATA','league',p_league,
  'homeId',p_home,'awayId',p_away,'asOf',p_asof,
  'trainingCount',v_n,'trainingFingerprint',v_input_hash,
  'latestResultDate',v_latest,'latestCaptureAt',v_latest_capture,
  'expectedHomeGoals',lh,'expectedAwayGoals',la,
  'home',ph/mass,'draw',pd/mass,'away',pa/mass,
  'over25',ov/mass,'under25',1-ov/mass,
  'predictedScore',score,'corners',corner_payload,
  'baselineHome',ph_base,'baselineDraw',pd_base,
  'baselineAway',pa_base,'capturePolicy','SOURCE_OBSERVED_BEFORE_FORECAST_ASOF');
END
$fn$;
REVOKE ALL ON FUNCTION private.ft_native_fd_poisson(text,text,text,timestamptz)
FROM PUBLIC,anon,authenticated;
