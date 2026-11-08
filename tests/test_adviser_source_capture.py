import unittest
import hashlib
import tempfile
from pathlib import Path
from unittest.mock import patch
from scripts.adviser_source_capture import parse_betclan, parse_sportytrader, candidate_urls, valid_triplet
from scripts.adviser_source_capture import betclan_utc_listing_evidence
from scripts.adviser_source_capture import collect
from scripts.adviser_source_capture import enrich_sportytrader_event
from scripts.adviser_source_capture import sportytrader_faq_utc
from scripts.adviser_source_capture import replay_saved_evidence


class BoundedSourceEvidenceTest(unittest.TestCase):
    def test_saved_replay_keeps_capture_time_and_rejects_changed_evidence_without_network(self):
        html = '<h1>QPR vs Derby Prediction</h1><p>16/10/2026 07:45</p>'
        digest = hashlib.sha256(html.encode()).hexdigest()
        report = {'generated_at':'2026-10-15T17:15:06Z','records':[{'source':'SPORTYTRADER','source_event_id':'123',
                  'source_url':'https://www.sportytrader.com/en/betting-tips/qpr-derby-123/',
                  'captured_at':'2026-10-15T17:15:06Z','raw_content_hash':digest}]}
        with tempfile.TemporaryDirectory() as directory, patch('scripts.adviser_source_capture.fetch') as fetch:
            path=Path(directory)/'sportytrader'/(digest+'.html');path.parent.mkdir();path.write_text(html)
            replay = replay_saved_evidence(report,directory)
            self.assertEqual(replay['generated_at'],report['generated_at'])
            self.assertEqual(replay['records'][0]['captured_at'],report['records'][0]['captured_at'])
            path.write_text(html+' changed')
            with self.assertRaisesRegex(ValueError,'hash_mismatch'):
                replay_saved_evidence(report,directory)
            fetch.assert_not_called()

    def test_source_linked_event_verifies_only_identical_oriented_clock_and_competition(self):
        import json
        # Saved live source artifact11994040671 / run38775736633.
        url = 'https://www.sportytrader.com/en/results-live/aberdeen-st-mirren-8556351/'
        row = {'source':'SPORTYTRADER','home':'Aberdeen','away':'St Mirren','source_date':'2026-10-17',
               'source_wall_time':'09:00','source_competition':'Scottish Premiership','kickoff_timezone_verified':False}
        event = {'@type':'SportsEvent','url':url,'startDate':'2026-10-17T09:00:00-05:00',
                 'homeTeam':{'name':'Aberdeen'},'awayTeam':{'name':'St Mirren'},'organizer':{'name':'Scottish Premiership'}}
        def page(events): return '<script type="application/ld+json">'+json.dumps(events)+'</script>'
        result = enrich_sportytrader_event(row,page([event]),url)
        self.assertTrue(result['kickoff_timezone_verified'])
        self.assertEqual(result['source_kickoff'],'2026-10-17T09:00:00-05:00')
        self.assertIsNone(result['source_event_status'])  # Not invented from a successful capture.
        for changed in [dict(event,startDate='2026-10-17T09:00:00'),dict(event,startDate='2026-10-17T10:00:00-05:00'),
                        dict(event,url=url.replace('8556351','999')),dict(event,homeTeam=event['awayTeam'],awayTeam=event['homeTeam']),
                        dict(event,organizer={'name':'Other league'})]:
            self.assertFalse(enrich_sportytrader_event(row,page([changed]),url)['kickoff_timezone_verified'])
        self.assertFalse(enrich_sportytrader_event(row,page([event,event]),url)['kickoff_timezone_verified'])

    def test_targeted_capture_preserves_replayable_html_without_other_provider_requests(self):
        html = '<h1>QPR vs Derby County Prediction</h1><p>16/10/2026 07:45</p><p>Prediction : BTTS 1.83</p>'
        calls = []
        def fake_fetch(session, url):
            calls.append(url)
            if url.endswith('-378837/'):
                return html
            return '<a href="/en/betting-tips/qpr-derby-county-378837/">tip</a><a href="/en/betting-tips/zz-other-378838/">other</a>'
        with tempfile.TemporaryDirectory() as directory, patch('scripts.adviser_source_capture.fetch', side_effect=fake_fetch):
            result = collect(source='SPORTYTRADER', limit=1, pause=0, evidence_dir=directory)
            self.assertEqual(len(result['records']), 1)
            self.assertTrue(all('sportytrader.com' in url for url in calls))
            self.assertEqual(len(calls), 3)  # Two listings, one deduplicated detail.
            digest = hashlib.sha256(html.encode()).hexdigest()
            self.assertEqual(result['records'][0]['raw_content_hash'], digest)
            self.assertEqual((Path(directory)/'sportytrader'/(digest+'.html')).read_text(), html)
            self.assertFalse(result['records'][0]['kickoff_timezone_verified'])

    def test_eight_request_budget_selects_major_upcoming_league_not_alphabetical(self):
        import json
        # Alphabetical 'a-minor' used to consume the scarce first linked
        # evidence request. The ranked selector must use the same one request
        # for the upcoming Premier League with a REAL timezone-aware event.
        minor='https://www.sportytrader.com/en/betting-tips/a-minor-cup-123/'
        major='https://www.sportytrader.com/en/betting-tips/z-liverpool-brentford-124/'
        minor_related='https://www.sportytrader.com/en/results-live/minor-cup-1111/'
        major_related='https://www.sportytrader.com/en/results-live/liverpool-brentford-2222/'
        listing=('<a href="/en/betting-tips/a-minor-cup-123/">minor</a>'
                 '<a href="/en/betting-tips/z-liverpool-brentford-124/">major</a>')
        minor_page=('<h1>Minor vs Cup Prediction & Betting Tips - Minor League</h1>'
                    '<p>18/10/2026 09:00</p><p>Prediction : BTTS</p>'
                    '<a href="/en/results-live/minor-cup-1111/">Live</a>')
        major_page=('<h1>Liverpool vs Brentford Prediction & Betting Tips - Premier League</h1>'
                    '<p>18/10/2026 09:00</p><p>Prediction : BTTS</p>'
                    '<a href="/en/results-live/liverpool-brentford-2222/">Live</a>')
        event={"@type":"SportsEvent","url":major_related,
               "startDate":"2026-10-18T09:00:00-05:00",
               "homeTeam":{"name":"Liverpool"},"awayTeam":{"name":"Brentford"},
               "organizer":{"name":"Premier League"}}
        major_source='<script type="application/ld+json">'+json.dumps(event)+'</script>'
        calls=[]
        def fake_fetch(session,url):
            calls.append(url)
            return {minor:minor_page,major:major_page,major_related:major_source}.get(url,listing)
        with tempfile.TemporaryDirectory() as directory, patch(
            'scripts.adviser_source_capture.fetch',side_effect=fake_fetch
        ):
            out=collect(source='SPORTYTRADER',limit=2,pause=0,
                        evidence_dir=directory,related_evidence_limit=1)
        self.assertEqual(len(calls),5,"two listing + two tips + SAME single linked page")
        self.assertIn(major_related,calls)
        self.assertNotIn(minor_related,calls)
        self.assertEqual(out['providers']['SPORTYTRADER']['related_candidates'],2)
        self.assertEqual(out['providers']['SPORTYTRADER']['related_attempted'],1)
        self.assertEqual(out['providers']['SPORTYTRADER']['related_budget'],1)
        self.assertEqual(out['providers']['SPORTYTRADER']['related_verified_kickoff'],1)
        self.assertEqual(len(out['records']),2)
        minor_row,major_row=out['records']
        self.assertFalse(minor_row['kickoff_timezone_verified'])
        self.assertTrue(major_row['kickoff_timezone_verified'])
        self.assertEqual(major_row['source_kickoff'],"2026-10-18T09:00:00-05:00")
        self.assertIsNone(major_row['canonical_event_id'],
            "Linked SportyTrader event proves source clock but not Flashscore identity")

    def test_invalid_bounds_reject_before_network(self):
        for kwargs in ({'limit':0}, {'limit':121}, {'source':'UNKNOWN'}, {'related_evidence_limit':17}, {'related_evidence_limit':1}):
            with self.assertRaises(ValueError), patch('scripts.adviser_source_capture.fetch') as fetch:
                collect(**kwargs)
            fetch.assert_not_called()

    def test_sixteen_linked_proofs_is_valid_but_still_hard_capped(self):
        # The daily linked-event proof budget increases but is never
        # an unbounded scraper. Even if 17 links are supplied, only 16
        # directly source-linked event pages may be requested.
        listing="".join(
            f'<a href="/en/betting-tips/testhome-testaway-{600000+i}/">tip</a>'
            for i in range(17))
        detail_html=lambda i: (
            '<h1>Testhome vs Testaway Prediction & Betting Tips - Premier League</h1>'
            '<p>08/11/2026 09:30</p><p>Prediction : BTTS</p>'
            f'<a href="/en/results-live/testhome-testaway-{800000+i}/">Event</a>')
        calls=[]
        def fake_fetch(session,url):
            calls.append(url)
            if "/en/betting-tips/football/" in url:
                return listing
            import re
            m=re.search(r"/en/betting-tips/testhome-testaway-(\d+)/",url)
            if m: return detail_html(int(m.group(1))-600000)
            return '<html>No verified event JSON-LD</html>'
        with tempfile.TemporaryDirectory() as tmp, patch(
            'scripts.adviser_source_capture.fetch',side_effect=fake_fetch):
            result=collect(source="SPORTYTRADER",limit=17,pause=0,
                           evidence_dir=tmp,related_evidence_limit=16)
        stats=result["providers"]["SPORTYTRADER"]
        self.assertEqual(stats["related_attempted"],16)
        self.assertEqual(stats["related_budget"],16)
        self.assertEqual(sum("/en/results-live/" in url for url in calls),16)
        self.assertEqual(len(result["records"]),17)
        self.assertEqual(stats["related_verified_kickoff"] if "related_verified_kickoff" in stats else 0,0)

    def test_related_evidence_is_explicit_bounded_and_does_not_verify_kickoff(self):
        html = '<h1>QPR vs Derby Prediction</h1><p>16/10/2026 07:45</p><a href="/en/results-live/qpr-derby-123/">Live</a>'
        related_html = '<script type="application/ld+json">{"@type":"SportsEvent","startDate":"2026-10-16T19:45:00Z"}</script>'
        def fake_fetch(session, url):
            if '/results-live/' in url:
                return related_html
            if url.endswith('-378837/'):
                return html
            return '<a href="/en/betting-tips/qpr-derby-378837/">tip</a>'
        with tempfile.TemporaryDirectory() as directory, patch('scripts.adviser_source_capture.fetch', side_effect=fake_fetch) as fetch:
            result = collect(source='SPORTYTRADER', limit=1, pause=0, evidence_dir=directory, related_evidence_limit=1)
            self.assertEqual(fetch.call_count, 4)
            row = result['records'][0]
            digest = hashlib.sha256(related_html.encode()).hexdigest()
            self.assertEqual(row['related_content_hash'], digest)
            self.assertEqual((Path(directory)/'sportytrader-related'/(digest+'.html')).read_text(), related_html)
            self.assertFalse(row['kickoff_timezone_verified'])


