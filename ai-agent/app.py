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
import requests

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

import config
from models import get_db, now_iso
from collector import TrafficCollector
from suggester import RuleSuggester
from hl7_receiver import HL7Receiver
from workflow_engine import WorkflowEngine
import llm

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
)
logger = logging.getLogger("ai-agent")

collector = TrafficCollector()
suggester = RuleSuggester()
workflow_engine = WorkflowEngine()
hl7_receiver = HL7Receiver(on_message=workflow_engine.on_hl7_message)


@asynccontextmanager
async def lifespan(app: FastAPI):
    collector.start()
    hl7_receiver.start()
    logger.info("AI DICOM Routing Agent started")
    yield
    hl7_receiver.stop()
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
    return {
        "status": "ok",
        "service": "ai-dicom-agent",
        "llm_enabled": config.LLM_ENABLED,
        "llm_model": config.ANTHROPIC_MODEL if config.LLM_ENABLED else None,
        "hl7_enabled": config.HL7_ENABLED,
        "hl7_port": config.HL7_PORT if config.HL7_ENABLED else None,
    }


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


# ── Rule Test / Dry Run ──


class RuleTestRequest(BaseModel):
    rule: dict


@app.post("/api/rules/test")
def test_rule(body: RuleTestRequest):
    """Dry-run a rule to preview matching studies without routing."""
    rule = body.rule
    import fnmatch
    from datetime import datetime, timedelta

    auth = None
    if config.ORTHANC_USER:
        auth = (config.ORTHANC_USER, config.ORTHANC_PASS)

    def matches_filter(value, pattern):
        if not pattern:
            return True
        value = (value or "").lower()
        pattern = pattern.lower()
        if pattern.startswith("!"):
            return not fnmatch.fnmatch(value, pattern[1:])
        return fnmatch.fnmatch(value, pattern)

    def get_date_range(filter_val):
        """Mirror the Lua GetDateRangeQuery logic."""
        if not filter_val:
            return ""
        today = datetime.utcnow().strftime("%Y%m%d")
        if filter_val == "today":
            return f"{today}-{today}"
        days_map = {"yesterday": 1, "7days": 7, "30days": 30, "90days": 90}
        days = days_map.get(filter_val, 0)
        if days == 0:
            return ""
        start = (datetime.utcnow() - timedelta(days=days)).strftime("%Y%m%d")
        return f"{start}-{today}"

    modality_filter = rule.get("filterModality", "")
    desc_filter = rule.get("filterStudyDescription") or rule.get("filterDescription", "")
    date_filter = rule.get("filterDateRange", "")
    rule_type = rule.get("type", "push")
    source = rule.get("source", "")

    matched = []

    if rule_type == "poll" and source:
        # ── Poll rule: query the SOURCE PACS via C-FIND ──
        query = {}
        if modality_filter and "!" not in modality_filter and "*" not in modality_filter:
            query["ModalitiesInStudy"] = modality_filter
        if desc_filter and "!" not in desc_filter:
            query["StudyDescription"] = desc_filter

        date_range = get_date_range(date_filter)
        if date_range:
            query["StudyDate"] = date_range

        try:
            qr = requests.post(
                f"{config.ORTHANC_URL}/modalities/{source}/query",
                json={"Level": "Study", "Query": query},
                auth=auth, timeout=30,
            )
            if not qr.ok:
                raise HTTPException(500, f"C-FIND to {source} failed: {qr.status_code} {qr.text}")
            query_id = qr.json().get("ID")
            if not query_id:
                raise HTTPException(500, "C-FIND returned no query ID")
        except requests.RequestException as e:
            raise HTTPException(500, f"Connection to Orthanc failed: {e}")

        # Get answers
        try:
            ans_resp = requests.get(
                f"{config.ORTHANC_URL}/queries/{query_id}/answers",
                auth=auth, timeout=30,
            )
            answers = ans_resp.json()
        except Exception as e:
            raise HTTPException(500, f"Failed to get C-FIND answers: {e}")

        for ans_idx in answers:
            try:
                content = requests.get(
                    f"{config.ORTHANC_URL}/queries/{query_id}/answers/{ans_idx}/content",
                    auth=auth, timeout=10,
                ).json()
            except Exception:
                continue

            def tag_val(v):
                """Extract string from DICOM tag value (may be str or {"Value":[...]})."""
                if v is None:
                    return ""
                if isinstance(v, str):
                    return v
                if isinstance(v, dict):
                    vals = v.get("Value", [])
                    if vals and len(vals) > 0:
                        return str(vals[0])
                    return ""
                return str(v)

            study_uid = tag_val(content.get("0020,000d") or content.get("StudyInstanceUID"))
            study_desc = tag_val(content.get("0008,1030") or content.get("StudyDescription"))
            patient_name = tag_val(content.get("0010,0010") or content.get("PatientName"))
            patient_id = tag_val(content.get("0010,0020") or content.get("PatientID"))
            study_mod = tag_val(content.get("0008,0061") or content.get("ModalitiesInStudy"))
            study_date = tag_val(content.get("0008,0020") or content.get("StudyDate"))

            # Apply negation filters locally
            if modality_filter and "!" in modality_filter:
                if not matches_filter(study_mod, modality_filter):
                    continue
            if desc_filter and "!" in desc_filter:
                if not matches_filter(study_desc, desc_filter):
                    continue

            matched.append({
                "studyId": study_uid,
                "patientName": patient_name,
                "patientId": patient_id,
                "modality": study_mod,
                "studyDescription": study_desc,
                "studyDate": study_date,
                "seriesCount": 0,
                "matchingSeries": None,
            })

    else:
        # ── Push rule: query local Orthanc ──
        query = {}
        if modality_filter and "*" not in modality_filter and "!" not in modality_filter:
            query["ModalitiesInStudy"] = modality_filter
        if desc_filter and "!" not in desc_filter:
            clean = desc_filter.replace("*", "")
            if clean:
                query["StudyDescription"] = f"*{clean}*"

        date_range = get_date_range(date_filter)
        if date_range:
            query["StudyDate"] = date_range

        try:
            resp = requests.post(
                f"{config.ORTHANC_URL}/tools/find",
                json={"Level": "Study", "Query": query, "Expand": True},
                auth=auth, timeout=30,
            )
            if not resp.ok:
                raise HTTPException(500, f"Orthanc query failed: {resp.status_code}")
            studies = resp.json()
        except requests.RequestException as e:
            raise HTTPException(500, f"Orthanc connection error: {e}")

        for study in studies:
            tags = study.get("MainDicomTags", {})
            patient_tags = study.get("PatientMainDicomTags", {})
            mod = tags.get("ModalitiesInStudy", "")
            desc = tags.get("StudyDescription", "")

            if not matches_filter(mod, modality_filter):
                continue
            if not matches_filter(desc, desc_filter):
                continue

            series_count = len(study.get("Series", []))
            matching_series = []
            series_desc_filter = rule.get("filterSeriesDescription", "")
            send_level = rule.get("sendLevel", "study")

            if send_level == "series" and series_desc_filter:
                for series_id in study.get("Series", []):
                    try:
                        sr = requests.get(
                            f"{config.ORTHANC_URL}/series/{series_id}",
                            auth=auth, timeout=10,
                        ).json()
                        st = sr.get("MainDicomTags", {})
                        s_desc = st.get("SeriesDescription", "")
                        s_mod = st.get("Modality", "")
                        if series_desc_filter and not matches_filter(s_desc, series_desc_filter):
                            continue
                        matching_series.append({
                            "description": s_desc, "modality": s_mod,
                            "instances": len(sr.get("Instances", [])),
                        })
                    except Exception:
                        pass
                if not matching_series:
                    continue

            matched.append({
                "studyId": study.get("ID", ""),
                "patientName": patient_tags.get("PatientName", ""),
                "patientId": patient_tags.get("PatientID", ""),
                "modality": mod,
                "studyDescription": desc,
                "studyDate": tags.get("StudyDate", ""),
                "seriesCount": series_count,
                "matchingSeries": matching_series if matching_series else None,
            })

    return {
        "totalStudies": len(matched),
        "destination": rule.get("destination", ""),
        "ruleName": rule.get("name", ""),
        "source": source if rule_type == "poll" else "local",
        "studies": matched[:100],
    }


