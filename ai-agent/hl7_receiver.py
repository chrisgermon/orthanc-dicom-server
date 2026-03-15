"""
HL7 MLLP Receiver — Listens for HL7 v2.x messages and stores them.

Supports ADT, ORM, ORU, SIU message types.
Triggers workflow engine on configurable events.
"""

import asyncio
import json
import logging
import threading
from datetime import datetime, timezone

import config
from models import get_db, now_iso

logger = logging.getLogger("hl7-receiver")

# MLLP framing characters
MLLP_START = b"\x0b"
MLLP_END = b"\x1c\x0d"


class HL7Message:
    """Parsed HL7 v2.x message."""

    def __init__(self, raw: str):
        self.raw = raw
        self.segments = {}
        self.segment_list = []
        self._parse()

    def _parse(self):
        lines = self.raw.strip().split("\r")
        if not lines:
            lines = self.raw.strip().split("\n")

        for line in lines:
            line = line.strip()
            if not line:
                continue
            fields = line.split("|")
            seg_name = fields[0]

            if seg_name == "MSH":
                # MSH is special — field separator is the first char after MSH
                # Reconstruct with proper indexing
                parsed = {"fields": fields}
            else:
                parsed = {"fields": fields}

            if seg_name not in self.segments:
                self.segments[seg_name] = []
            self.segments[seg_name].append(parsed)
            self.segment_list.append({"name": seg_name, "fields": fields})

    def get_field(self, segment, field_index, component=0, default=""):
        """Get a field value. MSH uses 1-indexed fields per HL7 spec."""
        segs = self.segments.get(segment, [])
        if not segs:
            return default
        fields = segs[0]["fields"]
        if segment == "MSH":
            # MSH field numbering: MSH-1 = |, MSH-2 = ^~\&, MSH-3 = fields[2], etc.
            idx = field_index - 1
        else:
            idx = field_index
        if idx >= len(fields):
            return default
        value = fields[idx]
        if component > 0:
            components = value.split("^")
            return components[component - 1] if component <= len(components) else default
        return value

    @property
    def message_type(self):
        raw_type = self.get_field("MSH", 9)
        parts = raw_type.split("^")
        return parts[0] if parts else ""

    @property
    def trigger_event(self):
        raw_type = self.get_field("MSH", 9)
        parts = raw_type.split("^")
        return parts[1] if len(parts) > 1 else ""

    @property
    def message_control_id(self):
        return self.get_field("MSH", 10)

    @property
    def sending_application(self):
        return self.get_field("MSH", 3)

    @property
    def sending_facility(self):
        return self.get_field("MSH", 4)

    @property
    def receiving_application(self):
        return self.get_field("MSH", 5)

    @property
    def receiving_facility(self):
        return self.get_field("MSH", 6)

    @property
    def patient_name(self):
        raw = self.get_field("PID", 5)
        parts = raw.split("^")
        if len(parts) >= 2:
            return f"{parts[1]} {parts[0]}".strip()
        return parts[0] if parts else ""

    @property
    def patient_id(self):
        return self.get_field("PID", 3, component=1)

    @property
    def accession_number(self):
        # Try OBR first, then ORC
        acc = self.get_field("OBR", 18)
        if not acc:
            acc = self.get_field("ORC", 2)
        return acc

    @property
    def order_status(self):
        return self.get_field("ORC", 5)

    def build_ack(self, ack_code="AA"):
        """Build an ACK response."""
        ts = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
        ack = (
            f"MSH|^~\\&|AI_AGENT|ORTHANC|"
            f"{self.sending_application}|{self.sending_facility}|"
            f"{ts}||ACK^{self.trigger_event}|{ts}|P|2.5\r"
            f"MSA|{ack_code}|{self.message_control_id}\r"
        )
        return ack

    def to_parsed_json(self):
        """Return parsed segments as JSON-serializable dict."""
        result = []
        for seg in self.segment_list:
            result.append({
                "name": seg["name"],
                "fields": seg["fields"],
            })
        return result


