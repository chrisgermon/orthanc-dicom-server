"""
Workflow Engine — Executes visual workflows triggered by HL7 or DICOM events.

A workflow is a graph of nodes (triggers, conditions, actions) connected
by edges. When a trigger fires, the engine walks the graph and executes
matching action nodes.
"""

import json
import logging
import requests

import config
from models import get_db, now_iso

logger = logging.getLogger("workflow-engine")


class WorkflowEngine:
    """Evaluates and executes visual workflows."""

    def __init__(self):
        self.workflows = []
        self.reload()

    def reload(self):
        """Load enabled workflows from the database."""
        db = get_db()
        try:
            rows = db.execute(
                "SELECT id, name, flow_json, enabled FROM workflows WHERE enabled = 1"
            ).fetchall()
            self.workflows = []
            for row in rows:
                try:
                    flow = json.loads(row["flow_json"])
                    self.workflows.append({
                        "id": row["id"],
                        "name": row["name"],
                        "flow": flow,
                    })
                except json.JSONDecodeError:
                    logger.warning("Invalid workflow JSON for id=%d", row["id"])
        finally:
            db.close()
        logger.info("Loaded %d workflows", len(self.workflows))

    def on_hl7_message(self, hl7_msg):
        """Called when an HL7 message arrives. Check workflows for HL7 triggers."""
        for wf in self.workflows:
            try:
                self._evaluate_workflow(wf, "hl7", {
                    "message_type": hl7_msg.message_type,
                    "trigger_event": hl7_msg.trigger_event,
                    "patient_name": hl7_msg.patient_name,
                    "patient_id": hl7_msg.patient_id,
                    "accession_number": hl7_msg.accession_number,
                    "order_status": hl7_msg.order_status,
                    "sending_application": hl7_msg.sending_application,
                })
            except Exception as e:
                logger.error("Workflow %s error: %s", wf["name"], e)

    def on_dicom_study(self, study_data):
        """Called when a DICOM study becomes stable. Check workflows."""
        for wf in self.workflows:
            try:
                self._evaluate_workflow(wf, "dicom", study_data)
            except Exception as e:
                logger.error("Workflow %s error: %s", wf["name"], e)

    def _evaluate_workflow(self, workflow, trigger_type, event_data):
        """Walk the workflow graph starting from matching trigger nodes."""
        flow = workflow["flow"]
        drawflow = flow.get("drawflow", {}).get("Home", {}).get("data", {})
        if not drawflow:
            return

        # Find trigger nodes that match
        for node_id, node in drawflow.items():
            node_class = node.get("class", "")
            node_data = node.get("data", {})

            if trigger_type == "hl7" and node_class == "hl7-trigger":
                if self._matches_hl7_trigger(node_data, event_data):
                    logger.info(
                        "Workflow '%s': HL7 trigger matched (node %s)",
                        workflow["name"], node_id
                    )
                    self._follow_outputs(drawflow, node, event_data, workflow["name"])

            elif trigger_type == "dicom" and node_class == "dicom-trigger":
                if self._matches_dicom_trigger(node_data, event_data):
                    logger.info(
                        "Workflow '%s': DICOM trigger matched (node %s)",
                        workflow["name"], node_id
                    )
                    self._follow_outputs(drawflow, node, event_data, workflow["name"])

    def _matches_hl7_trigger(self, node_data, event_data):
        """Check if HL7 event matches trigger node configuration."""
        # Check message type
        msg_type = node_data.get("messageType", "")
        if msg_type and msg_type != event_data.get("message_type", ""):
            return False

        # Check trigger event
        trigger = node_data.get("triggerEvent", "")
        if trigger and trigger != event_data.get("trigger_event", ""):
            return False

        # Check order status
        status = node_data.get("orderStatus", "")
        if status and status != event_data.get("order_status", ""):
            return False

        return True

    def _matches_dicom_trigger(self, node_data, event_data):
        """Check if DICOM event matches trigger node configuration."""
        modality = node_data.get("modality", "")
        if modality and modality.upper() != event_data.get("modality", "").upper():
            return False

        desc = node_data.get("studyDescription", "")
        if desc:
            study_desc = event_data.get("study_description", "").lower()
            if "*" in desc:
                pattern = desc.lower().replace("*", "")
                if pattern not in study_desc:
                    return False
            elif desc.lower() != study_desc:
                return False

        return True

    def _follow_outputs(self, drawflow, node, event_data, wf_name):
        """Follow output connections from a node and process connected nodes."""
        outputs = node.get("outputs", {})
        for output_key, output_val in outputs.items():
            connections = output_val.get("connections", [])
            for conn in connections:
                target_id = str(conn.get("node", ""))
                target_node = drawflow.get(target_id)
                if not target_node:
                    continue

                target_class = target_node.get("class", "")
                target_data = target_node.get("data", {})

                if target_class == "condition":
                    if self._evaluate_condition(target_data, event_data):
                        self._follow_outputs(drawflow, target_node, event_data, wf_name)
                    else:
                        logger.info("Workflow '%s': condition not met at node %s", wf_name, target_id)

                elif target_class == "action-route":
                    self._execute_route_action(target_data, event_data, wf_name)

                elif target_class == "action-query":
                    results = self._execute_query_action(target_data, event_data, wf_name)
                    if results:
                        # Pass query results downstream
                        enriched = {**event_data, "query_results": results}
                        self._follow_outputs(drawflow, target_node, enriched, wf_name)

                elif target_class == "action-notify":
                    self._execute_notify_action(target_data, event_data, wf_name)

    def _evaluate_condition(self, node_data, event_data):
        """Evaluate a condition node."""
        field = node_data.get("field", "")
        operator = node_data.get("operator", "equals")
        value = node_data.get("value", "")

        if not field or not value:
            return True

        actual = event_data.get(field, "")
        if isinstance(actual, str):
            actual = actual.lower()
            value = value.lower()

        if operator == "equals":
            return actual == value
        elif operator == "not_equals":
            return actual != value
        elif operator == "contains":
            return value in actual
        elif operator == "not_contains":
            return value not in actual
        elif operator == "starts_with":
            return actual.startswith(value)
        return True

    def _execute_route_action(self, node_data, event_data, wf_name):
        """Route a study or series to a destination."""
        destination = node_data.get("destination", "")
        if not destination:
            logger.warning("Workflow '%s': route action missing destination", wf_name)
            return

        # If we have query results, route those
        query_results = event_data.get("query_results", [])
        if query_results:
            for study_id in query_results:
                try:
                    auth = None
                    if config.ORTHANC_USER:
                        auth = (config.ORTHANC_USER, config.ORTHANC_PASS)
                    resp = requests.post(
                        f"{config.ORTHANC_URL}/modalities/{destination}/store",
                        json=study_id,
                        auth=auth,
                        timeout=60,
                    )
                    if resp.ok:
                        logger.info(
                            "Workflow '%s': routed study %s to %s",
                            wf_name, study_id, destination
                        )
                    else:
                        logger.error(
                            "Workflow '%s': route failed for %s: %s",
                            wf_name, study_id, resp.text
                        )
                except Exception as e:
                    logger.error("Workflow '%s': route error: %s", wf_name, e)
        else:
            logger.info(
                "Workflow '%s': route action has no studies to route", wf_name
            )

    def _execute_query_action(self, node_data, event_data, wf_name):
        """Query Orthanc for matching studies."""
        auth = None
        if config.ORTHANC_USER:
            auth = (config.ORTHANC_USER, config.ORTHANC_PASS)

        # Build query
        query = {}
        accession = node_data.get("accessionNumber", "") or event_data.get("accession_number", "")
        if accession:
            query["AccessionNumber"] = accession

        patient_id = node_data.get("patientId", "") or event_data.get("patient_id", "")
        if patient_id:
            query["PatientID"] = patient_id

        modality = node_data.get("modality", "")
        if modality:
            query["ModalitiesInStudy"] = modality

        if not query:
            logger.warning("Workflow '%s': query action has no search criteria", wf_name)
            return []

        try:
            resp = requests.post(
                f"{config.ORTHANC_URL}/tools/find",
                json={"Level": "Study", "Query": query},
                auth=auth,
                timeout=30,
            )
            if resp.ok:
                results = resp.json()
                logger.info(
                    "Workflow '%s': query found %d studies",
                    wf_name, len(results)
                )
                return results
            else:
                logger.error("Workflow '%s': query failed: %s", wf_name, resp.text)
        except Exception as e:
            logger.error("Workflow '%s': query error: %s", wf_name, e)

        return []

    def _execute_notify_action(self, node_data, event_data, wf_name):
        """Log a notification event."""
        message = node_data.get("message", "Workflow notification")
        logger.info(
            "Workflow '%s' NOTIFY: %s (event: %s)",
            wf_name, message, json.dumps(event_data, default=str)[:200]
        )