class AdviserSourceCaptureTest(unittest.TestCase):
    def test_betclan_genuine_detail_shape(self):
        html = """<h1>QPR vs Derby Prediction, H2H, Tip and Match Preview</h1>
        <p>Date 2026-10-14 19:45</p><h4>Winner</h4>
        <p>QPR Home 57% Draw 23% Away 20%</p>
        <h4>Total Goals 2.5</h4><p>Under 44% Over 56%</p>
        <h4>Both Teams to Score BTTS</h4><p>Yes 58% No 42%</p>
        <h4>Correct Score</h4><p>3-1 13% Others 87%</p>
        <h3>Team Momentum</h3>"""
        row = parse_betclan(html, "https://www.betclan.com/predictionsdetails/football/1563202/qpr-v-derby-prediction/")
        self.assertEqual(row["hda"], {"home": 0.57, "draw": 0.23, "away": 0.2})
        self.assertEqual(row["predicted_score"], "3-1")
        self.assertEqual(row["over25"], 0.56)
        self.assertEqual(row["btts_yes"], 0.58)
        self.assertIsNone(row["canonical_event_id"])
        self.assertFalse(row["kickoff_timezone_verified"])

    def test_sportytrader_tip_is_not_fake_probability(self):
        html = """<h1>QPR vs Derby County Prediction & Betting Tips - Championship</h1>
          <div>15/10/2026 07:45</div><p>Prediction : BTTS 1.83</p>
          <p>Prediction published on 14/10/2026</p>"""
        row = parse_sportytrader(html, "https://www.sportytrader.com/en/betting-tips/qpr-derby-county-378837/")
        self.assertEqual(row["tip"], "BTTS")
        self.assertEqual(row["source_date"], "2026-10-15")
        self.assertIsNone(row["hda"])
        self.assertEqual(row["identity"], "UNRESOLVED")


    def test_sportytrader_verified_algorithm_not_bookmaker_odds(self):
        html = """<h1>QPR vs Derby County Prediction & Betting Tips - Championship</h1>
          <div>15/10/2026 07:45</div><p>Prediction : Under 2.5 goals 1.83</p>
          <p>Prediction published on 14/10/2026</p>
          <p>Probabilities according to our algorithm of possible 1X2 football predictions
          The Sportytrader algorithm estimates a probability of 43.66% for a win of QPR.
          The probability according to Sportytrader for a draw between QPR vs Derby County is 36.64%.
          Our prediction model gives a 19.71% chance for a win of Derby County vs QPR.
          </p><h3>QPR - Derby County Prediction and Best Odds:</h3>"""
        row = parse_sportytrader(html, "https://www.sportytrader.com/en/betting-tips/qpr-derby-county-378837/")
        self.assertEqual(row["tip"], "Under 2.5 goals")
        self.assertEqual(row["hda"], {"home": .4366, "draw": .3664, "away": .1971})
        self.assertIsNone(row["canonical_event_id"])

    def test_source_boundary(self):
        html = """<a href="/predictionsdetails/football/123/abc">One</a>
           <a href="https://evil.test/predictionsdetails/football/999/bad">Evil</a>"""
        self.assertEqual(len(candidate_urls(html, "BETCLAN")), 1)

    def test_wrong_probability_triplet_rejected(self):
        self.assertIsNone(valid_triplet({"home": .8, "draw": .4, "away": .3}))