# ── Collect Now (manual trigger) ──


@app.post("/api/collect")
def collect_now():
    """Trigger an immediate data collection."""
    success = collector.collect_now()
    return {"status": "ok" if success else "error"}


# ── HL7 Messages ──


@app.get("/api/hl7/messages")
def hl7_messages(limit: int = 50, offset: int = 0, msg_type: str = ""):
    """List HL7 messages with optional filtering."""
    db = get_db()
    try:
        where = "1=1"
        params = []
        if msg_type:
            where += " AND message_type = ?"
            params.append(msg_type)

        params.extend([limit, offset])
        rows = db.execute(
            f"""SELECT id, timestamp, message_type, trigger_event,
                      patient_name, patient_id, accession_number, order_status,
                      sending_application, sending_facility
               FROM hl7_messages
               WHERE {where}
               ORDER BY timestamp DESC
               LIMIT ? OFFSET ?""",
            params,
        ).fetchall()

        total = db.execute(
            f"SELECT COUNT(*) as cnt FROM hl7_messages WHERE {where}",
            params[:-2] if msg_type else [],
        ).fetchone()["cnt"]

        return {
            "total": total,
            "messages": [
                {
                    "id": r["id"],
                    "timestamp": r["timestamp"],
                    "messageType": r["message_type"],
                    "triggerEvent": r["trigger_event"],
                    "patientName": r["patient_name"],
                    "patientId": r["patient_id"],
                    "accessionNumber": r["accession_number"],
                    "orderStatus": r["order_status"],
                    "sendingApp": r["sending_application"],
                    "sendingFacility": r["sending_facility"],
                }
                for r in rows
            ],
        }
    finally:
        db.close()


