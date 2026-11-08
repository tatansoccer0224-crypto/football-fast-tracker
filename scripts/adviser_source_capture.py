#!/usr/bin/env python3
"""Bounded, evidence-only captures of BetClan and SportyTrader soccer tips.

This deliberately does NOT match provider names directly to Flashscore IDs.
The canonical reconciliation job must verify date, competition, both teams and
non-overlapping identity before a tip can become a dashboard adviser.
"""
import argparse
import json
import hashlib
import math
import re
import time
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
from pathlib import Path
from urllib.parse import urljoin, urlparse

import requests
from bs4 import BeautifulSoup

SOURCES = {
    "BETCLAN": (
        "https://www.betclan.com/todays-football-predictions/",
        "https://www.betclan.com/tomorrows-football-predictions/",
    ),
    "SPORTYTRADER": (
        "https://www.sportytrader.com/en/betting-tips/football/",
        "https://www.sportytrader.com/en/betting-tips/football/tomorrow/",
    ),
}
HOSTS = {"BETCLAN": "www.betclan.com", "SPORTYTRADER": "www.sportytrader.com"}
UA = "FastTracker-SourceAudit/1.0 (daily, bounded, no personal data)"
PERCENT = r"(\d{1,3}(?:\.\d+)?)\s*%"


def section(text, start, end):
    a = re.search(start, text, re.I)
    if not a:
        return ""
    s = text[a.end():]
    b = re.search(end, s, re.I)
    return s[:b.start()] if b else s[:1500]


def percentage(raw):
    if raw is None:
        return None
    n = float(raw)
    return round(n / 100, 6) if 0 <= n <= 100 else None


def valid_triplet(p):
    if not isinstance(p, dict) or any(type(p.get(x)) not in (int, float) or not math.isfinite(p[x]) or not 0 <= p[x] <= 1 for x in ("home", "draw", "away")):
        return None
    return p if abs(sum(p[x] for x in ("home", "draw", "away")) - 1) <= 0.025 else None



def betclan_utc_listing_evidence(html):
    """Capture independent, exact-url BetClan listing SportsEvent UTC evidence.

    BetClan can emit '17:00Z' in its listing but '17:00+01:00' in its
    detail while both human-facing clocks display 17:00. Never assume a
    universal timezone shift: require the listing's explicit UTC, same
    oriented team names, and matching displayed listing time. Contradictory
    duplicate source events are excluded, not selected arbitrarily.
    """
    soup = BeautifulSoup(html, "html.parser")
    found = {}
    for cell in soup.select("div.bclisttip"):
        anchor = cell.find("a", href=True)
        if anchor is None:
            continue
        url = urljoin(SOURCES["BETCLAN"][0], anchor["href"])
        parsed = urlparse(url)
        if (parsed.scheme != "https" or parsed.hostname != HOSTS["BETCLAN"]
            or parsed.query or parsed.fragment
            or not re.fullmatch(r"/predictionsdetails/football/\d+/[^/?#]+/", parsed.path)):
            continue
        clock_node = cell.select_one(".bctime .convert_date")
        home_node = cell.select_one(".bchome")
        away_node = cell.select_one(".bcaway")
        if not clock_node or not home_node or not away_node:
            continue
        clock = clock_node.get_text(" ", strip=True)
        oriented = (home_node.get_text(" ", strip=True), away_node.get_text(" ", strip=True))
        for script in cell.find_all("script", type="application/ld+json"):
            try:
                raw = script.string or ""
                try:
                    data = json.loads(raw)
                except json.JSONDecodeError as error:
                    # Observed 2026-11-08: BetClan listing emits exactly ONE
                    # extra closing brace AFTER a complete SportsEvent object.
                    # Recover ONLY that narrow syntax error, never arbitrary
                    # truncated/broken JSON or unexpected trailing content.
                    trimmed = raw.rstrip()
                    if (error.msg != "Extra data"
                        or error.pos != len(trimmed) - 1
                        or not trimmed.endswith("}")):
                        raise
                    data = json.loads(trimmed[:-1])
            except (ValueError, TypeError):
                continue
            for event in data if isinstance(data, list) else [data]:
                if not isinstance(event, dict) or event.get("@type") != "SportsEvent":
                    continue
                if (event.get("url") != url
                    or tuple(str(event.get(k, {}).get("name", "")).strip()
                             for k in ("homeTeam", "awayTeam")) != oriented):
                    continue
                start = event.get("startDate")
                if not isinstance(start, str) or not re.fullmatch(
                    r"20\d{2}-[01]\d-[0-3]\dT(?:[01]\d|2[0-3]):[0-5]\d:00Z", start
                ):
                    continue
                try:
                    start_utc = datetime.fromisoformat(start.replace("Z", "+00:00"))
                except ValueError:
                    continue
                if start_utc.strftime("%H:%M") != clock:
                    continue
                loc = event.get("location", {})
                league = loc.get("name") if isinstance(loc, dict) else None
                proof = {"startDate": start, "home": oriented[0], "away": oriented[1],
                         "competition": league}
                if url in found and found[url] != proof:
                    found[url] = None
                elif url not in found:
                    found[url] = proof
    return {url: evidence for url, evidence in found.items() if evidence is not None}


