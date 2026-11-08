#!/usr/bin/env python3
"""One-shot read-only BetClan listing structure probe. Prints counts, never HTML."""
import json
import re
import requests
from bs4 import BeautifulSoup
from scripts.adviser_source_capture import SOURCES, fetch, candidate_urls, betclan_utc_listing_evidence

html = fetch(requests.Session(), SOURCES["BETCLAN"][0])
soup = BeautifulSoup(html, "html.parser")
cards = soup.select("div.bclisttip")
stats = {"html_bytes": len(html.encode()), "cards": len(cards),
         "candidate_urls": len(candidate_urls(html, "BETCLAN")),
         "strict_listing_proofs": len(betclan_utc_listing_evidence(html)),
         "all_scripts": len(soup.select('script[type="application/ld+json"]')),
         "cards_with_url": 0, "cards_with_clock": 0,
         "cards_with_teams": 0, "cards_with_script": 0,
         "sportsevents_in_cards": 0, "sportsevents_utc": 0,
         "sportsevents_other_zone": 0, "json_parse_failures": 0, "json_empty_string": 0,
         "json_types": {}, "json_preview": None, "json_error_examples": [], "event_url_equal_anchor": 0,
         "event_names_equal_card": 0, "utc_time_equal_clock": 0,
         "examples": []}
for cell in cards:
    link = cell.find("a", href=True)
    clock = cell.select_one(".bctime .convert_date")
    home = cell.select_one(".bchome")
    away = cell.select_one(".bcaway")
    scripts = cell.find_all("script", type="application/ld+json")
    stats["cards_with_url"] += bool(link)
    stats["cards_with_clock"] += bool(clock)
    stats["cards_with_teams"] += bool(home and away)
    stats["cards_with_script"] += bool(scripts)
    for s in scripts:
        try:
            raw = s.string or ""
            if not raw:
                stats["json_empty_string"] += 1
            if stats["json_preview"] is None:
                stats["json_preview"] = str(raw)[:120]
            data = json.loads(raw)
            types = (data if isinstance(data, list) else [data])
            for node in types:
                if isinstance(node, dict):
                    k=str(node.get("@type"))
                    stats["json_types"][k] = stats["json_types"].get(k, 0) + 1
        except (TypeError, ValueError) as exc:
            stats["json_parse_failures"] += 1
            if len(stats["json_error_examples"]) < 4:
                at = getattr(exc, "pos", 0)
                stats["json_error_examples"].append({
                    "error_type": type(exc).__name__, "position": at,
                    "reason": getattr(exc,"msg",str(exc))[:90],
                    "snippet": str(raw)[max(0,at-60):at+90],
                    "length": len(str(raw))
                })
            continue
        for ev in data if isinstance(data, list) else [data]:
            if not isinstance(ev, dict) or ev.get("@type") != "SportsEvent":
                continue
            stats["sportsevents_in_cards"] += 1
            stamp = ev.get("startDate")
            stats["sportsevents_utc"] += isinstance(stamp,str) and stamp.endswith("Z")
            stats["sportsevents_other_zone"] += isinstance(stamp,str) and not stamp.endswith("Z")
            url_matches = bool(link and ev.get("url") == link.get("href"))
            stats["event_url_equal_anchor"] += url_matches
            names_match = bool(home and away and
                ev.get("homeTeam",{}).get("name") == home.get_text(" ",strip=True) and
                ev.get("awayTeam",{}).get("name") == away.get_text(" ",strip=True))
            stats["event_names_equal_card"] += names_match
            stats["utc_time_equal_clock"] += bool(
                isinstance(stamp,str) and stamp.endswith("Z") and clock and
                stamp[11:16] == clock.get_text(" ",strip=True))
            if len(stats["examples"])<4:
                stats["examples"].append({
                    "url_tail": str(ev.get("url","")).split("/football/")[-1][:35],
                    "startDate": stamp,
                    "display": clock.get_text(" ",strip=True) if clock else None,
                    "same_url": url_matches, "same_teams": names_match,
                    "location": (ev.get("location") or {}).get("name")
                      if isinstance(ev.get("location"),dict) else None})
print("BETCLAN_LISTING_SOURCE_CONTRACT", json.dumps(stats,sort_keys=True))
if stats["candidate_urls"]<20:
    raise SystemExit("SOURCE_PAGE_CONTRACT_UNAVAILABLE")
