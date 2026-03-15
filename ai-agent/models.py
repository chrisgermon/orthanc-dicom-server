"""Data models for the AI DICOM Routing Agent."""

import sqlite3
import os
from datetime import datetime, timezone
from config import DB_PATH, DATA_DIR


def get_db():
    """Get a database connection, creating tables if needed."""
    os.makedirs(DATA_DIR, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    _create_tables(conn)
    return conn


def _create_tables(conn):
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS traffic_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            study_uid TEXT,
            patient_name TEXT,
            patient_id TEXT,
            modality TEXT,
            study_description TEXT,
            calling_aet TEXT,
            called_aet TEXT,
            num_series INTEGER DEFAULT 0,
            num_instances INTEGER DEFAULT 0,
            routed INTEGER DEFAULT 0,
            route_rule TEXT,
            route_dest TEXT
        );

        CREATE TABLE IF NOT EXISTS suggestions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL,
            category TEXT NOT NULL,
            title TEXT NOT NULL,
            description TEXT NOT NULL,
            confidence INTEGER DEFAULT 50,
            rule_json TEXT,
            status TEXT DEFAULT 'pending',
            dismissed_at TEXT
        );

        CREATE TABLE IF NOT EXISTS collector_state (
            key TEXT PRIMARY KEY,
            value TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_traffic_timestamp
            ON traffic_events(timestamp);
        CREATE INDEX IF NOT EXISTS idx_traffic_modality
            ON traffic_events(modality);
        CREATE INDEX IF NOT EXISTS idx_traffic_calling_aet
            ON traffic_events(calling_aet);
        CREATE INDEX IF NOT EXISTS idx_traffic_routed
            ON traffic_events(routed);
        CREATE INDEX IF NOT EXISTS idx_traffic_study_uid
            ON traffic_events(study_uid);
        CREATE INDEX IF NOT EXISTS idx_suggestions_status
            ON suggestions(status);

        CREATE TABLE IF NOT EXISTS hl7_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            message_type TEXT,
            trigger_event TEXT,
            message_control_id TEXT,
            patient_name TEXT,
            patient_id TEXT,
            accession_number TEXT,
            order_status TEXT,
            sending_application TEXT,
            sending_facility TEXT,
            receiving_application TEXT,
            receiving_facility TEXT,
            raw_message TEXT,
            parsed_segments TEXT
        );

        CREATE TABLE IF NOT EXISTS workflows (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            description TEXT DEFAULT '',
            flow_json TEXT NOT NULL,
            enabled INTEGER DEFAULT 1,
            created_at TEXT NOT NULL,
            updated_at TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_hl7_timestamp
            ON hl7_messages(timestamp);
        CREATE INDEX IF NOT EXISTS idx_hl7_message_type
            ON hl7_messages(message_type);
        CREATE INDEX IF NOT EXISTS idx_hl7_patient_id
            ON hl7_messages(patient_id);
        CREATE INDEX IF NOT EXISTS idx_hl7_accession
            ON hl7_messages(accession_number);
    """)
    conn.commit()


def get_state(conn, key, default=None):
    row = conn.execute(
        "SELECT value FROM collector_state WHERE key = ?", (key,)
    ).fetchone()
    return row["value"] if row else default


def set_state(conn, key, value):
    conn.execute(
        "INSERT OR REPLACE INTO collector_state (key, value) VALUES (?, ?)",
        (key, str(value)),
    )
    conn.commit()


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