@app.get("/api/hl7/messages/{message_id}")
def hl7_message_detail(message_id: int):
    """Get full HL7 message with raw content and parsed segments."""
    db = get_db()
    try:
        row = db.execute(
            "SELECT * FROM hl7_messages WHERE id = ?", (message_id,)
        ).fetchone()
        if not row:
            raise HTTPException(404, "Message not found")

        parsed = []
        if row["parsed_segments"]:
            try:
                parsed = json.loads(row["parsed_segments"])
            except json.JSONDecodeError:
                pass

        return {
            "id": row["id"],
            "timestamp": row["timestamp"],
            "messageType": row["message_type"],
            "triggerEvent": row["trigger_event"],
            "messageControlId": row["message_control_id"],
            "patientName": row["patient_name"],
            "patientId": row["patient_id"],
            "accessionNumber": row["accession_number"],
            "orderStatus": row["order_status"],
            "sendingApp": row["sending_application"],
            "sendingFacility": row["sending_facility"],
            "receivingApp": row["receiving_application"],
            "receivingFacility": row["receiving_facility"],
            "rawMessage": row["raw_message"],
            "parsedSegments": parsed,
        }
    finally:
        db.close()


@app.get("/api/hl7/stats")
def hl7_stats():
    """HL7 message statistics."""
    db = get_db()
    try:
        total = db.execute("SELECT COUNT(*) as cnt FROM hl7_messages").fetchone()["cnt"]

        by_type = db.execute(
            """SELECT message_type, trigger_event, COUNT(*) as cnt
               FROM hl7_messages
               GROUP BY message_type, trigger_event
               ORDER BY cnt DESC LIMIT 20"""
        ).fetchall()

        recent_24h = db.execute(
            """SELECT COUNT(*) as cnt FROM hl7_messages
               WHERE timestamp >= datetime('now', '-1 day')"""
        ).fetchone()["cnt"]

        return {
            "total": total,
            "recent24h": recent_24h,
            "byType": [
                {
                    "type": f"{r['message_type']}^{r['trigger_event']}",
                    "count": r["cnt"],
                }
                for r in by_type
            ],
        }
    finally:
        db.close()