if __name__ == "__main__":
    unittest.main()


class BetClanUTCListingCrosscheckTest(unittest.TestCase):
    """Exact current-source regression; no HTTP calls and no guessed DST shift."""
    URL = ("https://www.betclan.com/predictionsdetails/football/1550191/"
           "inter-v-como-prediction-h2h-tip-and-match-preview/")

    def listing(self, start="2026-11-08T17:00:00Z", home="Inter",
                away="Como", clock="17:00", league="Italy Serie A"):
        import json
        event = {
            "@type": "SportsEvent", "url": self.URL, "startDate": start,
            "homeTeam": {"name": home}, "awayTeam": {"name": away},
            "location": {"name": league},
        }
        return (f'<div class="bclisttip"><a href="{self.URL}">'
                f'<div class="bctime"><span class="convert_date">{clock}</span></div>'
                f'<div class="bchome">{home}</div><div class="bcaway">{away}</div>'
                f'</a><script type="application/ld+json">{json.dumps(event)}</script></div>')

    def detail(self, start="2026-11-08T17:00:00+01:00", home="Inter",
               away="Como", league="Italy Serie A"):
        import json
        event = {
            "@type": "SportsEvent", "url": self.URL, "startDate": start,
            "homeTeam": {"name": home}, "awayTeam": {"name": away},
            "organizer": {"name": league},
        }
        return (f'<h1>{home} vs {away} Prediction</h1>'
                f'<div>Date 2026-11-08 17:00</div>'
                '<h4>Winner</h4><p>Home 60% Draw 20% Away 20%</p>'
                '<h4>Total Goals 2.5</h4><p>Over 51%</p>'
                f'<script type="application/ld+json">{json.dumps(event)}</script>')

    def test_malformed_live_listing_single_extra_brace_recovers_without_guessing(self):
        # Captured from BetClan's 2026-11-08 listing: 500 SportsEvent JSON-LD
        # scripts had exactly one extra } after otherwise valid source JSON.
        original=self.listing()
        malformed=original.replace("</script>", "}</script>")
        events=betclan_utc_listing_evidence(malformed)
        self.assertIn(self.URL,events)
        self.assertEqual(events[self.URL]["startDate"],"2026-11-08T17:00:00Z")
        row=parse_betclan(self.detail(),self.URL,events[self.URL])
        self.assertEqual(row["source_kickoff"],"2026-11-08T17:00:00+00:00")
        self.assertEqual(row["source_clock_disagreement_minutes"],60)

    def test_more_than_one_trailing_brace_is_not_silently_recovered(self):
        for bad in ('}}</script>', '}garbage</script>', '}null</script>'):
            data=self.listing().replace("</script>",bad)
            self.assertNotIn(self.URL,betclan_utc_listing_evidence(data))

    def test_list_detail_reconciliation_with_exact_one_brace_in_both_listings(self):
        calls=[]
        listing=self.listing().replace("</script>", "}</script>")
        def fake_fetch(session,url):
            calls.append(url)
            return self.detail() if url==self.URL else listing
        with patch("scripts.adviser_source_capture.fetch",side_effect=fake_fetch):
            out=collect(source="BETCLAN",limit=1,pause=0)
        self.assertEqual(len(calls),3)
        self.assertEqual(out["providers"]["BETCLAN"]["listing_utc_proofs"],1)
        self.assertEqual(out["providers"]["BETCLAN"]["clock_conflicts_resolved"],1)
        self.assertEqual(out["records"][0]["source_kickoff"],"2026-11-08T17:00:00+00:00")


    def test_missing_listing_utc_evidence_is_flagged_and_no_time_invented(self):
        # Regress the actual previous silent failure: many real-looking
        # listing URLs, but zero parseable independent listing UTC events.
        listing = "".join(
            f'<a href="/predictionsdetails/football/{9000+n}/match-{n}/">tip</a>'
            for n in range(25))
        detail = '<h1>Home vs Away Prediction</h1><p>Date 2026-11-08 17:00</p>'
        def fake_fetch(session,url):
            return detail if "/predictionsdetails/football/" in url else listing
        with patch("scripts.adviser_source_capture.fetch", side_effect=fake_fetch):
            out = collect(source="BETCLAN", limit=1, pause=0)
        self.assertEqual(out["providers"]["BETCLAN"]["candidate_urls"],25)
        self.assertEqual(out["providers"]["BETCLAN"]["listing_utc_proofs"],0)
        self.assertEqual(out["providers"]["BETCLAN"]["clock_proof_status"],
                         "PROOFS_UNAVAILABLE")
        self.assertIsNone(out["records"][0]["source_kickoff"])
        self.assertFalse(out["records"][0]["kickoff_timezone_verified"])

    def test_real_utc_conflict_is_resolved_from_exact_listing_sportsevent(self):
        proof = betclan_utc_listing_evidence(self.listing())[self.URL]
        row = parse_betclan(self.detail(), self.URL, proof)
        self.assertEqual(row["source_kickoff"], "2026-11-08T17:00:00+00:00")
        self.assertEqual(row["source_detail_kickoff"], "2026-11-08T17:00:00+01:00")
        self.assertEqual(row["source_listing_kickoff"], "2026-11-08T17:00:00Z")
        self.assertEqual(row["source_clock_disagreement_minutes"], 60)
        self.assertEqual(row["source_clock_basis"], "LISTING_UTC_CONFIRMED_DETAIL_CLOCK_CONFLICT")
        self.assertTrue(row["kickoff_timezone_verified"])
        self.assertEqual(row["source_competition"], "Italy Serie A")
        self.assertIsNone(row["canonical_event_id"])

    def test_source_does_not_gain_utc_proof_from_wrong_team_or_time(self):
        for html in [
            self.listing().replace('"name": "Inter"', '"name": "Other Team"'),
            self.listing(clock="16:00"),
            self.listing(start="2026-11-08T17:00:00+01:00"),
            self.listing(start="2026-11-08T16:00:00Z"),
        ]:
            self.assertNotIn(self.URL, betclan_utc_listing_evidence(html))
        for evidence in [None, {"startDate": "2026-11-08T17:00:00Z",
                                "home": "Other Team", "away": "Como",
                                "competition": "Italy Serie A"}]:
            row = parse_betclan(self.detail(), self.URL, evidence)
            self.assertEqual(row["source_kickoff"], "2026-11-08T17:00:00+01:00")

    def test_conflicting_listing_duplicates_fail_closed(self):
        html = self.listing() + self.listing(start="2026-11-08T18:00:00Z", clock="18:00")
        self.assertNotIn(self.URL, betclan_utc_listing_evidence(html))

    def test_multi_hour_conflict_remains_unknown(self):
        row = parse_betclan(
            self.detail(start="2026-11-08T17:00:00+03:00"),
            self.URL, betclan_utc_listing_evidence(self.listing())[self.URL])
        self.assertIsNone(row["source_kickoff"])
        self.assertFalse(row["kickoff_timezone_verified"])
        self.assertEqual(row["source_clock_basis"], "LISTING_DETAIL_CLOCK_CONFLICT_UNRESOLVED")

    def test_collect_crosschecks_both_listing_pages_without_extra_http(self):
        calls = []
        listing = self.listing()
        def fake_fetch(session, url):
            calls.append(url)
            return self.detail() if url == self.URL else listing
        with patch("scripts.adviser_source_capture.fetch", side_effect=fake_fetch):
            result = collect(source="BETCLAN", limit=1, pause=0)
        self.assertEqual(len(calls), 3, "two existing source listings + one detail")
        self.assertEqual(len(result["records"]), 1)
        self.assertEqual(result["records"][0]["source_kickoff"],
                         "2026-11-08T17:00:00+00:00")
        self.assertEqual(result["providers"]["BETCLAN"]["clock_conflicts_resolved"], 1)
        self.assertEqual(result["providers"]["BETCLAN"]["listing_utc_proofs"], 1)


