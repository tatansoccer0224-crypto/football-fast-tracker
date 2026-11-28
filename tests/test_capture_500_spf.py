import sys
import io
import urllib.error
import unittest
from unittest.mock import patch
from datetime import datetime,timezone
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"scripts"))
from capture_500_spf import read_official,resolve_canonical,get,_retryable_source_error

NOW=datetime(2026,10,10,12,25,tzinfo=timezone.utc)
FIXTURES=[
 {"id":"FB6342","kickoff":"2026-10-10T11:30:00Z","home":"Arsenal","away":"Leeds","league":"EPL"},
 {"id":"FB6346","kickoff":"2026-10-10T14:00:00Z","home":"Chelsea","away":"Bournemouth","league":"EPL"},
]
XML=b'<root><m id="2041867" matchnum="6005" league="\xe8\x8b\xb1\xe6\xa0\xbc\xe5\x85\xb0\xe8\xb6\x85\xe7\xba\xa7\xe8\x81\x94\xe8\xb5\x9b" home="\xe9\x98\xbf\xe6\xa3\xae\xe7\xba\xb3" away="\xe5\x88\xa9\xe5\x85\xb9\xe8\x81\x94"><row win="2.02" draw="3.50" lost="2.87" updatetime="2026-10-10 19:54"/></m></root>'
HTML='<table><tr data-processname="6005" data-id="2041867" data-matchdate="2026-10-10" data-matchtime="19:30"></tr></table>'
class ProviderTests(unittest.TestCase):
 def test_exact_join_and_prices(self):
  rows=read_official(XML,HTML,NOW)
  self.assertEqual(len(rows),1)
  self.assertEqual(rows[0]["source_event_id"],"2041867")
  self.assertEqual(rows[0]["home"],2.02)
  self.assertEqual(rows[0]["kickoff"],"2026-10-10T11:30:00+00:00")
  self.assertEqual(resolve_canonical(rows,FIXTURES,NOW)[0]["match_id"],"FB6342")
 def test_source_timestamp_with_seconds(self):
  rows=read_official(XML.replace(b"2026-10-10 19:54",b"2026-10-10 19:54:12"),HTML,NOW)
  self.assertEqual(len(rows),1)
 def test_wrong_provider_event_id(self):
  self.assertEqual(read_official(XML,HTML.replace("2041867","99999"),NOW),[])
 def test_reversed_fixture_never_matches(self):
  rows=read_official(XML,HTML,NOW)
  bad=[dict(FIXTURES[0],home="Leeds",away="Arsenal")]
  self.assertEqual(resolve_canonical(rows,bad,NOW),[])
 def test_time_drift_rejected(self):
  rows=read_official(XML,HTML,NOW)
  changed=[dict(FIXTURES[0],kickoff="2026-10-10T13:00:00Z")]
  self.assertEqual(resolve_canonical(rows,changed,NOW),[])
 def test_ambiguous_alias_rejected(self):
  rows=read_official(XML,HTML,NOW)
  self.assertEqual(resolve_canonical(rows,[dict(FIXTURES[0],id="FB1"),dict(FIXTURES[0],id="FB2")],NOW),[])
 def test_price_below_1_01_rejected(self):
  self.assertEqual(read_official(XML.replace(b'win="2.02"',b'win="0.0"'),HTML,NOW),[])
 def test_non_epl_rejected(self):
  rows=read_official(XML.replace("英格兰超级联赛".encode(), "法国甲级联赛".encode()),HTML,NOW)
  self.assertEqual(resolve_canonical(rows,FIXTURES,NOW),[])
 def test_stale_timestamp_future_rejected(self):
  self.assertEqual(read_official(XML.replace(b'2026-10-10 19:54',b'2026-10-11 19:54'),HTML,NOW),[])
 def test_duplicate_index_rejected(self):
  self.assertEqual(read_official(XML,HTML.replace('</table>','<tr data-processname="6005" data-id="2041867" data-matchdate="2026-10-10" data-matchtime="19:30"></tr></table>'),NOW),[])
 def test_verified_major_leagues_exact_pair_and_identity(self):
  pairs=[
   ("西班牙甲级联赛","巴列卡诺","毕尔巴鄂竞技","Rayo Vallecano","Ath. Bilbao","LaLigaSPAIN: Standings","FS:ES","2026-10-10T12:00:00Z"),
   ("意大利甲级联赛","热那亚","佛罗伦萨","Genoa","Fiorentina","Serie AITALY: Standings","FS:IT","2026-10-10T13:00:00Z"),
   ("德国甲级联赛","柏林联合","埃尔沃斯堡","Union Berlin","Elversberg","BundesligaGERMANY: Standings","FS:DE","2026-10-10T13:30:00Z"),
   ("法国甲级联赛","里尔","勒阿弗尔","Lille","Le Havre","Ligue 1FRANCE: Standings","FS:FR","2026-10-10T15:15:00Z"),
  ]
  src=[dict(source_league=league,source_home=hc,source_away=ac,kickoff=kick)
       for league,hc,ac,he,ae,lg,mid,kick in pairs]
  fixt=[dict(league=lg,home=he,away=ae,id=mid,kickoff=kick)
        for league,hc,ac,he,ae,lg,mid,kick in pairs]
  # Another Bundesliga at the same kickoff cannot create time-only matching.
  fixt.append(dict(id="FS:OTHER",home="Mainz",away="Leverkusen",
                   league="BundesligaGERMANY: Standings",kickoff="2026-10-10T13:30:00Z"))
  resolved=resolve_canonical(src,fixt,NOW)
  self.assertEqual({x["match_id"] for x in resolved},{"FS:ES","FS:IT","FS:DE","FS:FR"})
  self.assertTrue(all(x["canonical_league"] for x in resolved))
 def test_cross_league_identity_rejected(self):
  row=dict(source_league="西班牙甲级联赛",source_home="巴列卡诺",source_away="毕尔巴鄂竞技",kickoff="2026-10-10T12:00:00Z")
  wrong=[dict(id="FS:BAD",league="BundesligaGERMANY: Standings",home="Rayo Vallecano",away="Ath. Bilbao",kickoff="2026-10-10T12:00:00Z")]
  self.assertEqual(resolve_canonical([row],wrong,NOW),[])
 def test_unknown_500_names_never_guessed(self):
  row=dict(source_league="西班牙甲级联赛",source_home="巴列卡诺",source_away="假名字",kickoff="2026-10-10T12:00:00Z")
  f=dict(id="FS:BAD",league="LaLigaSPAIN: Standings",home="Rayo Vallecano",away="Ath. Bilbao",kickoff="2026-10-10T12:00:00Z")
  self.assertEqual(resolve_canonical([row],[f],NOW),[])
