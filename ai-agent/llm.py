"""
LLM Integration — Claude Opus for natural language rule building.

Provides:
1. parse_natural_language_rule() — Convert English to routing rule JSON
2. chat() — Conversational rule building with memory
3. enhance_suggestion() — Enrich heuristic suggestions with LLM
"""

import json
import logging
from typing import Optional

import anthropic

import config

logger = logging.getLogger("llm")

# Rule schema documentation for Claude's system prompt
RULE_SCHEMA_DOCS = """
You are an expert DICOM routing rule builder for Orthanc DICOM server. You help users create routing rules using natural language.

## Rule JSON Schema

Each routing rule has these fields:
- **name** (string): Human-readable name for the rule
- **enabled** (boolean): Whether the rule is active (always true for new rules)
- **type** (string): "push" (triggers when study arrives) or "poll" (periodically queries a PACS)
- **destination** (string): Name of the destination modality to route to (must match a configured modality)
- **source** (string): For poll rules only — name of the source PACS to query
- **pollIntervalMinutes** (integer): For poll rules — how often to query (default 5)
- **sendLevel** (string): "study" (send entire study) or "series" (send matching series only)
- **filterModality** (string): Filter by DICOM modality type. Values: CT, MR, CR, XA, US, DX, PT, NM, etc. Use * as wildcard, prefix with ! to negate
- **filterStudyDescription** (string): Filter by study description text. Use * as wildcard (e.g. "*chest*"), prefix with ! to negate
- **filterSeriesDescription** (string): Filter by series description. Most useful with series sendLevel. Use * as wildcard, prefix with ! to negate
- **filterSliceThickness** (string): Filter by slice thickness in mm. Use comparison operators: "<2" (less than 2mm), "<=1.5", ">3", ">=0.5", "=1.0". Only works with series sendLevel. For thin slices (CT lung windows), use "<2". For thick slices, use ">3".
- **filterCallingAet** (string): Filter by the AE title of the sending scanner/modality. Use * as wildcard, prefix with ! to negate
- **filterCalledAet** (string): Filter by the AE title this server was called as
- **filterDateRange** (string): Filter by study date. Values: "", "today", "yesterday", "7days", "30days", "90days"
- **deleteAfterSend** (boolean): Delete the local copy after successful send

## Filter Rules
- Leave a filter field as empty string "" to match ALL values (no filter)
- Use * as wildcard: "*chest*" matches any description containing "chest"
- Prefix with ! to negate: "!CT" matches everything EXCEPT CT
- Filters are case-insensitive

## Important
- Always set "enabled": true for new rules
- Default sendLevel is "study" unless the user specifically asks for series-level routing
- Default type is "push" unless the user asks for polling/querying
- Always suggest a descriptive rule name
- deleteAfterSend defaults to false unless explicitly requested
"""


def get_client():
    """Get Anthropic client, or None if not configured."""
    if not config.LLM_ENABLED:
        return None
    return anthropic.Anthropic(api_key=config.ANTHROPIC_API_KEY)


def parse_natural_language_rule(
    prompt: str,
    available_modalities: list[dict],
    current_rules: list[dict],
) -> dict:
    """
    Convert a natural language description into a routing rule JSON.

    Args:
        prompt: User's natural language description of the rule they want
        available_modalities: List of configured DICOM modalities [{name, AET, Host, Port}]
        current_rules: List of existing routing rules for context

    Returns:
        dict with 'rule' (the JSON), 'explanation' (Claude's interpretation), 'confidence'
    """
    client = get_client()
    if not client:
        raise RuntimeError("LLM not configured — set ANTHROPIC_API_KEY")

    # Build context about available destinations
    modality_list = "\n".join(
        f"- **{m['name']}** (AET: {m.get('AET', '?')}, Host: {m.get('Host', '?')}:{m.get('Port', '?')})"
        for m in available_modalities
    ) or "No modalities configured yet."

    existing_rules_summary = ""
    if current_rules:
        existing_rules_summary = "\n\nExisting rules for context:\n" + "\n".join(
            f"- {r.get('name', '?')}: {r.get('type', 'push')} → {r.get('destination', '?')} "
            f"(modality: {r.get('filterModality', 'any')}, desc: {r.get('filterStudyDescription', 'any')})"
            for r in current_rules[:10]
        )

    system_prompt = f"""{RULE_SCHEMA_DOCS}

## Available Destinations (Modalities)
These are the configured DICOM modalities you can route to:
{modality_list}
{existing_rules_summary}

## Your Task
The user will describe a routing rule in plain English. You must:
1. Interpret their intent
2. Generate the rule JSON
3. Explain what the rule will do

Respond with a JSON object containing:
- "rule": the complete rule JSON object
- "explanation": a plain English explanation of what this rule will do (2-3 sentences)
- "confidence": a number 0-100 indicating how confident you are in your interpretation
- "warnings": an array of any warnings or clarifications needed (empty array if none)

Respond ONLY with valid JSON, no markdown code fences or other text."""

    try:
        message = client.messages.create(
            model=config.ANTHROPIC_MODEL,
            max_tokens=config.LLM_MAX_TOKENS,
            system=system_prompt,
            messages=[{"role": "user", "content": prompt}],
        )

        response_text = message.content[0].text.strip()

        # Parse response — handle potential markdown fencing
        if response_text.startswith("```"):
            lines = response_text.split("\n")
            response_text = "\n".join(lines[1:-1])

        result = json.loads(response_text)

        # Ensure required fields
        if "rule" not in result:
            raise ValueError("Claude response missing 'rule' field")

        # Apply defaults to the rule
        rule = result["rule"]
        defaults = {
            "enabled": True,
            "type": "push",
            "source": "",
            "pollIntervalMinutes": 0,
            "sendLevel": "study",
            "filterModality": "",
            "filterStudyDescription": "",
            "filterSeriesDescription": "",
            "filterSliceThickness": "",
            "filterCallingAet": "",
            "filterCalledAet": "",
            "filterDateRange": "",
            "deleteAfterSend": False,
        }
        for key, default in defaults.items():
            if key not in rule:
                rule[key] = default

        return {
            "rule": rule,
            "explanation": result.get("explanation", ""),
            "confidence": result.get("confidence", 75),
            "warnings": result.get("warnings", []),
        }

    except json.JSONDecodeError as e:
        logger.error("Failed to parse Claude response: %s", e)
        raise RuntimeError(f"Failed to parse AI response: {e}")
    except anthropic.APIError as e:
        logger.error("Anthropic API error: %s", e)
        raise RuntimeError(f"AI service error: {e}")