class BetClanRegressionTest(unittest.TestCase):
    def page(self, start='2026-10-15T00:30:00+01:00'):
        import json
        event={'@type':'SportsEvent','url':'https://www.betclan.com/predictionsdetails/football/123/test/',
               'startDate':start,'homeTeam':{'name':'Home'},'awayTeam':{'name':'Away'},
               'organizer':{'name':'Estonia Meistriliiga'}}
        return '''<nav>Correct Score Calculator</nav><h1>Home vs Away Prediction</h1>
        <p>Date 2026-10-15 00:30</p><h4>Winner</h4><p>Home 60% Draw 20% Away 20%</p>
        <h4>Total Goals 2.5</h4><p>Over 63%</p><h4>Both Teams to Score</h4><p>Yes 61%</p>
        <h4>Correct Score</h4><h5>3-1</h5><h3>Team Momentum</h3>
        <script type="application/ld+json">'''+json.dumps(event)+'</script>'

    def test_navigation_date_is_never_score(self):
        row=parse_betclan(self.page(),'https://www.betclan.com/predictionsdetails/football/123/test/')
        self.assertEqual(row['predicted_score'],'3-1')
        self.assertEqual(row['source_kickoff'],'2026-10-15T00:30:00+01:00')
        self.assertTrue(row['kickoff_timezone_verified'])
        self.assertEqual(row['source_competition'],'Estonia Meistriliiga')

    def test_missing_market_stays_unknown(self):
        row=parse_betclan(self.page().replace('<h4>Correct Score</h4><h5>3-1</h5>',''),
                         'https://www.betclan.com/predictionsdetails/football/123/test/')
        self.assertIsNone(row['predicted_score'])

    def test_timezone_missing_or_conflicting_stays_unknown(self):
        for at in ['2026-10-15T00:30:00','2026-10-14T00:30:00+01:00']:
            row=parse_betclan(self.page(at),'https://www.betclan.com/predictionsdetails/football/123/test/')
            self.assertIsNone(row['source_kickoff'])
            self.assertFalse(row['kickoff_timezone_verified'])

    def test_bad_triplets(self):
        for triplet in [{'home':-.1,'draw':.5,'away':.6},{'home':float('nan'),'draw':.5,'away':.5},
                        {'home':True,'draw':0,'away':0},{'home':1.1,'draw':0,'away':-.1}]:
            self.assertIsNone(valid_triplet(triplet))