def parse_betclan(html, url, listing_evidence=None):
    soup = BeautifulSoup(html, "html.parser")
    h1 = soup.find("h1")
    if not h1:
        return None
    match = re.search(r"(.+?)\s+vs?\s+(.+?)\s+(?:Prediction|H2H)", h1.get_text(" ", strip=True), re.I)
    if not match:
        return None
    text = soup.get_text(" ", strip=True)
    dt = re.search(r"\bDate\s+(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})", text)
    if not dt:
        return None
    winner = section(text, r"\bWinner\b", r"\bTotal Goals\s*2\.5\b")
    probs = {
        key: percentage(re.search(r"\b" + key + r"\s*" + PERCENT, winner, re.I).group(1))
        if re.search(r"\b" + key + r"\s*" + PERCENT, winner, re.I) else None
        for key in ("Home", "Draw", "Away")
    }
    goal = section(text, r"\bTotal Goals\s*2\.5\b", r"\bBoth Teams to Score\b")
    btts = section(text, r"\bBoth Teams to Score\b", r"\bCorrect Score\b")
    # Navigation contains 'Correct Score Calculator' before the fixture date.
    # Only the actual market heading and its immediate value are evidence.
    heading = soup.find("h4", string=re.compile(r"^\s*Correct Score\s*$", re.I))
    value = heading.find_next_sibling() if heading else None
    score = re.fullmatch(r"(\d{1,2})\s*-\s*(\d{1,2})(?:\s+\d{1,3}%\s+Others\s+\d{1,3}%)?",
                         value.get_text(" ", strip=True) if value and value.name in ("h5", "p") else "")
    event = None
    for script in soup.find_all("script", type="application/ld+json"):
        try:
            obj = json.loads(script.string or "")
        except (ValueError, TypeError):
            continue
        for item in obj if isinstance(obj, list) else [obj]:
            if (isinstance(item, dict) and item.get("@type") == "SportsEvent"
                and item.get("url") == url
                and item.get("homeTeam", {}).get("name") == match.group(1).strip()
                and item.get("awayTeam", {}).get("name") == match.group(2).strip()):
                event = item
    kickoff = None
    if event and re.search(r"(?:Z|[+-]\d{2}:\d{2})$", str(event.get("startDate", ""))):
        try:
            at = datetime.fromisoformat(event["startDate"].replace("Z", "+00:00"))
            if at.strftime("%Y-%m-%d %H:%M") == f"{dt.group(1)} {dt.group(2)}":
                kickoff = at.isoformat()
        except ValueError:
            pass
    # Preserve the original detail-zone stamp for an audit. A listing stamp
    # may override it ONLY when both pages corroborate URL, oriented teams,
    # competition and visible date/time, and the listing carries explicit UTC.
    detail_kickoff = kickoff
    listing_kickoff = None
    clock_basis = "DETAIL_STRUCTURED_EVENT" if kickoff else "CLOCK_UNVERIFIED"
    clock_disagreement_minutes = None
    if isinstance(listing_evidence, dict) and event is not None:
        listing_stamp = listing_evidence.get("startDate")
        listing_competition = listing_evidence.get("competition")
        detail_competition = (event.get("organizer") or {}).get("name")
        if (isinstance(listing_stamp, str)
            and re.fullmatch(r"20\d{2}-[01]\d-[0-3]\dT(?:[01]\d|2[0-3]):[0-5]\d:00Z", listing_stamp)
            and listing_evidence.get("home") == match.group(1).strip()
            and listing_evidence.get("away") == match.group(2).strip()
            and (not listing_competition or listing_competition == detail_competition)):
            at = datetime.fromisoformat(listing_stamp.replace("Z", "+00:00"))
            if at.strftime("%Y-%m-%d %H:%M") == f"{dt.group(1)} {dt.group(2)}":
                listing_kickoff = listing_stamp
                if detail_kickoff:
                    detail_at = datetime.fromisoformat(detail_kickoff)
                    clock_disagreement_minutes = int(
                        (at - detail_at).total_seconds() / 60)
                # Only a documented one-hour discrepancy or a fully agreeing
                # clock may be reconciled. Any other conflict remains UNKNOWN.
                if clock_disagreement_minutes in (None, 0, -60, 60):
                    kickoff = at.isoformat()
                    clock_basis = ("LISTING_UTC_CONFIRMED_DETAIL_CLOCK_CONFLICT"
                                   if clock_disagreement_minutes in (-60, 60)
                                   else "LISTING_UTC_CORROBORATED")
                else:
                    kickoff = None
                    clock_basis = "LISTING_DETAIL_CLOCK_CONFLICT_UNRESOLVED"
    return {
        "source": "BETCLAN", "source_url": url,
        "source_event_id": re.search(r"/football/(\d+)/", url).group(1),
        "home": match.group(1).strip(), "away": match.group(2).strip(),
        "source_date": dt.group(1), "source_wall_time": dt.group(2),
        "kickoff_timezone_verified": kickoff is not None,
        "source_kickoff": kickoff,
        "source_timezone": kickoff[-6:] if kickoff else None,
        "source_competition": event.get("organizer", {}).get("name") if event else None,
        "source_event_status": event.get("eventStatus") if event else None,
        "raw_content_hash": hashlib.sha256(html.encode()).hexdigest(),
        "parser_version": "betclan-v3-listing-utc-crosscheck",
        "source_detail_kickoff": detail_kickoff,
        "source_listing_kickoff": listing_kickoff,
        "source_clock_basis": clock_basis,
        "source_clock_disagreement_minutes": clock_disagreement_minutes,
        "hda": valid_triplet({k.lower(): v for k, v in probs.items()}),
        "over25": percentage(re.search(r"\bOver\s*" + PERCENT, goal, re.I).group(1))
        if re.search(r"\bOver\s*" + PERCENT, goal, re.I) else None,
        "btts_yes": percentage(re.search(r"\bYes\s*" + PERCENT, btts, re.I).group(1))
        if re.search(r"\bYes\s*" + PERCENT, btts, re.I) else None,
        "predicted_score": f"{score.group(1)}-{score.group(2)}" if score else None,
        "canonical_event_id": None, "identity": "UNRESOLVED",
    }