def store_message(msg: HL7Message):
    """Store an HL7 message in SQLite."""
    db = get_db()
    try:
        db.execute(
            """INSERT INTO hl7_messages
               (timestamp, message_type, trigger_event, message_control_id,
                patient_name, patient_id, accession_number, order_status,
                sending_application, sending_facility,
                receiving_application, receiving_facility,
                raw_message, parsed_segments)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                now_iso(),
                msg.message_type,
                msg.trigger_event,
                msg.message_control_id,
                msg.patient_name,
                msg.patient_id,
                msg.accession_number,
                msg.order_status,
                msg.sending_application,
                msg.sending_facility,
                msg.receiving_application,
                msg.receiving_facility,
                msg.raw,
                json.dumps(msg.to_parsed_json()),
            ),
        )
        db.commit()
        logger.info(
            "Stored HL7 %s^%s from %s (patient: %s, accession: %s)",
            msg.message_type,
            msg.trigger_event,
            msg.sending_application,
            msg.patient_name,
            msg.accession_number,
        )
    finally:
        db.close()


class MLLPProtocol(asyncio.Protocol):
    """MLLP protocol handler for HL7 messages."""

    def __init__(self, on_message=None):
        self.buffer = b""
        self.transport = None
        self.on_message = on_message

    def connection_made(self, transport):
        peer = transport.get_extra_info("peername")
        logger.info("HL7 connection from %s", peer)
        self.transport = transport

    def data_received(self, data):
        self.buffer += data

        # Look for complete MLLP-framed messages
        while MLLP_START in self.buffer and MLLP_END in self.buffer:
            start = self.buffer.index(MLLP_START)
            end = self.buffer.index(MLLP_END)

            if end > start:
                raw_msg = self.buffer[start + 1 : end].decode("utf-8", errors="replace")
                self.buffer = self.buffer[end + 2 :]

                try:
                    msg = HL7Message(raw_msg)
                    store_message(msg)

                    # Send ACK
                    ack = msg.build_ack("AA")
                    self.transport.write(MLLP_START + ack.encode("utf-8") + MLLP_END)

                    # Trigger workflow engine if callback registered
                    if self.on_message:
                        try:
                            self.on_message(msg)
                        except Exception as e:
                            logger.error("Workflow trigger error: %s", e)

                except Exception as e:
                    logger.error("Failed to process HL7 message: %s", e)
                    # Send NACK
                    nack = f"MSH|^~\\&|AI_AGENT|ORTHANC||||{now_iso()}||ACK|NACK|P|2.5\rMSA|AE|ERROR\r"
                    self.transport.write(
                        MLLP_START + nack.encode("utf-8") + MLLP_END
                    )
            else:
                break

    def connection_lost(self, exc):
        logger.info("HL7 connection closed")


class HL7Receiver:
    """HL7 MLLP receiver that runs in a background thread."""

    def __init__(self, on_message=None):
        self.port = config.HL7_PORT
        self.enabled = config.HL7_ENABLED
        self.thread = None
        self.loop = None
        self.server = None
        self.on_message = on_message

    def start(self):
        if not self.enabled:
            logger.info("HL7 receiver disabled")
            return

        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()
        logger.info("HL7 receiver starting on port %d", self.port)

    def _run(self):
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)

        try:
            self.loop.run_until_complete(self._serve())
            self.loop.run_forever()
        except Exception as e:
            logger.error("HL7 receiver error: %s", e)
        finally:
            self.loop.close()

    async def _serve(self):
        on_msg = self.on_message
        self.server = await self.loop.create_server(
            lambda: MLLPProtocol(on_message=on_msg),
            "0.0.0.0",
            self.port,
        )
        logger.info("HL7 MLLP server listening on port %d", self.port)

    def stop(self):
        if self.server:
            self.server.close()
        if self.loop:
            self.loop.call_soon_threadsafe(self.loop.stop)
        logger.info("HL7 receiver stopped")