# ── Workflows ──


class WorkflowSaveRequest(BaseModel):
    name: str
    description: str = ""
    flow_json: dict
    enabled: bool = True


@app.get("/api/workflows")
def list_workflows():
    """List all saved workflows."""
    db = get_db()
    try:
        rows = db.execute(
            """SELECT id, name, description, enabled, created_at, updated_at
               FROM workflows ORDER BY created_at DESC"""
        ).fetchall()
        return {
            "workflows": [
                {
                    "id": r["id"],
                    "name": r["name"],
                    "description": r["description"],
                    "enabled": bool(r["enabled"]),
                    "createdAt": r["created_at"],
                    "updatedAt": r["updated_at"],
                }
                for r in rows
            ]
        }
    finally:
        db.close()


@app.get("/api/workflows/{workflow_id}")
def get_workflow(workflow_id: int):
    """Get a workflow with its full flow JSON."""
    db = get_db()
    try:
        row = db.execute(
            "SELECT * FROM workflows WHERE id = ?", (workflow_id,)
        ).fetchone()
        if not row:
            raise HTTPException(404, "Workflow not found")
        return {
            "id": row["id"],
            "name": row["name"],
            "description": row["description"],
            "flowJson": json.loads(row["flow_json"]),
            "enabled": bool(row["enabled"]),
            "createdAt": row["created_at"],
            "updatedAt": row["updated_at"],
        }
    finally:
        db.close()