class SportyTraderSportBoundaryTest(unittest.TestCase):
    """2026-11-08: a Rugby Nations Championship tip leaked via football links."""
    def detail(self, sport="rugby", extra_nav=False):
        import json
        structured={"@type":"BreadcrumbList","itemListElement":[
            {"@type":"ListItem","item":"https://www.sportytrader.com/en/"},
            {"@type":"ListItem","item":"https://www.sportytrader.com/en/betting-tips/"},
            {"@type":"ListItem","item":f"https://www.sportytrader.com/en/betting-tips/{sport}/"},
        ]}
        nav = ('<a href="/en/betting-tips/rugby/">Global Nav Rugby</a>'
               if extra_nav else '')
        return (nav+'<h1>England vs Australia Prediction & Betting Tips - Nations Championship</h1>'
                '<p>08/11/2026 09:30</p><p>Prediction : BTTS</p>'
                '<script type="application/ld+json">'+json.dumps(structured)+'</script>')

    def test_actual_cross_sport_rugby_leak_is_rejected(self):
        from bs4 import BeautifulSoup
        from scripts.adviser_source_capture import sportytrader_is_football_tip
        url="https://www.sportytrader.com/en/betting-tips/england-australia-386278/"
        self.assertFalse(sportytrader_is_football_tip(
            BeautifulSoup(self.detail("rugby"),"html.parser")))
        self.assertIsNone(parse_sportytrader(self.detail("rugby"),url))
        self.assertIsNotNone(parse_sportytrader(self.detail("football"),url))

    def test_generic_navigation_link_to_rugby_does_not_reject_football(self):
        url="https://www.sportytrader.com/en/betting-tips/england-australia-386278/"
        self.assertIsNotNone(parse_sportytrader(
            self.detail("football",extra_nav=True),url))

    def test_mixed_breadcrumb_categories_and_broken_structured_proof_fail_closed(self):
        import json
        url="https://www.sportytrader.com/en/betting-tips/england-australia-386278/"
        mixed=self.detail("football").replace(
            '</script>',
            '<!-- extra-category -->'
            '</script>')
        # Syntactically malformed structured BreadcrumbList is not accepted.
        self.assertIsNone(parse_sportytrader(mixed,url))
        compound={"@type":"BreadcrumbList","itemListElement":[
            {"item":"https://www.sportytrader.com/en/betting-tips/football/"},
            {"item":"https://www.sportytrader.com/en/betting-tips/rugby/"}
        ]}
        another=self.detail("football").replace(
            self.detail("football").split('<script type="application/ld+json">')[1].split('</script>')[0],
            json.dumps(compound))
        self.assertIsNone(parse_sportytrader(another,url))

    def test_capture_tracks_nonfootball_exclusions_not_false_predictions(self):
        rugby="https://www.sportytrader.com/en/betting-tips/england-australia-386278/"
        football="https://www.sportytrader.com/en/betting-tips/brighton-brentford-385770/"
        listing=(f'<a href="{rugby}">Rugby</a><a href="{football}">Football</a>')
        def fake_fetch(session,url):
            return listing if url.endswith("/football/") or url.endswith("/football/tomorrow/") \
                else self.detail("rugby" if url==rugby else "football")
        with patch("scripts.adviser_source_capture.fetch",side_effect=fake_fetch):
            report=collect(source="SPORTYTRADER",limit=2,pause=0)
        self.assertEqual(report["providers"]["SPORTYTRADER"]["nonfootball_rejected"],1)
        self.assertEqual(len(report["records"]),1)
        self.assertEqual(report["records"][0]["source_event_id"],"385770")