def sportytrader_faq_utc(soup, home, away, source_date):
    """Use only fixture-specific dated FAQ UK/GMT/UTC time on the same tip URL.

    This proves nothing alone: a separately linked SportsEvent must corroborate
    the UTC instant, exact URL, oriented teams and league before verified kickoff.
    """
    try:
        d = datetime.strptime(source_date, "%Y-%m-%d")
    except (TypeError, ValueError):
        return None
    month = d.strftime("%B")
    month_short = d.strftime("%b")
    day = str(d.day)
    date_pattern = (r"\b(?:" + re.escape(month) + "|" + re.escape(month_short) +
                    r")\s+0?" + day + r"\b|\b0?" + day +
                    r"\s+(?:" + re.escape(month) + "|" + re.escape(month_short) + r")\b")
    proofs = []
    for script in soup.select('script[type="application/ld+json"]'):
        try:
            data = json.loads(script.get_text())
        except (TypeError, ValueError):
            continue
        for node in data if isinstance(data, list) else [data]:
            if not isinstance(node, dict) or node.get("@type") != "FAQPage":
                continue
            for item in node.get("mainEntity", []):
                if not isinstance(item, dict) or item.get("@type") != "Question":
                    continue
                question = str(item.get("name") or "")
                if ("when" not in question.casefold()
                    or home.casefold() not in question.casefold()
                    or away.casefold() not in question.casefold()):
                    continue
                ans = item.get("acceptedAnswer")
                if not isinstance(ans, dict) or not isinstance(ans.get("text"), str):
                    continue
                answer = BeautifulSoup(ans["text"], "html.parser").get_text(" ", strip=True)
                if len(answer) > 650 or not re.search(date_pattern, answer, re.I):
                    continue
                years = re.findall(r"\b20\d{2}\b", answer)
                if years and any(y != str(d.year) for y in years):
                    continue
                matches = re.findall(
                    r"\b([01]?\d|2[0-3]):([0-5]\d)\s*(GMT|UTC|UK\s+time)\b", answer, re.I)
                if len(matches) != 1:
                    continue
                hour, minute, label = matches[0]
                tz_label = re.sub(r"\s+", " ", label.strip()).upper()
                zone = timezone.utc if tz_label in ("GMT", "UTC") else ZoneInfo("Europe/London")
                local = datetime(d.year, d.month, d.day, int(hour), int(minute), tzinfo=zone)
                # Fall-back 01:xx UK time is ambiguous without a numeric offset.
                if local.utcoffset() != local.replace(fold=1).utcoffset():
                    continue
                proofs.append((local.astimezone(timezone.utc).isoformat(),
                               question[:160], answer[:500], tz_label))
    if len(proofs) != 1:
        return None
    instant, question, answer, label = proofs[0]
    return {"kickoff_utc": instant, "question": question,
            "answer": answer, "time_label": label}