class TransportRetryTests(unittest.TestCase):
 def test_initial_success_makes_exactly_one_official_request(self):
  with patch("capture_500_spf.urllib.request.urlopen",return_value=io.BytesIO(b"safe")) as urlopen, patch("capture_500_spf.time.sleep") as sleep:
   self.assertEqual(get("https://trade.500.com/example.xml",100),b"safe")
  self.assertEqual(urlopen.call_count,1)
  sleep.assert_not_called()

 def test_actual_tls_handshake_timeout_recovers_with_one_retry(self):
  side_effect=[urllib.error.URLError("_ssl.c:1063: The handshake operation timed out"),io.BytesIO(b"fresh")]
  with patch("capture_500_spf.urllib.request.urlopen",side_effect=side_effect) as urlopen, patch("capture_500_spf.time.sleep") as sleep:
   self.assertEqual(get("https://trade.500.com/example.xml",100),b"fresh")
  self.assertEqual(urlopen.call_count,2)
  sleep.assert_called_once_with(1)

 def test_http_503_recovers_but_403_404_and_bad_cert_do_not_retry(self):
  for code in (500,503,504):
   unavailable=urllib.error.HTTPError("https://trade.500.com/",code,"temporary",{},None)
   with self.subTest(code=code), patch("capture_500_spf.urllib.request.urlopen",side_effect=[unavailable,io.BytesIO(b"xml")]) as urlopen, patch("capture_500_spf.time.sleep") as sleep:
    self.assertEqual(get("https://trade.500.com/example.xml",100),b"xml")
    self.assertEqual(urlopen.call_count,2)
    sleep.assert_called_once_with(1)
  for code in (403,404,429):
   blocked=urllib.error.HTTPError("https://trade.500.com/",code,"do not retry",{},None)
   with self.subTest(code=code), patch("capture_500_spf.urllib.request.urlopen",side_effect=blocked) as urlopen, patch("capture_500_spf.time.sleep") as sleep:
    with self.assertRaises(urllib.error.HTTPError):
     get("https://trade.500.com/example.xml",100)
    self.assertEqual(urlopen.call_count,1)
    sleep.assert_not_called()
  with patch("capture_500_spf.urllib.request.urlopen",side_effect=urllib.error.URLError("CERTIFICATE_VERIFY_FAILED")) as urlopen,patch("capture_500_spf.time.sleep") as sleep:
   with self.assertRaises(urllib.error.URLError):
    get("https://trade.500.com/example.xml",100)
   self.assertEqual(urlopen.call_count,1)
   sleep.assert_not_called()

 def test_repeated_timeouts_end_with_error_and_never_use_stale_payload(self):
  with patch("capture_500_spf.urllib.request.urlopen",side_effect=urllib.error.URLError("handshake operation timed out")) as urlopen, patch("capture_500_spf.time.sleep") as sleep:
   with self.assertRaises(urllib.error.URLError):
    get("https://trade.500.com/example.xml",100)
   self.assertEqual(urlopen.call_count,3)
   self.assertEqual([c.args[0] for c in sleep.call_args_list],[1,3])

 def test_oversized_response_is_rejected_without_retry(self):
  with patch("capture_500_spf.urllib.request.urlopen",return_value=io.BytesIO(b"oversize")) as urlopen,patch("capture_500_spf.time.sleep") as sleep:
   with self.assertRaisesRegex(ValueError,"size limit"):
    get("https://trade.500.com/example.xml",4)
   self.assertEqual(urlopen.call_count,1)
   sleep.assert_not_called()

if __name__=="__main__":unittest.main()
