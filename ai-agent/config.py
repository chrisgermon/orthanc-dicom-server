"""Configuration for the AI DICOM Routing Agent."""

import os

# Orthanc connection
ORTHANC_URL = os.getenv("ORTHANC_URL", "http://orthanc:8042")
ORTHANC_USER = os.getenv("ORTHANC_USER", "")
ORTHANC_PASS = os.getenv("ORTHANC_PASS", "")

# Data paths
DATA_DIR = os.getenv("DATA_DIR", "/data")
DB_PATH = os.path.join(DATA_DIR, "traffic.db")
TRAFFIC_EVENTS_PATH = os.getenv(
    "TRAFFIC_EVENTS_PATH", "/orthanc-data/traffic-events.json"
)
ROUTING_LOG_PATH = os.getenv(
    "ROUTING_LOG_PATH", "/orthanc-data/routing-log.json"
)
ROUTING_RULES_PATH = os.getenv(
    "ROUTING_RULES_PATH", "/orthanc-data/routing-rules.json"
)

# Collector settings
POLL_INTERVAL_SECONDS = int(os.getenv("POLL_INTERVAL_SECONDS", "60"))
CHANGES_BATCH_SIZE = int(os.getenv("CHANGES_BATCH_SIZE", "100"))

# Suggester settings
STALE_RULE_DAYS = int(os.getenv("STALE_RULE_DAYS", "7"))
MIN_UNROUTED_COUNT = int(os.getenv("MIN_UNROUTED_COUNT", "3"))
HIGH_FAILURE_THRESHOLD = float(os.getenv("HIGH_FAILURE_THRESHOLD", "0.2"))