def sportytrader_is_football_tip(soup):
    """Reject non-football tips leaked through football page recommendations.

    Inspect ONLY the tip's structured BreadcrumbList, not global navigation
    that links all sports. Explicit rugby/basketball/etc. reject; missing
    breadcrumb remains source-only, without guessed canonical fixture.
    """
    categories=set()
    saw=False
    for script in soup.select('script[type="application/ld+json"]'):
        raw=script.get_text()
        if "BreadcrumbList" not in raw:
            continue
        saw=True
        try:
            data=json.loads(raw)
        except (ValueError,TypeError):
            return False
        for node in data if isinstance(data,list) else [data]:
            if not isinstance(node,dict) or node.get("@type")!="BreadcrumbList":
                continue
            items=node.get("itemListElement",[])
            if not isinstance(items,list):
                return False
            for item in items:
                if not isinstance(item,dict):
                    return False
                url=item.get("item")
                if isinstance(url,dict):
                    url=url.get("@id") or url.get("url")
                if not isinstance(url,str):
                    continue
                parsed=urlparse(url)
                if parsed.scheme!="https" or parsed.hostname!=HOSTS["SPORTYTRADER"]:
                    return False
                # Category breadcrumb: /en/betting-tips/football/.
                # Last breadcrumb is the actual event /en/betting-tips/brighton-...-385770/,
                # NOT a sport. Exclude all event slugs with numeric provider IDs.
                found=re.fullmatch(r"/en/betting-tips/([^/]+)/",parsed.path)
                if found and not re.search(r"-[0-9]{5,12}$",found.group(1)):
                    categories.add(found.group(1).casefold())
    return categories=={"football"} if saw else True


