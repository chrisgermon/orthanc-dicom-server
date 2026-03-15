"""
AI DICOM Routing Agent — FastAPI application.

Provides REST API for the admin dashboard:
- Traffic summaries and unrouted study detection
- AI-generated rule suggestions with one-click apply
- Plain English explanations of existing routing rules
"""

import json
import os
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

import config
from models import get_db, now_iso
from collector import TrafficCollector
from suggester import RuleSuggester

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
)
logger = logging.getLogger("ai-agent")

collector = TrafficCollector()
suggester = RuleSuggester()


@asynccontextmanager
async def lifespan(app: FastAPI):
    collector.start()
    logger.info("AI DICOM Routing Agent started")
    yield
    collector.stop()
    logger.info("AI DICOM Routing Agent stopped")


app = FastAPI(
    title="AI DICOM Routing Agent",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── Health ──


@app.get("/api/health")
def health():
    return {"status": "ok", "service": "ai-dicom-agent"}


# ── Traffic Summary ──


@app.get("/api/traffic/summary")
def traffic_summary():
    """Traffic overview: volumes, top modalities, top sources."""
    db = get_db()
    try:
        # Total counts by time period
        periods = {
            "24h": "datetime('now', '-1 day')",
            "7d": "datetime('now', '-7 days')",
            "30d": "datetime('now', '-30 days')",
        }
        totals = {}
        for label, expr in periods.items():
            row = db.execute(
                f"SELECT COUNT(*) as cnt FROM traffic_events WHERE timestamp >= {expr}"
            ).fetchone()
            totals[label] = row["cnt"]

        # Top modalities (last 7 days)
        modalities = db.execute(
            """SELECT modality, COUNT(*) as cnt
               FROM traffic_events
               WHERE timestamp >= datetime('now', '-7 days') AND modality != ''
               GROUP BY modality
               ORDER BY cnt DESC LIMIT 10"""
        ).fetchall()

        # Top source AETs (last 7 days)
        sources = db.execute(
            """SELECT calling_aet, COUNT(*) as cnt
               FROM traffic_events
               WHERE timestamp >= datetime('now', '-7 days') AND calling_aet != ''
               GROUP BY calling_aet
               ORDER BY cnt DESC LIMIT 10"""
        ).fetchall()

        # Top study descriptions (last 7 days)
        descriptions = db.execute(
            """SELECT study_description, COUNT(*) as cnt
               FROM traffic_events
               WHERE timestamp >= datetime('now', '-7 days') AND study_description != ''
               GROUP BY study_description
               ORDER BY cnt DESC LIMIT 10"""
        ).fetchall()

        # Routed vs unrouted (last 7 days)
        routing = db.execute(
            """SELECT routed, COUNT(*) as cnt
               FROM traffic_events
               WHERE timestamp >= datetime('now', '-7 days')
               GROUP BY routed"""
        ).fetchall()
        routed_count = sum(r["cnt"] for r in routing if r["routed"] == 1)
        unrouted_count = sum(r["cnt"] for r in routing if r["routed"] == 0)

        return {
            "totals": totals,
            "modalities": [
                {"name": r["modality"], "count": r["cnt"]} for r in modalities
            ],
            "sources": [
                {"name": r["calling_aet"], "count": r["cnt"]} for r in sources
            ],
            "descriptions": [
                {"name": r["study_description"], "count": r["cnt"]}
                for r in descriptions
            ],
            "routing": {
                "routed": routed_count,
                "unrouted": unrouted_count,
            },
        }
    finally:
        db.close()


# ── Unrouted Studies ──


@app.get("/api/traffic/unrouted")
def traffic_unrouted():
    """List studies that matched no routing rule."""
    db = get_db()
    try:
        rows = db.execute(
            """SELECT timestamp, study_uid, patient_name, modality,
                      study_description, calling_aet, called_aet,
                      num_series, num_instances
               FROM traffic_events
               WHERE routed = 0
               ORDER BY timestamp DESC
               LIMIT 50"""
        ).fetchall()

        return {
            "count": len(rows),
            "studies": [
                {
                    "timestamp": r["timestamp"],
                    "studyUid": r["study_uid"],
                    "patientName": r["patient_name"],
                    "modality": r["modality"],
                    "studyDescription": r["study_description"],
                    "callingAet": r["calling_aet"],
                    "calledAet": r["called_aet"],
                    "numSeries": r["num_series"],
                    "numInstances": r["num_instances"],
                }
                for r in rows
            ],
        }
    finally:
        db.close()


# ── Suggestions ──


@app.get("/api/suggestions")
def get_suggestions():
    """Get all pending AI-generated suggestions."""
    # First, regenerate suggestions
    suggester.run_and_save()

    db = get_db()
    try:
        rows = db.execute(
            """SELECT id, created_at, category, title, description,
                      confidence, rule_json, status
               FROM suggestions
               WHERE status = 'pending'
               ORDER BY confidence DESC, created_at DESC
               LIMIT 50"""
        ).fetchall()

        return {
            "count": len(rows),
            "suggestions": [
                {
                    "id": r["id"],
                    "createdAt": r["created_at"],
                    "category": r["category"],
                    "title": r["title"],
                    "description": r["description"],
                    "confidence": r["confidence"],
                    "ruleJson": (
                        json.loads(r["rule_json"]) if r["rule_json"] else None
                    ),
                    "status": r["status"],
                }
                for r in rows
            ],
        }
    finally:
        db.close()


class ApplyRequest(BaseModel):
    destination: str | None = None


@app.post("/api/suggestions/{suggestion_id}/apply")
def apply_suggestion(suggestion_id: int, body: ApplyRequest = None):
    """Apply a suggestion — adds the rule to routing-rules.json."""
    db = get_db()
    try:
        row = db.execute(
            "SELECT * FROM suggestions WHERE id = ?", (suggestion_id,)
        ).fetchone()
        if not row:
            raise HTTPException(404, "Suggestion not found")
        if row["status"] != "pending":
            raise HTTPException(400, "Suggestion already processed")
        if not row["rule_json"]:
            raise HTTPException(
                400, "This suggestion has no associated rule to apply"
            )

        rule = json.loads(row["rule_json"])

        # Override destination if provided
        if body and body.destination:
            rule["destination"] = body.destination

        # Load existing rules
        rules_path = config.ROUTING_RULES_PATH
        rules = []
        if os.path.exists(rules_path):
            try:
                with open(rules_path, "r") as f:
                    rules = json.loads(f.read().strip() or "[]")
            except (json.JSONDecodeError, IOError):
                rules = []

        # Add the new rule
        rules.append(rule)

        # Save
        with open(rules_path, "w") as f:
            json.dump(rules, f)

        # Mark suggestion as applied
        db.execute(
            "UPDATE suggestions SET status = 'applied' WHERE id = ?",
            (suggestion_id,),
        )
        db.commit()

        return {
            "status": "applied",
            "rule": rule,
            "message": (
                f'Rule "{rule.get("name", "")}" has been added. '
                f"Reload the routing rules in the admin panel to activate it."
            ),
        }
    finally:
        db.close()


@app.post("/api/suggestions/{suggestion_id}/dismiss")
def dismiss_suggestion(suggestion_id: int):
    """Dismiss a suggestion."""
    db = get_db()
    try:
        row = db.execute(
            "SELECT id FROM suggestions WHERE id = ?", (suggestion_id,)
        ).fetchone()
        if not row:
            raise HTTPException(404, "Suggestion not found")

        db.execute(
            "UPDATE suggestions SET status = 'dismissed', dismissed_at = ? WHERE id = ?",
            (now_iso(), suggestion_id),
        )
        db.commit()

        return {"status": "dismissed"}
    finally:
        db.close()


# ── Rule Explainer ──


@app.get("/api/rules/explain")
def explain_rules():
    """Get plain English explanations of all current routing rules."""
    explanations = suggester.explain_rules()
    return {"rules": explanations}


# ── Collect Now (manual trigger) ──


@app.post("/api/collect")
def collect_now():
    """Trigger an immediate data collection."""
    success = collector.collect_now()
    return {"status": "ok" if success else "error"}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=5000)
