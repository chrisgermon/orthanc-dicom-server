"""
Rule Suggester — analyzes traffic data to generate intelligent routing suggestions.

Detects:
1. Unrouted traffic patterns (studies arriving that no rule matches)
2. Stale rules (rules that haven't matched recently)
3. High-failure destinations
4. Optimization opportunities (overlapping rules, consolidation)

Each suggestion includes a plain English description and pre-built rule JSON.
"""

import json
import os
import logging
from collections import Counter, defaultdict
from datetime import datetime, timezone, timedelta

import config
from models import get_db, now_iso

logger = logging.getLogger("suggester")


class RuleSuggester:
    def __init__(self):
        self._modalities_cache = None
        self._modalities_cache_time = None

    def generate_suggestions(self):
        """Analyze traffic and generate all suggestions."""
        db = get_db()
        suggestions = []

        try:
            suggestions.extend(self._detect_unrouted_patterns(db))
            suggestions.extend(self._detect_stale_rules(db))
            suggestions.extend(self._detect_high_failure_routes(db))
            suggestions.extend(self._detect_optimization_opportunities(db))
        except Exception as e:
            logger.error("Suggestion generation error: %s", e)
        finally:
            db.close()

        return suggestions

    def run_and_save(self):
        """Generate suggestions and save new ones to the database."""
        suggestions = self.generate_suggestions()
        if not suggestions:
            return 0

        db = get_db()
        new_count = 0

        for s in suggestions:
            # Check if a similar suggestion already exists (by title)
            existing = db.execute(
                "SELECT id FROM suggestions WHERE title = ? AND status = 'pending'",
                (s["title"],),
            ).fetchone()
            if existing:
                continue

            db.execute(
                """INSERT INTO suggestions
                   (created_at, category, title, description, confidence, rule_json, status)
                   VALUES (?, ?, ?, ?, ?, ?, 'pending')""",
                (
                    now_iso(),
                    s["category"],
                    s["title"],
                    s["description"],
                    s["confidence"],
                    json.dumps(s["rule_json"]) if s.get("rule_json") else None,
                ),
            )
            new_count += 1

        db.commit()
        db.close()

        if new_count > 0:
            logger.info("Generated %d new suggestions", new_count)
        return new_count

    # ── Detection: Unrouted Traffic ──

    def _detect_unrouted_patterns(self, db):
        """Find repeating patterns of studies that aren't being routed."""
        suggestions = []

        # Look at unrouted studies from the last 7 days
        cutoff = (datetime.now(timezone.utc) - timedelta(days=7)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )

        rows = db.execute(
            """SELECT modality, study_description, calling_aet, called_aet,
                      COUNT(*) as cnt
               FROM traffic_events
               WHERE routed = 0 AND timestamp >= ?
               GROUP BY modality, study_description, calling_aet
               HAVING cnt >= ?
               ORDER BY cnt DESC
               LIMIT 20""",
            (cutoff, config.MIN_UNROUTED_COUNT),
        ).fetchall()

        # Get available destinations for rule suggestions
        destinations = self._get_available_destinations()

        for row in rows:
            modality = row["modality"] or "Unknown"
            desc = row["study_description"] or ""
            aet = row["calling_aet"] or ""
            count = row["cnt"]

            # Build human-readable description
            source_part = f" from **{aet}**" if aet else ""
            desc_part = f' with description matching "*{desc}*"' if desc else ""

            title = f"Unrouted {modality} studies{source_part}"
            description = (
                f"**{count} {modality} studies**{source_part}{desc_part} "
                f"arrived in the last 7 days but were not routed to any destination.\n\n"
                f"Consider creating a routing rule to forward these studies."
            )

            # Build a suggested rule
            rule_json = {
                "name": f"Route {modality}" + (f" from {aet}" if aet else ""),
                "enabled": True,
                "type": "push",
                "destination": destinations[0] if destinations else "",
                "source": "",
                "pollIntervalMinutes": 0,
                "sendLevel": "study",
                "filterModality": modality if modality != "Unknown" else "",
                "filterStudyDescription": f"*{desc}*" if desc else "",
                "filterSeriesDescription": "",
                "filterCallingAet": aet,
                "filterCalledAet": "",
                "filterDateRange": "",
                "deleteAfterSend": False,
            }

            # Confidence based on count
            confidence = min(95, 50 + count * 5)

            suggestions.append(
                {
                    "category": "unrouted",
                    "title": title,
                    "description": description,
                    "confidence": confidence,
                    "rule_json": rule_json,
                }
            )

        return suggestions

    # ── Detection: Stale Rules ──

    def _detect_stale_rules(self, db):
        """Find routing rules that haven't matched anything recently."""
        suggestions = []
        rules = self._load_current_rules()
        if not rules:
            return suggestions

        cutoff = (
            datetime.now(timezone.utc) - timedelta(days=config.STALE_RULE_DAYS)
        ).strftime("%Y-%m-%dT%H:%M:%SZ")

        # Get rules that have been active (routed) recently
        active_rules = set()
        rows = db.execute(
            """SELECT DISTINCT route_rule FROM traffic_events
               WHERE routed = 1 AND route_rule IS NOT NULL AND timestamp >= ?""",
            (cutoff,),
        ).fetchall()
        for row in rows:
            active_rules.add(row["route_rule"])

        # Also check routing log file directly for more complete data
        log_rules = self._get_recent_log_rules(cutoff)
        active_rules.update(log_rules)

        for rule in rules:
            name = rule.get("name", "")
            if not name or not rule.get("enabled", False):
                continue
            if name not in active_rules:
                suggestions.append(
                    {
                        "category": "stale",
                        "title": f'Rule "{name}" may be stale',
                        "description": (
                            f'The routing rule **"{name}"** is enabled but has not matched '
                            f"any studies in the last **{config.STALE_RULE_DAYS} days**.\n\n"
                            f"Consider disabling it to keep your rules list clean, or verify "
                            f"the filter criteria are still correct."
                        ),
                        "confidence": 60,
                        "rule_json": None,
                    }
                )

        return suggestions

    # ── Detection: High Failure Routes ──

    def _detect_high_failure_routes(self, db):
        """Find destinations with high failure rates."""
        suggestions = []

        log_path = config.ROUTING_LOG_PATH
        if not os.path.exists(log_path):
            return suggestions

        try:
            with open(log_path, "r") as f:
                entries = json.loads(f.read().strip() or "[]")
        except (json.JSONDecodeError, IOError):
            return suggestions

        # Count sent vs failed per destination in last 7 days
        cutoff = (datetime.now(timezone.utc) - timedelta(days=7)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        dest_stats = defaultdict(lambda: {"sent": 0, "failed": 0, "errors": []})

        for entry in entries:
            if entry.get("time", "") < cutoff:
                continue
            dest = entry.get("dest", "")
            if not dest:
                continue
            status = entry.get("status", "sent")
            if status == "sent":
                dest_stats[dest]["sent"] += 1
            elif status == "failed":
                dest_stats[dest]["failed"] += 1
                error = entry.get("error", "")
                if error and error not in dest_stats[dest]["errors"]:
                    dest_stats[dest]["errors"].append(error)

        for dest, stats in dest_stats.items():
            total = stats["sent"] + stats["failed"]
            if total < 3:
                continue
            failure_rate = stats["failed"] / total
            if failure_rate >= config.HIGH_FAILURE_THRESHOLD:
                pct = int(failure_rate * 100)
                error_hint = ""
                if stats["errors"]:
                    error_hint = (
                        f'\n\nRecent error: *"{stats["errors"][-1][:200]}"*'
                    )

                suggestions.append(
                    {
                        "category": "failure",
                        "title": f"High failure rate to {dest}",
                        "description": (
                            f"Destination **{dest}** has a **{pct}% failure rate** "
                            f"({stats['failed']} failures out of {total} attempts) "
                            f"in the last 7 days.{error_hint}\n\n"
                            f"Check network connectivity, AE title configuration, "
                            f"or whether the destination is online."
                        ),
                        "confidence": min(95, 60 + pct // 2),
                        "rule_json": None,
                    }
                )

        return suggestions

    # ── Detection: Optimization Opportunities ──

    def _detect_optimization_opportunities(self, db):
        """Find overlapping or consolidatable rules."""
        suggestions = []
        rules = self._load_current_rules()
        if len(rules) < 2:
            return suggestions

        # Detect rules with identical filters going to same destination
        seen = defaultdict(list)
        for rule in rules:
            if not rule.get("enabled", False):
                continue
            key = (
                rule.get("destination", ""),
                rule.get("filterModality", ""),
                rule.get("filterCallingAet", ""),
                rule.get("type", "push"),
            )
            seen[key].append(rule.get("name", "?"))

        for key, names in seen.items():
            if len(names) >= 2:
                dest, modality, aet, rtype = key
                suggestions.append(
                    {
                        "category": "optimize",
                        "title": f"Possible duplicate rules: {', '.join(names[:3])}",
                        "description": (
                            f"Rules **{', '.join(names)}** share the same destination "
                            f"(**{dest}**), modality filter (**{modality or 'any'}**), "
                            f"and source AET (**{aet or 'any'}**).\n\n"
                            f"Consider consolidating them into a single rule."
                        ),
                        "confidence": 70,
                        "rule_json": None,
                    }
                )

        return suggestions

    # ── Helpers ──

    def _load_current_rules(self):
        """Load current routing rules from file."""
        path = config.ROUTING_RULES_PATH
        if not os.path.exists(path):
            return []
        try:
            with open(path, "r") as f:
                return json.loads(f.read().strip() or "[]")
        except (json.JSONDecodeError, IOError):
            return []

    def _get_recent_log_rules(self, cutoff):
        """Get rule names from routing log after cutoff time."""
        path = config.ROUTING_LOG_PATH
        if not os.path.exists(path):
            return set()
        try:
            with open(path, "r") as f:
                entries = json.loads(f.read().strip() or "[]")
        except (json.JSONDecodeError, IOError):
            return set()

        rules = set()
        for entry in entries:
            if entry.get("time", "") >= cutoff and entry.get("status") == "sent":
                rule = entry.get("rule", "")
                if rule:
                    rules.add(rule)
        return rules

    def _get_available_destinations(self):
        """Get list of known DICOM modality names (destinations)."""
        rules = self._load_current_rules()
        destinations = set()
        for r in rules:
            dest = r.get("destination", "")
            if dest:
                destinations.add(dest)
        return sorted(destinations)

    # ── Rule Explainer ──

    def explain_rules(self):
        """Generate plain English explanations of all current rules."""
        rules = self._load_current_rules()
        if not rules:
            return []

        # Get recent match counts from routing log
        match_counts = self._get_rule_match_counts()

        explanations = []
        for rule in rules:
            explanations.append(self._explain_single_rule(rule, match_counts))
        return explanations

    def _explain_single_rule(self, rule, match_counts):
        """Generate a plain English explanation for a single rule."""
        name = rule.get("name", "Unnamed")
        rule_type = rule.get("type", "push")
        dest = rule.get("destination", "?")
        source = rule.get("source", "")
        send_level = rule.get("sendLevel", "study")
        enabled = rule.get("enabled", False)

        # Build the condition parts
        conditions = []

        modality = rule.get("filterModality", "")
        if modality:
            if modality.startswith("!"):
                conditions.append(f"the modality is NOT **{modality[1:]}**")
            else:
                conditions.append(f"the modality is **{modality}**")

        study_desc = rule.get("filterStudyDescription", "") or rule.get(
            "filterDescription", ""
        )
        if study_desc:
            if study_desc.startswith("!"):
                conditions.append(
                    f'the study description does NOT match "{study_desc[1:]}"'
                )
            else:
                conditions.append(
                    f'the study description matches "{study_desc}"'
                )

        series_desc = rule.get("filterSeriesDescription", "")
        if series_desc:
            if series_desc.startswith("!"):
                conditions.append(
                    f'the series description does NOT match "{series_desc[1:]}"'
                )
            else:
                conditions.append(
                    f'the series description matches "{series_desc}"'
                )

        calling_aet = rule.get("filterCallingAet", "")
        if calling_aet:
            if calling_aet.startswith("!"):
                conditions.append(f"the sending scanner is NOT **{calling_aet[1:]}**")
            else:
                conditions.append(f"the sending scanner is **{calling_aet}**")

        called_aet = rule.get("filterCalledAet", "")
        if called_aet:
            conditions.append(f"it was sent to AE title **{called_aet}**")

        date_range = rule.get("filterDateRange", "")
        date_labels = {
            "today": "today",
            "yesterday": "since yesterday",
            "7days": "in the last 7 days",
            "30days": "in the last 30 days",
            "90days": "in the last 90 days",
        }
        if date_range and date_range in date_labels:
            conditions.append(f"the study date is {date_labels[date_range]}")

        # Compose the sentence
        if rule_type == "push":
            trigger = "When a study arrives and becomes stable"
        else:
            interval = rule.get("pollIntervalMinutes", 5)
            trigger = f"Every **{interval} minutes**, query **{source}**"

        condition_text = (
            " where " + ", and ".join(conditions) if conditions else ""
        )
        level_text = "each matching series" if send_level == "series" else "the entire study"
        action = f"forward {level_text} to **{dest}**"

        delete_text = ""
        if rule.get("deleteAfterSend"):
            delete_text = ", then **delete the local copy**"

        explanation = f"{trigger}{condition_text}, {action}{delete_text}."

        # Match stats
        counts = match_counts.get(name, {"24h": 0, "7d": 0})

        return {
            "name": name,
            "enabled": enabled,
            "type": rule_type,
            "explanation": explanation,
            "matches_24h": counts["24h"],
            "matches_7d": counts["7d"],
        }

    def _get_rule_match_counts(self):
        """Get match counts per rule from routing log."""
        path = config.ROUTING_LOG_PATH
        if not os.path.exists(path):
            return {}

        try:
            with open(path, "r") as f:
                entries = json.loads(f.read().strip() or "[]")
        except (json.JSONDecodeError, IOError):
            return {}

        now = datetime.now(timezone.utc)
        cutoff_24h = (now - timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%SZ")
        cutoff_7d = (now - timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ")

        counts = defaultdict(lambda: {"24h": 0, "7d": 0})

        for entry in entries:
            rule = entry.get("rule", "")
            if not rule:
                continue
            t = entry.get("time", "")
            status = entry.get("status", "sent")
            if status != "sent":
                continue
            if t >= cutoff_24h:
                counts[rule]["24h"] += 1
            if t >= cutoff_7d:
                counts[rule]["7d"] += 1

        return dict(counts)