def parse_sportytrader(html, url):
    soup = BeautifulSoup(html, "html.parser")
    if not sportytrader_is_football_tip(soup):
        return None
    h1 = soup.find("h1")
    if not h1:
        return None
    title = h1.get_text(" ", strip=True)
    pair = re.search(r"(.+?)\s+vs?\s+(.+?)\s+Prediction\b", title, re.I)
    if not pair:
        return None
    text = soup.get_text(" ", strip=True)
    dt = re.search(r"\b(\d{2})/(\d{2})/(\d{4})\s+(\d{2}:\d{2})\b", text)
    if not dt:
        return None
    pick = section(text, r"\bPrediction\s*:", r"(?:Prediction published|Bookmaker|New customers)")
    tip_label = soup.select_one('[data-trans="tips.our.tip"]')
    if tip_label is not None and tip_label.parent is not None:
        tip_node = tip_label.parent.select_one('p:not([data-trans])')
        if tip_node is not None:
            pick = tip_node.get_text(' ', strip=True)
    # Remove bookmaker decimal quote without corrupting a tip such as "Under 2.5 goals".
    pick = re.split(r"\s+New customers\b", pick, flags=re.I, maxsplit=1)[0].strip()
    pick = re.sub(r"\s+[1-9]\d{0,2}\.\d{2}$", "", pick).strip()[:90]
    # Parse genuine SportyTrader algorithm probabilities, not bookmaker odds.
    algorithm = section(text, r"Probabilities according to our algorithm", r"Prediction and Best Odds")
    h = re.search(r"probability of\s*" + PERCENT + r"\s+for a win of", algorithm, re.I)
    d = re.search(r"for a draw\b.{0,160}?\bis\s*" + PERCENT, algorithm, re.I)
    a = re.search(r"(?:model gives|model estimates)\s+(?:a\s+)?" + PERCENT + r"\s+chance.{0,100}?for a win of", algorithm, re.I)
    hda = valid_triplet({
        "home": percentage(h.group(1)) if h else None,
        "draw": percentage(d.group(1)) if d else None,
        "away": percentage(a.group(1)) if a else None,
    })
    source_date = f"{dt.group(3)}-{dt.group(2)}-{dt.group(1)}"
    faq = sportytrader_faq_utc(soup, pair.group(1).strip(), pair.group(2).strip(), source_date)
    return {
        "source": "SPORTYTRADER", "source_url": url,
        "source_event_id": re.search(r"-(\d+)/?$", url).group(1),
        "home": pair.group(1).strip(), "away": pair.group(2).strip(),
        "source_date": source_date,
        "source_wall_time": dt.group(4), "kickoff_timezone_verified": False,
        "source_faq_kickoff_utc": faq["kickoff_utc"] if faq else None,
        "source_faq_evidence": faq,
        "source_competition": (re.split(r'Prediction\s*&\s*Betting Tips\s*-\s*', title, flags=re.I)[1].strip()
                               if re.search(r'Prediction\s*&\s*Betting Tips\s*-\s*', title, re.I) else None),
        # A written tip is not a probability triplet; never invent 1X2 from odds.
        "tip": pick or None, "hda": hda, "canonical_event_id": None,
        "identity": "UNRESOLVED",
    }


def enrich_sportytrader_event(row, html, url):
    """Require the directly linked event's oriented teams and local clock to agree."""
    if not re.fullmatch(r'https://www\.sportytrader\.com/en/results-live/[^/?#]+-\d+/', url):
        return row
    events = []
    for script in BeautifulSoup(html, 'html.parser').select('script[type="application/ld+json"]'):
        try:
            data = json.loads(script.get_text())
        except (ValueError, TypeError):
            continue
        nodes = data if isinstance(data, list) else [data]
        events.extend(x for x in nodes if isinstance(x, dict) and x.get('@type') == 'SportsEvent')
    valid = []
    for event in events:
        try:
            kickoff = event['startDate']
            if not isinstance(kickoff, str) or not re.search(r'(Z|[+-]\d{2}:\d{2})$', kickoff):
                continue
            at = datetime.fromisoformat(kickoff.replace('Z', '+00:00'))
            faq_utc = row.get('source_faq_kickoff_utc')
            wall_agrees = at.strftime('%H:%M') == row['source_wall_time']
            faq_agrees = isinstance(faq_utc, str) and at.astimezone(timezone.utc).isoformat() == faq_utc
            if (event.get('url') != url or at.strftime('%Y-%m-%d') != row['source_date']
                or (not wall_agrees and not faq_agrees)
                or (faq_utc is not None and not faq_agrees)):
                continue
            if any(event.get(side+'Team', {}).get('name', '').strip().casefold() != row[side].strip().casefold() for side in ('home', 'away')):
                continue
            competition = event.get('organizer', {}).get('name')
            if not competition or (row.get('source_competition') and competition.casefold() != row['source_competition'].casefold()):
                continue
            valid.append((kickoff, competition, event))
        except (ValueError, TypeError, KeyError, AttributeError):
            continue
    if len(valid) != 1:
        return row
    kickoff, competition, event = valid[0]
    return {**row, 'source_kickoff': kickoff, 'source_timezone': kickoff[-6:] if not kickoff.endswith('Z') else 'UTC',
            'source_competition': competition, 'kickoff_timezone_verified': True,
            'source_event_status': event.get('eventStatus'), 'related_event_evidence': event,
            'source_clock_basis': ('FAQ_GMT_AND_LINKED_SPORTSEVENT' if row.get('source_faq_kickoff_utc') else 'WALL_CLOCK_AND_LINKED_SPORTSEVENT'),
            'parser_version': 'sportytrader-v2-linked-sportsevent'}