def chat(
    message: str,
    conversation_history: list[dict],
    available_modalities: list[dict],
    current_rules: list[dict],
) -> dict:
    """
    Conversational rule building — supports multi-turn refinement.

    Args:
        message: User's latest message
        conversation_history: Previous messages [{"role": "user"|"assistant", "content": "..."}]
        available_modalities: Available DICOM destinations
        current_rules: Existing routing rules

    Returns:
        dict with 'response' (text), 'rule' (if one was generated), 'conversation'
    """
    client = get_client()
    if not client:
        raise RuntimeError("LLM not configured — set ANTHROPIC_API_KEY")

    modality_list = "\n".join(
        f"- **{m['name']}** (AET: {m.get('AET', '?')})"
        for m in available_modalities
    ) or "No modalities configured."

    rules_summary = ""
    if current_rules:
        rules_summary = "\n\nCurrent rules:\n" + "\n".join(
            f"- {r.get('name', '?')}: → {r.get('destination', '?')}"
            for r in current_rules[:10]
        )

    system_prompt = f"""{RULE_SCHEMA_DOCS}

## Available Destinations
{modality_list}
{rules_summary}

## Conversation Mode
You are in a conversational mode helping the user build DICOM routing rules. You can:
- Help them create new rules from natural language descriptions
- Modify/refine rules based on follow-up instructions
- Explain what a rule does
- Answer questions about DICOM routing

When the user describes a rule they want, include a JSON code block with the rule. Format:
```json
{{"name": "...", "enabled": true, ...}}
```

When refining a previous rule, output the UPDATED complete rule JSON.
Be conversational and helpful. Keep responses concise."""

    # Build messages list
    messages = list(conversation_history) + [{"role": "user", "content": message}]

    try:
        response = client.messages.create(
            model=config.ANTHROPIC_MODEL,
            max_tokens=config.LLM_MAX_TOKENS,
            system=system_prompt,
            messages=messages,
        )

        response_text = response.content[0].text.strip()

        # Try to extract rule JSON from the response
        rule = None
        if "```json" in response_text:
            try:
                json_start = response_text.index("```json") + 7
                json_end = response_text.index("```", json_start)
                rule_text = response_text[json_start:json_end].strip()
                rule = json.loads(rule_text)
                # Apply defaults
                defaults = {
                    "enabled": True,
                    "type": "push",
                    "source": "",
                    "pollIntervalMinutes": 0,
                    "sendLevel": "study",
                    "filterModality": "",
                    "filterStudyDescription": "",
                    "filterSeriesDescription": "",
                    "filterCallingAet": "",
                    "filterCalledAet": "",
                    "filterDateRange": "",
                    "deleteAfterSend": False,
                }
                for key, default in defaults.items():
                    if key not in rule:
                        rule[key] = default
            except (ValueError, json.JSONDecodeError):
                pass

        # Updated conversation
        updated_history = messages + [
            {"role": "assistant", "content": response_text}
        ]

        return {
            "response": response_text,
            "rule": rule,
            "conversation": updated_history,
        }

    except anthropic.APIError as e:
        logger.error("Anthropic API error in chat: %s", e)
        raise RuntimeError(f"AI service error: {e}")