class SportyTraderFAQCrossProofTest(unittest.TestCase):
    TIP="https://www.sportytrader.com/en/betting-tips/brighton-brentford-385770/"
    EVENT="https://www.sportytrader.com/en/results-live/brighton-brentford-8558904/"

    def tip_html(self, answer="The Premier League match between Brighton and Brentford "
                           "is due to take place on Sunday November 8 and begin at 14:00 UK time.",
                 question="When is Brighton v Brentford being played?"):
        import json
        faq={"@type":"FAQPage","mainEntity":[{"@type":"Question","name":question,
             "acceptedAnswer":{"@type":"Answer","text":answer}}]}
        return ('<h1>Brighton vs Brentford Prediction & Betting Tips - Premier League</h1>'
                '<p>08/11/2026 09:00</p><p>Prediction : BTTS</p>'
                '<a href="/en/results-live/brighton-brentford-8558904/">Match</a>'
                '<script type="application/ld+json">'+json.dumps([faq])+'</script>')

    def result_html(self, stamp="2026-11-08T08:00:00-06:00",
                    home="Brighton",away="Brentford",league="Premier League"):
        import json
        event={"@type":"SportsEvent","url":self.EVENT,"startDate":stamp,
               "homeTeam":{"name":home},"awayTeam":{"name":away},
               "organizer":{"name":league}}
        return '<script type="application/ld+json">'+json.dumps([event])+'</script>'

    def test_uk_faq_clock_corroborates_different_page_local_wall_time(self):
        tip=parse_sportytrader(self.tip_html(),self.TIP)
        self.assertEqual(tip["source_wall_time"],"09:00")
        self.assertEqual(tip["source_faq_kickoff_utc"],"2026-11-08T14:00:00+00:00")
        proof=enrich_sportytrader_event(tip,self.result_html(),self.EVENT)
        self.assertTrue(proof["kickoff_timezone_verified"])
        self.assertEqual(proof["source_kickoff"],"2026-11-08T08:00:00-06:00")
        self.assertEqual(proof["source_clock_basis"],"FAQ_GMT_AND_LINKED_SPORTSEVENT")
        self.assertIsNone(proof["canonical_event_id"],
                          "Source time alone never proves Flashscore fixture identity")
        self.assertEqual(proof.get("identity"),"UNRESOLVED")

    def test_other_event_timestamp_or_team_does_not_pass_utc_crosscheck(self):
        tip=parse_sportytrader(self.tip_html(),self.TIP)
        for html in [
            self.result_html(stamp="2026-11-08T09:00:00-06:00"),
            self.result_html(home="Brentford",away="Brighton"),
            self.result_html(league="Other League"),
            self.result_html(stamp="2026-11-08T08:00:00"),
        ]:
            self.assertFalse(enrich_sportytrader_event(
                tip,html,self.EVENT)["kickoff_timezone_verified"])

    def test_wrong_date_team_or_unzoned_faq_stays_unknown(self):
        cases=[
            {"answer":"The match is on November 9 at 14:00 UK time."},
            {"answer":"The match is on November 8 at 14:00, UK venue."},
            {"answer":"The match is on November 8 at 14:00 PST."},
            {"question":"When is Chelsea v Brentford being played?"},
        ]
        for change in cases:
            row=parse_sportytrader(self.tip_html(**change),self.TIP)
            self.assertIsNone(row["source_faq_kickoff_utc"])
            self.assertFalse(enrich_sportytrader_event(
                row,self.result_html(),self.EVENT)["kickoff_timezone_verified"])

    def test_uk_autumn_dst_fold_is_ambiguous_and_not_auto_confirmed(self):
        import json
        from bs4 import BeautifulSoup
        faq={"@type":"FAQPage","mainEntity":[{"@type":"Question",
             "name":"When is Brighton v Brentford being played?",
             "acceptedAnswer":{"text":"The match is on October 25 at 01:30 UK time."}}]}
        soup=BeautifulSoup('<script type="application/ld+json">'+json.dumps(faq)+'</script>',
                           'html.parser')
        self.assertIsNone(sportytrader_faq_utc(
            soup,"Brighton","Brentford","2026-10-25"))

    def test_existing_matching_wall_time_remains_valid_without_faq(self):
        tip=parse_sportytrader(self.tip_html(answer="No confirmed kickoff time."),
                              self.TIP)
        tip["source_wall_time"]="08:00"
        proof=enrich_sportytrader_event(tip,self.result_html(),self.EVENT)
        self.assertTrue(proof["kickoff_timezone_verified"])
        self.assertEqual(proof["source_clock_basis"],"WALL_CLOCK_AND_LINKED_SPORTSEVENT")