def candidate_urls(html, source):
    soup = BeautifulSoup(html, "html.parser")
    found = set()
    for anchor in soup.find_all("a", href=True):
        url = urljoin(SOURCES[source][0], anchor["href"])
        parsed = urlparse(url)
        if parsed.scheme != "https" or parsed.hostname != HOSTS[source]:
            continue
        if source == "BETCLAN" and not re.search(r"/predictionsdetails/football/\d+/", parsed.path):
            continue
        if source == "SPORTYTRADER" and not re.fullmatch(r"/en/betting-tips/[^/]+-\d+/", parsed.path):
            continue
        found.add(parsed._replace(query="", fragment="").geturl())
    return sorted(found)


def fetch(session, url):
    response = session.get(url, timeout=(5, 12), headers={"User-Agent": UA})
    response.raise_for_status()
    if urlparse(response.url).hostname != urlparse(url).hostname:
        raise RuntimeError("provider_redirected_to_another_host")
    if len(response.content) > 2_000_000:
        raise RuntimeError("page_too_large")
    return response.text


def replay_saved_evidence(report, evidence_dir):
    """Reparse saved bytes without changing their capture time or making requests."""
    records = []
    for old in report['records']:
        if old.get('source') != 'SPORTYTRADER':
            records.append(old)
            continue
        digest = old.get('raw_content_hash', '')
        if not re.fullmatch(r'[a-f0-9]{64}', digest):
            records.append(old)
            continue
        path = Path(evidence_dir) / 'sportytrader' / (digest+'.html')
        if not path.exists():
            records.append(old)
            continue
        html = path.read_text(encoding='utf-8')
        if hashlib.sha256(html.encode()).hexdigest() != digest:
            raise ValueError('source_evidence_hash_mismatch')
        row = parse_sportytrader(html, old['source_url'])
        if row is None or row['source_event_id'] != old['source_event_id']:
            raise ValueError('source_evidence_identity_mismatch')
        related_hash = old.get('related_content_hash', '')
        related_url = old.get('related_source_url', '')
        links = {urljoin(old['source_url'], a['href']) for a in BeautifulSoup(html, 'html.parser').find_all('a', href=True)}
        if re.fullmatch(r'[a-f0-9]{64}', related_hash) and related_url in links:
            related_path = Path(evidence_dir) / 'sportytrader-related' / (related_hash+'.html')
            related_html = related_path.read_text(encoding='utf-8')
            if hashlib.sha256(related_html.encode()).hexdigest() != related_hash:
                raise ValueError('related_evidence_hash_mismatch')
            row = enrich_sportytrader_event(row, related_html, related_url)
            row.update(related_content_hash=related_hash, related_source_url=related_url)
        row.update(captured_at=old['captured_at'], raw_content_hash=digest)
        records.append(row)
    return {**report, 'records': records}


# Related SportsEvent page fetches are limited to 16 daily. Sort *after*
# collecting all allowed tip details, so alphabetical URL order cannot spend
# the evidence budget on arbitrary early URLs. Priority only controls WHICH
# source proof to read; it never certifies identity or guesses timezones.
MAJOR_LEAGUES = (
    "premier league", "champions league", "laliga", "serie a", "bundesliga",
    "ligue 1", "championship", "europa league", "eredivisie",
    "primeira liga", "major league soccer", "mls",
)

