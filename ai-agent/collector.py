"""
Traffic Collector — polls Orthanc and traffic-events.json to build a traffic profile.

Runs on a background thread, collecting:
1. Traffic events from the Lua-written traffic-events.json
2. Routing log entries to correlate which studies were routed
"""

import json
import os
import time
import threading
import logging
import requests
from datetime import datetime, timezone, timedelta

import config
from models import get_db, get_state, set_state, now_iso

logger = logging.getLogger("collector")


class TrafficCollector:
    def __init__(self):
        self._running = False
        self._thread = None

    def start(self):
        """Start the collector background thread."""
        if self._running:
            return
        self._running = True
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()
        logger.info("Traffic collector started (poll every %ds)", config.POLL_INTERVAL_SECONDS)

    def stop(self):
        self._running = False

    def _loop(self):
        # Initial delay to let Orthanc start
        time.sleep(5)
        while self._running:
            try:
                self._collect()
            except Exception as e:
                logger.error("Collection error: %s", e)
            time.sleep(config.POLL_INTERVAL_SECONDS)

    def _collect(self):
        """Run one collection cycle."""
        self._collect_traffic_events()
        self._collect_routing_log()

    # ── Traffic Events (from Lua-written JSON) ──

    def _collect_traffic_events(self):
        """Read traffic-events.json written by autoforward.lua."""
        path = config.TRAFFIC_EVENTS_PATH
        if not os.path.exists(path):
            return

        try:
            with open(path, "r") as f:
                content = f.read().strip()
            if not content:
                return
            events = json.loads(content)
        except (json.JSONDecodeError, IOError) as e:
            logger.warning("Could not read traffic events: %s", e)
            return

        if not isinstance(events, list) or len(events) == 0:
            return

        db = get_db()
        last_seen = get_state(db, "last_traffic_event_time", "")
        new_count = 0

        for evt in events:
            evt_time = evt.get("time", "")
            if evt_time <= last_seen:
                continue

            # Check if we already recorded this study UID recently
            study_uid = evt.get("studyUid", "")
            if study_uid:
                existing = db.execute(
                    "SELECT id FROM traffic_events WHERE study_uid = ? AND timestamp = ?",
                    (study_uid, evt_time),
                ).fetchone()
                if existing:
                    continue

            db.execute(
                """INSERT INTO traffic_events
                   (timestamp, study_uid, patient_name, patient_id, modality,
                    study_description, calling_aet, called_aet, num_series,
                    num_instances, routed)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)""",
                (
                    evt_time,
                    study_uid,
                    evt.get("patientName", ""),
                    evt.get("patientId", ""),
                    evt.get("modality", ""),
                    evt.get("studyDescription", ""),
                    evt.get("callingAet", ""),
                    evt.get("calledAet", ""),
                    evt.get("numSeries", 0),
                    evt.get("numInstances", 0),
                ),
            )
            new_count += 1
            if evt_time > last_seen:
                last_seen = evt_time

        if new_count > 0:
            set_state(db, "last_traffic_event_time", last_seen)
            db.commit()
            logger.info("Collected %d new traffic events", new_count)
        db.close()

    # ── Routing Log (correlate routed studies) ──

    def _collect_routing_log(self):
        """Read routing-log.json to mark which studies were routed."""
        path = config.ROUTING_LOG_PATH
        if not os.path.exists(path):
            return

        try:
            with open(path, "r") as f:
                content = f.read().strip()
            if not content:
                return
            entries = json.loads(content)
        except (json.JSONDecodeError, IOError) as e:
            logger.warning("Could not read routing log: %s", e)
            return

        if not isinstance(entries, list):
            return

        db = get_db()
        last_processed = get_state(db, "last_routing_log_time", "")

        for entry in entries:
            entry_time = entry.get("time", "")
            if entry_time <= last_processed:
                continue

            status = entry.get("status", "sent")
            if status != "sent":
                continue

            study_id = entry.get("study", "")
            rule_name = entry.get("rule", "")
            dest = entry.get("dest", "")
            description = entry.get("description", "")
            modality = entry.get("modality", "")

            # Try to match by description + modality + time proximity
            # since traffic events use studyUid and routing log uses study ID
            db.execute(
                """UPDATE traffic_events
                   SET routed = 1, route_rule = ?, route_dest = ?
                   WHERE routed = 0
                     AND timestamp >= datetime(?, '-5 minutes')
                     AND timestamp <= datetime(?, '+5 minutes')
                     AND (study_description = ? OR modality = ?)
                   LIMIT 1""",
                (rule_name, dest, entry_time, entry_time, description, modality),
            )

            if entry_time > last_processed:
                last_processed = entry_time

        if last_processed:
            set_state(db, "last_routing_log_time", last_processed)
        db.commit()
        db.close()

    # ── Manual collection trigger ──

    def collect_now(self):
        """Run a collection cycle immediately (for API calls)."""
        try:
            self._collect()
            return True
        except Exception as e:
            logger.error("Manual collection error: %s", e)
            return False