@app.post("/api/workflows")
def save_workflow(body: WorkflowSaveRequest):
    """Create or update a workflow."""
    db = get_db()
    try:
        now = now_iso()
        db.execute(
            """INSERT INTO workflows (name, description, flow_json, enabled, created_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (body.name, body.description, json.dumps(body.flow_json),
             1 if body.enabled else 0, now, now),
        )
        db.commit()
        wf_id = db.execute("SELECT last_insert_rowid()").fetchone()[0]

        # Reload workflows in engine
        workflow_engine.reload()

        return {"id": wf_id, "status": "created"}
    finally:
        db.close()


@app.put("/api/workflows/{workflow_id}")
def update_workflow(workflow_id: int, body: WorkflowSaveRequest):
    """Update an existing workflow."""
    db = get_db()
    try:
        row = db.execute(
            "SELECT id FROM workflows WHERE id = ?", (workflow_id,)
        ).fetchone()
        if not row:
            raise HTTPException(404, "Workflow not found")

        db.execute(
            """UPDATE workflows SET name = ?, description = ?, flow_json = ?,
                      enabled = ?, updated_at = ? WHERE id = ?""",
            (body.name, body.description, json.dumps(body.flow_json),
             1 if body.enabled else 0, now_iso(), workflow_id),
        )
        db.commit()
        workflow_engine.reload()
        return {"id": workflow_id, "status": "updated"}
    finally:
        db.close()


@app.delete("/api/workflows/{workflow_id}")
def delete_workflow(workflow_id: int):
    """Delete a workflow."""
    db = get_db()
    try:
        db.execute("DELETE FROM workflows WHERE id = ?", (workflow_id,))
        db.commit()
        workflow_engine.reload()
        return {"status": "deleted"}
    finally:
        db.close()


# ── LLM: Natural Language Rule Builder ──


class BuildRuleRequest(BaseModel):
    prompt: str


@app.post("/api/rules/build")
def build_rule(body: BuildRuleRequest):
    """Convert natural language to a routing rule using Claude."""
    if not config.LLM_ENABLED:
        raise HTTPException(503, "LLM not configured — set ANTHROPIC_API_KEY")

    # Get available modalities and current rules for context
    modalities = _get_modalities()
    current_rules = _load_rules()

    try:
        result = llm.parse_natural_language_rule(
            prompt=body.prompt,
            available_modalities=modalities,
            current_rules=current_rules,
        )
        return result
    except RuntimeError as e:
        raise HTTPException(500, str(e))


class ChatRequest(BaseModel):
    message: str
    conversation: list[dict] = []


@app.post("/api/chat")
def chat_endpoint(body: ChatRequest):
    """Conversational rule building and HL7 analysis with Claude."""
    if not config.LLM_ENABLED:
        raise HTTPException(503, "LLM not configured — set ANTHROPIC_API_KEY")

    modalities = _get_modalities()
    current_rules = _load_rules()

    # Fetch recent HL7 messages for context
    hl7_context = ""
    try:
        db = get_db()
        hl7_stats = db.execute(
            "SELECT COUNT(*) as total FROM hl7_messages"
        ).fetchone()
        hl7_recent = db.execute(
            """SELECT timestamp, message_type, trigger_event, patient_name,
                      patient_id, accession_number, order_status,
                      sending_application, sending_facility
               FROM hl7_messages ORDER BY timestamp DESC LIMIT 50"""
        ).fetchall()

        if hl7_recent:
            msg_lines = []
            for r in hl7_recent:
                msg_lines.append(
                    f"  {r['timestamp']} | {r['message_type']}^{r['trigger_event']} | "
                    f"Patient: {r['patient_name'] or '-'} ({r['patient_id'] or '-'}) | "
                    f"Acc: {r['accession_number'] or '-'} | Status: {r['order_status'] or '-'} | "
                    f"From: {r['sending_application'] or ''}"
                )
            hl7_context = (
                f"Total HL7 messages received: {hl7_stats['total']}\n"
                f"Recent 50 messages (newest first):\n" + "\n".join(msg_lines)
            )

        # Also get type breakdown
        type_breakdown = db.execute(
            """SELECT message_type, trigger_event, COUNT(*) as cnt
               FROM hl7_messages GROUP BY message_type, trigger_event
               ORDER BY cnt DESC LIMIT 20"""
        ).fetchall()
        if type_breakdown:
            hl7_context += "\n\nMessage type breakdown:\n" + "\n".join(
                f"  {r['message_type']}^{r['trigger_event']}: {r['cnt']} messages"
                for r in type_breakdown
            )

        db.close()
    except Exception:
        pass

    try:
        result = llm.chat(
            message=body.message,
            conversation_history=body.conversation,
            available_modalities=modalities,
            current_rules=current_rules,
            hl7_context=hl7_context,
        )
        return result
    except RuntimeError as e:
        raise HTTPException(500, str(e))


def _get_modalities():
    """Get configured DICOM modalities from Orthanc."""
    try:
        import requests
        resp = requests.get(
            f"{config.ORTHANC_URL}/modalities",
            auth=(config.ORTHANC_USER, config.ORTHANC_PASS) if config.ORTHANC_USER else None,
            timeout=5,
        )
        if resp.ok:
            names = resp.json()
            modalities = []
            for name in names:
                try:
                    detail = requests.get(
                        f"{config.ORTHANC_URL}/modalities/{name}/configuration",
                        auth=(config.ORTHANC_USER, config.ORTHANC_PASS) if config.ORTHANC_USER else None,
                        timeout=5,
                    )
                    if detail.ok:
                        d = detail.json()
                        modalities.append({"name": name, **d})
                    else:
                        modalities.append({"name": name})
                except Exception:
                    modalities.append({"name": name})
            return modalities
    except Exception:
        pass
    return []


def _load_rules():
    """Load current routing rules."""
    import os
    path = config.ROUTING_RULES_PATH
    if not os.path.exists(path):
        return []
    try:
        with open(path, "r") as f:
            return json.loads(f.read().strip() or "[]")
    except (json.JSONDecodeError, IOError):
        return []


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=5000)