def sportytrader_related_priority(row, capture_date):
    league = str(row.get("source_competition") or "").strip().casefold()
    source_date = str(row.get("source_date") or "")
    # Prefer today/tomorrow, then established league importance, then genuine
    # complete source model probability, finally deterministic provider ID.
    date_rank = 0 if source_date == capture_date else 1 if source_date > capture_date else 2
    league_rank = next((i for i, name in enumerate(MAJOR_LEAGUES)
                        if league == name or league.endswith(" - " + name)), len(MAJOR_LEAGUES))
    model_rank = 0 if valid_triplet(row.get("hda")) else 1
    return (date_rank, league_rank, model_rank, str(row.get("source_event_id") or ""))


def collect(limit=100, pause=0.4, session=None, source=None, evidence_dir=None, related_evidence_limit=0):
    if source is not None and source not in SOURCES:
        raise ValueError("unknown_source")
    if not 1 <= limit <= 120:
        raise ValueError("invalid_source_limit")
    if not 0 <= related_evidence_limit <= 16 or (related_evidence_limit and evidence_dir is None):
        raise ValueError("invalid_related_evidence_limit")
    selected_source = source
    related_attempts = 0
    related_candidates = []
    session = session or requests.Session()
    output = {"generated_at": datetime.now(timezone.utc).isoformat(),
              "contract": "source_observations_only_v1", "providers": {}, "records": []}
    for source, listings in SOURCES.items():
        if selected_source is not None and source != selected_source:
            continue
        diag = {"listings_ok": 0, "candidate_urls": 0, "parsed": 0, "failed": 0,
                "status": "UNAVAILABLE"}
        urls = set()
        listing_clocks = {}
        for url in listings:
            try:
                listing_html = fetch(session, url)
                urls.update(candidate_urls(listing_html, source))
                if source == "BETCLAN":
                    for match_url, proof in betclan_utc_listing_evidence(listing_html).items():
                        if match_url in listing_clocks and listing_clocks[match_url] != proof:
                            listing_clocks[match_url] = None
                        elif match_url not in listing_clocks:
                            listing_clocks[match_url] = proof
                diag["listings_ok"] += 1
            except (requests.RequestException, RuntimeError) as exc:
                diag["last_error"] = type(exc).__name__
            time.sleep(pause)
        diag["candidate_urls"] = len(urls)
        for url in sorted(urls)[:limit]:
            try:
                html = fetch(session, url)
                evidence_hash = hashlib.sha256(html.encode("utf-8")).hexdigest()
                if evidence_dir is not None:
                    evidence_path = Path(evidence_dir) / source.lower() / (evidence_hash + ".html")
                    evidence_path.parent.mkdir(parents=True, exist_ok=True)
                    evidence_path.write_text(html, encoding="utf-8")
                parsed = (parse_betclan(html, url, listing_clocks.get(url))
                          if source == "BETCLAN" else parse_sportytrader(html, url))
                if parsed is None:
                    if source == "SPORTYTRADER" and not sportytrader_is_football_tip(
                        BeautifulSoup(html, "html.parser")
                    ):
                        diag["nonfootball_rejected"] = diag.get("nonfootball_rejected", 0) + 1
                    raise ValueError("invalid_source_detail_structure")
                parsed["captured_at"] = output["generated_at"]
                parsed["raw_content_hash"] = evidence_hash
                if source == "SPORTYTRADER" and related_evidence_limit:
                    # Collect links already present in this fetched tip HTML.
                    # Keep the same max-8 related HTTP budget; only improve
                    # deterministic selection of which URLs merit proof.
                    related = sorted({
                        urljoin(url, a['href']) for a in
                        BeautifulSoup(html, "html.parser").find_all('a', href=True)
                        if re.fullmatch(r'/en/results-live/[^/]+-\d+/', a['href'])
                    })
                    if len(related) == 1:
                        related_candidates.append((parsed, related[0]))
                output["records"].append(parsed)
                diag["parsed"] += 1
            except (requests.RequestException, RuntimeError, ValueError, AttributeError) as exc:
                diag["failed"] += 1
                diag["last_error"] = type(exc).__name__
            time.sleep(pause)
        if source == "BETCLAN":
            diag["listing_utc_proofs"] = sum(p is not None for p in listing_clocks.values())
            diag["clock_proof_status"] = ("PROOFS_UNAVAILABLE"
                if diag["candidate_urls"] >= 20 and diag["listing_utc_proofs"] == 0
                else "PROOFS_PRESENT" if diag["listing_utc_proofs"] > 0
                else "NO_LISTING_TARGETS")
            diag["clock_conflicts_resolved"] = sum(
                r.get("source") == "BETCLAN" and
                r.get("source_clock_basis") == "LISTING_UTC_CONFIRMED_DETAIL_CLOCK_CONFLICT"
                for r in output["records"])
        diag["status"] = ("CAPTURED_UNMATCHED" if diag["parsed"] else
                          "PARSE_FAILED" if diag["candidate_urls"] else "SOURCE_UNAVAILABLE")
        output["providers"][source] = diag
    if related_evidence_limit and related_candidates:
        sporty_diag = output["providers"].get("SPORTYTRADER", {})
        capture_date = output["generated_at"][:10]
        sporty_diag["related_candidates"] = len(related_candidates)
        seen_links = set()
        for row, related in sorted(
            related_candidates,
            key=lambda p: sportytrader_related_priority(p[0], capture_date)
        ):
            # Never spend two proof requests on the same linked event.
            if related in seen_links:
                continue
            seen_links.add(related)
            if related_attempts >= related_evidence_limit:
                break
            related_attempts += 1
            try:
                related_html = fetch(session, related)
                related_hash = hashlib.sha256(related_html.encode("utf-8")).hexdigest()
                related_path = Path(evidence_dir) / "sportytrader-related" / (related_hash + ".html")
                related_path.parent.mkdir(parents=True, exist_ok=True)
                related_path.write_text(related_html, encoding="utf-8")
                updated = enrich_sportytrader_event(row, related_html, related)
                # This mutates ONLY the original in-memory row already in
                # output["records"]; no second observation or duplicate ID.
                row.update(updated)
                row.update(related_source_url=related, related_content_hash=related_hash)
                if row.get("kickoff_timezone_verified") is True:
                    sporty_diag["related_verified_kickoff"] = sporty_diag.get("related_verified_kickoff", 0) + 1
                else:
                    sporty_diag["related_unverified"] = sporty_diag.get("related_unverified", 0) + 1
            except (requests.RequestException, RuntimeError, OSError):
                sporty_diag["related_failed"] = sporty_diag.get("related_failed", 0) + 1
            time.sleep(pause)
        sporty_diag["related_attempted"] = related_attempts
        sporty_diag["related_budget"] = related_evidence_limit
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--source", choices=tuple(SOURCES))
    parser.add_argument("--evidence-dir", type=Path)
    parser.add_argument("--related-evidence-limit", type=int, default=0, choices=range(17))
    parser.add_argument("--replay-input", type=Path)
    args = parser.parse_args()
    if not 1 <= args.limit <= 120:
        parser.error("limit must be 1..120 per source")
    if args.replay_input:
        if args.evidence_dir is None:
            parser.error('--replay-input requires --evidence-dir')
        report = replay_saved_evidence(json.loads(args.replay_input.read_text()), args.evidence_dir)
    else:
        report = collect(limit=args.limit, source=args.source, evidence_dir=args.evidence_dir,
                         related_evidence_limit=args.related_evidence_limit)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"providers": report["providers"], "total": len(report["records"]) }))
    if report["providers"].get("BETCLAN", {}).get("clock_proof_status") == "PROOFS_UNAVAILABLE":
        print("::warning::BETCLAN_LISTING_UTC_PROOFS_MISSING: "
              "source HTML contained 20+ links but zero corroborated UTC events; "
              "do not assume listing/detail clocks are verified.")
    if not report["records"]:
        raise SystemExit("capture failed: no source-backed adviser records; no ingestion")
