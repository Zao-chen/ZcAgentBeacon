#!/usr/bin/env python3
import argparse
import concurrent.futures
import ipaddress
import json
import os
import re
import socket
import struct
import subprocess
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


DISCOVERY_ADDRESS = "239.255.42.99"
DISCOVERY_PORT = 42179
DEFAULT_AGENT_PORT = 42180
COMPLETION_SOUND_PATH = os.environ.get("AGENTBEACON_COMPLETION_SOUND", "/opt/agentbeacon/assets/completion.wav")
SCREEN_CONTROL_ENABLED = os.environ.get("AGENTBEACON_SCREEN_CONTROL", "1").lower() not in ("0", "false", "no", "off")
SCREEN_IDLE_SECONDS = max(10, int(os.environ.get("AGENTBEACON_SCREEN_IDLE_SECONDS", "600")))
SCREEN_DISPLAY = os.environ.get("AGENTBEACON_SCREEN_DISPLAY", ":0")
SCREEN_XAUTHORITY = os.environ.get("AGENTBEACON_SCREEN_XAUTHORITY", "/home/greatzaochen/.Xauthority")
SCAN_ENABLED = os.environ.get("AGENTBEACON_SCAN_ENABLED", "1").lower() not in ("0", "false", "no", "off")
SCAN_CIDRS = os.environ.get("AGENTBEACON_SCAN_CIDRS", "")
SCAN_INTERVAL_SECONDS = max(10, int(os.environ.get("AGENTBEACON_SCAN_INTERVAL_SECONDS", "60")))
SCAN_TIMEOUT_SECONDS = max(0.2, float(os.environ.get("AGENTBEACON_SCAN_TIMEOUT_SECONDS", "1.2")))
SCAN_WORKERS = max(4, int(os.environ.get("AGENTBEACON_SCAN_WORKERS", "32")))
PROCESS_FRESHNESS_SECONDS = 45
ACTIVE_EVENT_FRESHNESS_SECONDS = 600
ABORT_EVENT_MARKERS = ("abort", "cancel", "interrupt")
ACTIVE_STATUSES = frozenset(("thinking", "working", "tool_running", "waiting_for_user"))
MACHINE_ID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)

ACTIVITY_FIELDS = (
    "conversationId",
    "title",
    "cwd",
    "status",
    "turnId",
    "lastEventAt",
    "lastToolName",
    "lastCommand",
    "lastToolOutput",
    "lastExplanation",
    "lastMessageSummary",
    "displayDetail",
    "displaySource",
)

SECRET_PATTERNS = [
    re.compile(r"(?i)(?:\$env:|env:)?[A-Z0-9_]*(?:PASS|PASSWORD|TOKEN|SECRET|API[_-]?KEY|ACCESS[_-]?KEY)[A-Z0-9_]*\s*=\s*[\"']?[^\"'\s,;]+"),
    re.compile(r"(?i)(api[_-]?key|token|secret|password|passwd|authorization|bearer)\s*[:=]\s*[\"']?[^\"'\s,;]+"),
    re.compile(r"(?i)bearer\s+[a-z0-9._\-]{16,}"),
    re.compile(r"sk-[a-zA-Z0-9_\-]{16,}"),
    re.compile(r"tp-[a-zA-Z0-9_\-]{16,}"),
    re.compile(r"gh[pousr]_[a-zA-Z0-9_]{20,}"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
]


def now_iso():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_iso(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def mask(value, max_length=1200):
    if value is None:
        return ""
    text = str(value)
    for pattern in SECRET_PATTERNS:
        def repl(match):
            found = match.group(0)
            sep = re.search(r"=", found) or re.search(r":", found)
            if not sep:
                return "[secret]"
            return found[:sep.end()].rstrip() + " [secret]"
        text = pattern.sub(repl, text)
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) > max_length:
        text = text[:max_length] + "..."
    return text


def conversation_fingerprint(item):
    return tuple(str(item.get(field) or "") for field in ACTIVITY_FIELDS)


def normalize_cwd(cwd):
    text = str(cwd or "").replace("\\", "/").strip()
    text = re.sub(r"/+$", "", text)
    return text.lower()


def cwd_basename(cwd):
    text = str(cwd or "").replace("\\", "/").rstrip("/")
    return text.rsplit("/", 1)[-1] if text else ""


def machine_generated_title(title, conversation_id=None):
    text = str(title or "").strip()
    conv = str(conversation_id or "").strip()
    if not text:
        return True
    return bool((conv and text == conv) or MACHINE_ID_RE.fullmatch(text))


def auxiliary_process_shadow(item):
    if item and item.get("isAuxiliaryProcess"):
        return True
    if not item or not machine_generated_title(item.get("title"), item.get("conversationId")):
        return False
    if item.get("displaySource") == "process":
        return True
    return bool(item.get("lastCommand") and not item.get("lastMessageSummary") and not item.get("lastExplanation"))


def preferred_title(raw):
    title = raw.get("title") or raw.get("conversationId") or "Untitled"
    if machine_generated_title(title, raw.get("conversationId")):
        return cwd_basename(raw.get("cwd")) or "未命名会话"
    return title


def merge_auxiliary_shadow(target, shadow):
    if shadow.get("status") not in ACTIVE_STATUSES:
        return False
    before = conversation_fingerprint(target)
    shadow_at = parse_iso(shadow.get("lastEventAt")) or 0
    target_at = parse_iso(target.get("lastEventAt")) or 0
    if shadow.get("status") == "tool_running" or target.get("status") not in ACTIVE_STATUSES:
        target["status"] = shadow.get("status")
    if shadow.get("turnId"):
        target["turnId"] = shadow.get("turnId")
    if shadow_at >= target_at and shadow.get("lastEventAt"):
        target["lastEventAt"] = shadow.get("lastEventAt")
        for field in ("lastToolName", "lastCommand", "displayDetail", "displaySource"):
            if shadow.get(field):
                target[field] = shadow.get(field)
    elif not target.get("displayDetail") and shadow.get("displayDetail"):
        target["displayDetail"] = shadow.get("displayDetail")
        target["displaySource"] = shadow.get("displaySource")
    folded = target.setdefault("foldedAuxiliaryIds", [])
    if shadow.get("conversationId") and shadow.get("conversationId") not in folded:
        folded.append(shadow.get("conversationId"))
    return before != conversation_fingerprint(target)


def fold_auxiliary_conversations(items):
    visible = []
    by_cwd = {}
    shadows = []
    for item in items:
        if auxiliary_process_shadow(item):
            shadows.append(item)
            continue
        visible.append(item)
        cwd_key = normalize_cwd(item.get("cwd"))
        if cwd_key:
            by_cwd.setdefault(cwd_key, []).append(item)

    for shadow in shadows:
        cwd_key = normalize_cwd(shadow.get("cwd"))
        peers = by_cwd.get(cwd_key) or []
        if not peers:
            if shadow.get("status") in ACTIVE_STATUSES:
                fallback = dict(shadow)
                fallback["suppressCompletion"] = True
                visible.append(fallback)
            continue
        if shadow.get("status") not in ACTIVE_STATUSES:
            continue
        target = max(peers, key=lambda item: parse_iso(item.get("lastEventAt")) or 0)
        merge_auxiliary_shadow(target, shadow)

    visible.sort(key=lambda item: parse_iso(item.get("lastEventAt")) or 0, reverse=True)
    return visible


def is_abort_event(event_type):
    value = str(event_type or "").lower()
    return any(marker in value for marker in ABORT_EVENT_MARKERS)


def event_ts(event):
    return parse_iso(event.get("eventAt") or event.get("completedAt") or event.get("updatedAt"))


def set_display(activity, detail, event_at, source):
    if not detail:
        return
    if activity.get("displayAt") and event_at and event_at < activity["displayAt"]:
        return
    activity["displayDetail"] = mask(detail, 360)
    activity["displayAt"] = event_at
    activity["displaySource"] = source


def note_response(activity, kind, event_at, turn_id):
    completed = activity["completedTurnIds"]
    if turn_id and str(turn_id) not in completed:
        activity["turnId"] = turn_id
    activity["lastTerminalStatus"] = None
    if event_at:
        activity["lastResponseAt"] = event_at
        activity["lastActivityKind"] = kind


def finish_signal_turn(activity, turn_id, event_at, completed_at, terminal_status):
    activity["hasOpenTurn"] = False
    activity["pendingCalls"].clear()
    if turn_id:
        activity["completedTurnIds"].add(str(turn_id))
    if completed_at and event_at:
        completed_at = max(completed_at, event_at)
    activity["lastTaskCompleteAt"] = completed_at or event_at
    activity["lastTerminalStatus"] = terminal_status
    activity["lastActivityKind"] = terminal_status


def activity_from_signals(raw):
    activity = {
        "hasOpenTurn": False,
        "pendingCalls": set(),
        "completedTurnIds": set(),
        "turnId": None,
        "lastEventAt": None,
        "lastResponseAt": None,
        "lastTaskCompleteAt": None,
        "lastTerminalStatus": None,
        "lastActivityKind": None,
        "lastToolName": None,
        "lastCommand": None,
        "lastToolOutput": None,
        "lastExplanation": None,
        "lastMessageSummary": None,
        "displayDetail": None,
        "displaySource": None,
        "displayAt": None,
    }
    events = raw.get("events") or []
    events = sorted([event for event in events if isinstance(event, dict)], key=lambda item: event_ts(item) or 0)
    for event in events:
        kind = event.get("kind") or ""
        event_type = event.get("type") or ""
        event_at = event_ts(event)
        if event_at and (not activity["lastEventAt"] or event_at > activity["lastEventAt"]):
            activity["lastEventAt"] = event_at
        turn_id = event.get("turnId")
        turn_key = str(turn_id) if turn_id else None
        if kind == "turn_start" or event_type == "task_started":
            activity["hasOpenTurn"] = True
            activity["turnId"] = turn_id
            if turn_key:
                activity["completedTurnIds"].discard(turn_key)
            activity["lastActivityKind"] = "task_started"
        elif kind == "turn_end" or event_type == "task_complete" or is_abort_event(event_type):
            terminal_status = event.get("terminalStatus") or ("interrupted" if is_abort_event(event_type) else "complete")
            completed_at = parse_iso(event.get("completedAt")) or event_at
            finish_signal_turn(activity, turn_id, event_at, completed_at, "interrupted" if terminal_status == "interrupted" else "idle")
            if event.get("messageSummary"):
                activity["lastMessageSummary"] = mask(event.get("messageSummary"))
                set_display(activity, event.get("messageSummary"), activity["lastTaskCompleteAt"], "interrupted" if terminal_status == "interrupted" else "complete")
        elif kind == "tool_call":
            if turn_key and turn_key in activity["completedTurnIds"]:
                continue
            note_response(activity, "function_call", event_at, turn_id)
            call_id = event.get("callId")
            if call_id:
                activity["pendingCalls"].add(str(call_id))
            tool_name = str(event.get("toolName") or "tool")
            explanation = event.get("explanation")
            if explanation:
                activity["lastExplanation"] = mask(explanation, 360)
                activity["lastMessageSummary"] = activity["lastExplanation"]
                activity["lastToolName"] = "explanation" if tool_name == "update_plan" else tool_name
                activity["lastCommand"] = ""
                set_display(activity, explanation, event_at, "explanation")
            else:
                activity["lastToolName"] = tool_name
                activity["lastCommand"] = mask(event.get("argumentsSummary"))
                set_display(activity, activity["lastCommand"], event_at, "command")
        elif kind == "tool_output":
            if turn_key and turn_key in activity["completedTurnIds"]:
                continue
            note_response(activity, "function_call_output", event_at, turn_id)
            call_id = event.get("callId")
            if call_id:
                activity["pendingCalls"].discard(str(call_id))
            activity["lastToolOutput"] = mask(event.get("outputSummary"))
            set_display(activity, activity["lastToolOutput"], event_at, "output")
        elif kind == "assistant_message":
            if turn_key and turn_key in activity["completedTurnIds"]:
                continue
            note_response(activity, "agent_message", event_at, turn_id)
            activity["lastMessageSummary"] = mask(event.get("messageSummary"))
            set_display(activity, activity["lastMessageSummary"], event_at, "message")
        elif kind == "message":
            if turn_key and turn_key in activity["completedTurnIds"]:
                continue
            if event.get("role") in ("user", "developer", "system"):
                continue
            if event.get("messageSummary"):
                note_response(activity, "message", event_at, turn_id)
                activity["lastMessageSummary"] = mask(event.get("messageSummary"))
                set_display(activity, activity["lastMessageSummary"], event_at, "message")
        elif kind == "reasoning":
            if turn_key and turn_key in activity["completedTurnIds"]:
                continue
            note_response(activity, "reasoning", event_at, turn_id)
            if event.get("explanation"):
                activity["lastExplanation"] = mask(event.get("explanation"), 360)
                activity["lastMessageSummary"] = activity["lastExplanation"]
                set_display(activity, activity["lastExplanation"], event_at, "explanation")
            elif event.get("messageSummary"):
                activity["lastMessageSummary"] = mask(event.get("messageSummary"))
                set_display(activity, activity["lastMessageSummary"], event_at, "reasoning")
            elif not activity["displayDetail"]:
                set_display(activity, "正在思考...", event_at, "reasoning")
    return activity


def conversation_from_raw(raw):
    activity = activity_from_signals(raw)
    now = time.time()
    for proc in raw.get("processes") or []:
        if not isinstance(proc, dict):
            continue
        proc_time = parse_iso(proc.get("updatedAt")) or ((proc.get("updatedAtMs") or 0) / 1000)
        if not proc_time or proc_time < now - PROCESS_FRESHNESS_SECONDS:
            continue
        proc_turn = str(proc.get("turnId")) if proc.get("turnId") else None
        if proc_turn and proc_turn in activity["completedTurnIds"]:
            continue
        if activity["lastTaskCompleteAt"] and activity["lastTaskCompleteAt"] >= proc_time:
            continue
        activity["pendingCalls"].add("process:%s" % (proc_turn or proc_time))
        if proc.get("turnId"):
            activity["turnId"] = proc.get("turnId")
        activity["lastToolName"] = activity["lastToolName"] or "tool"
        activity["lastCommand"] = activity["lastCommand"] or mask(proc.get("command"))
        activity["lastResponseAt"] = max(activity["lastResponseAt"] or 0, proc_time)
        activity["lastEventAt"] = max(activity["lastEventAt"] or 0, proc_time)
        set_display(activity, activity["lastCommand"], proc_time, "process")
    active = activity["hasOpenTurn"] or bool(activity["pendingCalls"])
    if not active:
        active = bool(
            activity["lastResponseAt"]
            and now - activity["lastResponseAt"] <= ACTIVE_EVENT_FRESHNESS_SECONDS
            and (not activity["lastTaskCompleteAt"] or activity["lastResponseAt"] > activity["lastTaskCompleteAt"])
        )
    if active:
        status = "tool_running" if activity["pendingCalls"] else "thinking"
    elif (
        activity["lastTerminalStatus"] == "interrupted"
        and activity["lastTaskCompleteAt"]
        and now - activity["lastTaskCompleteAt"] <= ACTIVE_EVENT_FRESHNESS_SECONDS
    ):
        status = "interrupted"
    else:
        status = "idle"
    event_candidates = [
        activity["lastResponseAt"],
        activity["lastTaskCompleteAt"],
        activity["lastEventAt"],
        parse_iso(raw.get("updatedAt")),
    ]
    event_at = max([value for value in event_candidates if value], default=None)
    if not event_at:
        return None
    if event_at < now - ACTIVE_EVENT_FRESHNESS_SECONDS and status == "idle":
        return None
    is_auxiliary_process = bool(
        machine_generated_title(raw.get("title"), raw.get("conversationId"))
        and raw.get("processes")
        and not raw.get("events")
    )
    return {
        "conversationId": raw.get("conversationId"),
        "title": preferred_title(raw),
        "cwd": raw.get("cwd") or "",
        "status": status,
        "turnId": activity["turnId"],
        "lastEventAt": iso_from_ts(event_at),
        "lastToolName": activity["lastToolName"],
        "lastCommand": activity["lastCommand"],
        "lastToolOutput": activity["lastToolOutput"],
        "lastExplanation": activity["lastExplanation"],
        "lastMessageSummary": activity["lastMessageSummary"],
        "displayDetail": activity["displayDetail"],
        "displaySource": activity["displaySource"],
        "detailLevel": "signals",
        "isAuxiliaryProcess": is_auxiliary_process,
        "suppressCompletion": is_auxiliary_process,
    }


def conversations_from_raw(raw_items):
    out = []
    for raw in raw_items or []:
        if not isinstance(raw, dict) or not raw.get("conversationId"):
            continue
        item = conversation_from_raw(raw)
        if item:
            out.append(item)
    return fold_auxiliary_conversations(out)


class DashboardState:
    def __init__(self):
        self.lock = threading.RLock()
        self.devices = {}
        self.conversation_history = {}
        self.settings = {
            "pollIntervalMs": 2000,
            "staleAfterSeconds": 15,
            "offlineAfterSeconds": 45,
            "showDetails": True,
        }
        self.lastActivityAt = time.time()
        self.lastActivityReason = "startup"

    def mark_activity(self, reason):
        self.lastActivityAt = time.time()
        self.lastActivityReason = reason

    def add_manual_device(self, host, port=DEFAULT_AGENT_PORT, hostname=None):
        return self.upsert_device(host, port, hostname, True, "manual")

    def add_scanned_device(self, host, port=DEFAULT_AGENT_PORT, hostname=None):
        return self.upsert_device(host, port, hostname, False, "scan")

    def upsert_device(self, host, port=DEFAULT_AGENT_PORT, hostname=None, manual=False, prefix="manual"):
        port = int(port)
        with self.lock:
            for device in self.devices.values():
                if device.get("host") == host and int(device.get("port") or 0) == port:
                    if hostname:
                        device["hostname"] = hostname
                    device["manual"] = bool(device.get("manual") or manual)
                    return device["key"]
            key = "%s:%s:%s" % (prefix, host, port)
            self.devices[key] = {
                "key": key,
                "nodeId": key,
                "hostname": hostname or host,
                "host": host,
                "port": port,
                "os": "",
                "manual": bool(manual),
                "lastBeaconAt": None,
                "lastSeenAt": None,
                "snapshot": None,
                "lastError": None,
            }
            return key

    def handle_beacon(self, payload, address):
        if payload.get("kind") != "agentbeacon.agent":
            return
        port = int(payload.get("port") or DEFAULT_AGENT_PORT)
        host = address[0]
        key = self.upsert_device(host, port, payload.get("hostname") or host, False, "beacon")
        with self.lock:
            device = self.devices.get(key)
            if device is None:
                return
            device["host"] = host
            device["port"] = port
            device["hostname"] = payload.get("hostname") or device["hostname"]
            device["os"] = payload.get("os") or device["os"]
            device["lastBeaconAt"] = time.time()

    def poll_all(self):
        with self.lock:
            devices = list(self.devices.values())
        threads = []
        for device in devices:
            thread = threading.Thread(target=self.poll_device, args=(device["key"],), daemon=True)
            thread.start()
            threads.append(thread)
        for thread in threads:
            thread.join(timeout=4)

    def poll_device(self, key):
        with self.lock:
            device = self.devices.get(key)
            if not device:
                return
            host = device["host"]
            port = int(device["port"])
        url = "http://%s:%s/status" % (host, port)
        try:
            with urllib.request.urlopen(url, timeout=3) as response:
                body = response.read().decode("utf-8", "replace")
            snapshot = json.loads(body)
            with self.lock:
                device = self.devices.get(key)
                if not device:
                    return
                device["nodeId"] = snapshot.get("nodeId") or device["nodeId"]
                device["hostname"] = snapshot.get("hostname") or device["hostname"]
                device["os"] = snapshot.get("os") or device["os"]
                device["snapshot"] = snapshot
                device["lastSeenAt"] = time.time()
                device["lastError"] = None
                self._merge_conversations(device, snapshot)
        except (OSError, urllib.error.URLError, json.JSONDecodeError) as error:
            with self.lock:
                device = self.devices.get(key)
                if device:
                    device["lastError"] = str(error)

    def update_settings(self, incoming):
        with self.lock:
            for key in ("pollIntervalMs", "staleAfterSeconds", "offlineAfterSeconds"):
                if key in incoming:
                    self.settings[key] = max(1, int(incoming[key]))
            if "showDetails" in incoming:
                self.settings["showDetails"] = bool(incoming["showDetails"])
            return dict(self.settings)

    def snapshot(self):
        with self.lock:
            now = time.time()
            device_views = []
            for device in self.devices.values():
                status = self._device_status(device, now)
                snapshot = device.get("snapshot") or {}
                items = snapshot.get("rawConversations") or []
                device_views.append({
                    "nodeId": device["nodeId"],
                    "hostname": device["hostname"],
                    "host": device["host"],
                    "port": device["port"],
                    "os": device["os"],
                    "status": status,
                    "codexRunning": bool(snapshot.get("codexRunning")),
                    "conversationCount": len(items),
                    "lastSeenAt": iso_from_ts(device.get("lastSeenAt")),
                    "lastBeaconAt": iso_from_ts(device.get("lastBeaconAt")),
                    "lastError": device.get("lastError"),
                    "manual": bool(device.get("manual")),
                })
            device_status_by_id = {item["nodeId"]: item["status"] for item in device_views}
            human_cwds_by_device = {}
            for item in self.conversation_history.values():
                if auxiliary_process_shadow(item):
                    continue
                cwd_key = normalize_cwd(item.get("cwd"))
                if cwd_key:
                    human_cwds_by_device.setdefault(item.get("deviceId"), set()).add(cwd_key)
            conversations = []
            for item in self.conversation_history.values():
                cwd_key = normalize_cwd(item.get("cwd"))
                if auxiliary_process_shadow(item) and (
                    item.get("status") not in ACTIVE_STATUSES
                    or cwd_key in human_cwds_by_device.get(item.get("deviceId"), set())
                ):
                    continue
                copied = dict(item)
                device_status = device_status_by_id.get(copied.get("deviceId"))
                if device_status in ("stale", "error_offline"):
                    copied["status"] = device_status
                conversations.append(copied)
            conversations.sort(
                key=lambda item: parse_iso(item.get("lastEventAt") or item.get("seenAt") or item.get("completedAt")) or 0,
                reverse=True,
            )
            device_views.sort(key=lambda item: item["hostname"])
            return {
                "generatedAt": now_iso(),
                "devices": device_views,
                "conversations": conversations,
                "screen": {
                    "controlEnabled": SCREEN_CONTROL_ENABLED,
                    "idleAfterSeconds": SCREEN_IDLE_SECONDS,
                    "lastActivityAt": iso_from_ts(self.lastActivityAt),
                    "lastActivityReason": self.lastActivityReason,
                },
            }

    def _merge_conversations(self, device, snapshot):
        active_ids = set()
        items = conversations_from_raw(snapshot.get("rawConversations") or [])
        for item in items:
            conversation_id = item.get("conversationId")
            if not conversation_id:
                continue
            if auxiliary_process_shadow(item):
                peer = self._history_peer_for_shadow(device["nodeId"], item)
                if peer:
                    peer_key, peer_item = peer
                    if merge_auxiliary_shadow(peer_item, item):
                        peer_item["seenAt"] = now_iso()
                        self.mark_activity("conversation_changed")
                    if item.get("status") in ACTIVE_STATUSES:
                        active_ids.add(peer_key)
                    continue
            key = "%s:%s" % (device["nodeId"], conversation_id)
            active_ids.add(key)
            copied = dict(item)
            copied["deviceId"] = device["nodeId"]
            copied["deviceName"] = device["hostname"]
            copied["deviceHost"] = "%s:%s" % (device["host"], device["port"])
            copied["seenAt"] = now_iso()
            for field in ("title", "cwd", "lastCommand", "lastToolOutput", "lastExplanation", "lastMessageSummary", "displayDetail", "displaySource"):
                if field in copied:
                    copied[field] = mask(copied.get(field))
            previous = self.conversation_history.get(key)
            if previous is None or conversation_fingerprint(previous) != conversation_fingerprint(copied):
                self.mark_activity("conversation_changed")
            self.conversation_history[key] = copied
        self._purge_auxiliary_history(device["nodeId"])

        for key, item in list(self.conversation_history.items()):
            if item.get("deviceId") != device["nodeId"] or key in active_ids:
                continue
            if item.get("status") in ("thinking", "working", "tool_running", "waiting_for_user"):
                item["status"] = "idle"
                item["completedAt"] = now_iso()
                self.mark_activity("conversation_completed")

    def _purge_auxiliary_history(self, device_id):
        human_cwds = set()
        for item in self.conversation_history.values():
            if item.get("deviceId") != device_id or auxiliary_process_shadow(item):
                continue
            cwd_key = normalize_cwd(item.get("cwd"))
            if cwd_key:
                human_cwds.add(cwd_key)
        for key, item in list(self.conversation_history.items()):
            if item.get("deviceId") != device_id or not auxiliary_process_shadow(item):
                continue
            cwd_key = normalize_cwd(item.get("cwd"))
            if item.get("status") not in ACTIVE_STATUSES or cwd_key in human_cwds:
                del self.conversation_history[key]

    def _history_peer_for_shadow(self, device_id, shadow):
        cwd_key = normalize_cwd(shadow.get("cwd"))
        if not cwd_key:
            return None
        candidates = []
        for key, item in self.conversation_history.items():
            if item.get("deviceId") != device_id or auxiliary_process_shadow(item):
                continue
            if normalize_cwd(item.get("cwd")) != cwd_key:
                continue
            candidates.append((parse_iso(item.get("lastEventAt") or item.get("seenAt")) or 0, key, item))
        if not candidates:
            return None
        _, key, item = max(candidates, key=lambda candidate: candidate[0])
        return key, item

    def _device_status(self, device, now):
        last_seen = device.get("lastSeenAt")
        if not last_seen:
            return "error_offline"
        age = now - last_seen
        if age >= int(self.settings["offlineAfterSeconds"]):
            return "error_offline"
        if age >= int(self.settings["staleAfterSeconds"]):
            return "stale"
        return "idle"


def iso_from_ts(value):
    if not value:
        return None
    return datetime.fromtimestamp(value, timezone.utc).isoformat().replace("+00:00", "Z")


def discovery_loop(state, address=DISCOVERY_ADDRESS, port=DISCOVERY_PORT):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("", port))
    group = socket.inet_aton(address)
    membership = group + struct.pack("=I", socket.INADDR_ANY)
    try:
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, membership)
    except OSError:
        pass
    while True:
        try:
            data, sender = sock.recvfrom(65535)
            payload = json.loads(data.decode("utf-8", "replace"))
            if isinstance(payload, dict):
                state.handle_beacon(payload, sender)
        except Exception:
            continue


def poll_loop(state):
    while True:
        state.poll_all()
        with state.lock:
            delay = max(1, int(state.settings["pollIntervalMs"]) / 1000)
        time.sleep(delay)


def local_scan_cidrs():
    if SCAN_CIDRS.strip():
        return [item.strip() for item in SCAN_CIDRS.split(",") if item.strip()]
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.connect(("8.8.8.8", 80))
        ip = sock.getsockname()[0]
        sock.close()
        if not ip.startswith("127."):
            parts = ip.split(".")
            return ["%s.%s.%s.0/24" % (parts[0], parts[1], parts[2])]
    except OSError:
        pass
    return []


def probe_agent(host, port=DEFAULT_AGENT_PORT):
    base = "http://%s:%s" % (host, port)
    try:
        with urllib.request.urlopen(base + "/health", timeout=SCAN_TIMEOUT_SECONDS) as response:
            if response.status >= 400:
                return None
        with urllib.request.urlopen(base + "/status", timeout=max(2.0, SCAN_TIMEOUT_SECONDS)) as response:
            data = json.loads(response.read().decode("utf-8", "replace"))
        if not isinstance(data, dict) or "rawConversations" not in data:
            return None
        return {
            "host": host,
            "port": port,
            "hostname": data.get("hostname") or host,
        }
    except Exception:
        return None


def scan_once(state):
    cidrs = local_scan_cidrs()
    hosts = []
    for cidr in cidrs:
        try:
            hosts.extend(str(host) for host in ipaddress.ip_network(cidr, strict=False).hosts())
        except ValueError:
            continue
    if not hosts:
        return
    found = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=SCAN_WORKERS) as executor:
        futures = [executor.submit(probe_agent, host) for host in hosts]
        for future in concurrent.futures.as_completed(futures):
            item = future.result()
            if item:
                found.append(item)
    for item in found:
        state.add_scanned_device(item["host"], item["port"], item["hostname"])
    if found:
        print("AgentBeacon scan found: %s" % ", ".join("%s:%s" % (item["host"], item["port"]) for item in found), flush=True)


def scan_loop(state):
    if not SCAN_ENABLED:
        print("AgentBeacon LAN scan disabled", flush=True)
        return
    while True:
        scan_once(state)
        time.sleep(SCAN_INTERVAL_SECONDS)


class ScreenController:
    def __init__(self, state):
        self.state = state
        self.blanked = False
        self.blanked_at = 0

    def run(self):
        if not SCREEN_CONTROL_ENABLED:
            print("AgentBeacon screen control disabled", flush=True)
            return
        self.wake("startup")
        while True:
            time.sleep(5)
            with self.state.lock:
                last_activity_at = self.state.lastActivityAt
                idle_for = time.time() - last_activity_at
                reason = self.state.lastActivityReason
            if self.blanked:
                if last_activity_at > self.blanked_at:
                    self.wake(reason)
            elif idle_for >= SCREEN_IDLE_SECONDS:
                self.blank(idle_for)

    def blank(self, idle_for):
        self._xset("s", "blank")
        self._xset("s", "activate")
        self._xset("+dpms")
        self._xset("dpms", "force", "off")
        self.blanked = True
        self.blanked_at = time.time()
        print("AgentBeacon screen blanked after %.0fs idle" % idle_for, flush=True)

    def wake(self, reason):
        self._xset("dpms", "force", "on")
        self._xset("s", "reset")
        self._xset("-dpms")
        self._xset("s", "off")
        if self.blanked:
            print("AgentBeacon screen woke for %s" % reason, flush=True)
        self.blanked = False

    def _xset(self, *args):
        env = dict(os.environ)
        env["DISPLAY"] = SCREEN_DISPLAY
        env["XAUTHORITY"] = SCREEN_XAUTHORITY
        try:
            subprocess.run(
                ["/usr/bin/xset", *args],
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=3,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as error:
            print("AgentBeacon screen control error: %s" % error, flush=True)


def screen_loop(state):
    ScreenController(state).run()


def make_handler(state):
    class Handler(BaseHTTPRequestHandler):
        server_version = "AgentBeaconPi/0.1"

        def do_OPTIONS(self):
            self._headers(204)
            self.end_headers()

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path == "/health":
                self._json({"ok": True})
            elif path == "/api/conversations":
                self._json(state.snapshot())
            elif path == "/api/devices":
                self._json({"devices": state.snapshot()["devices"]})
            elif path == "/api/settings":
                with state.lock:
                    self._json(dict(state.settings))
            elif path == "/assets/completion.wav":
                self._file(COMPLETION_SOUND_PATH, "audio/wav")
            else:
                self._html(INDEX_HTML)

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", "0") or "0"))
            try:
                payload = json.loads(body.decode("utf-8") or "{}")
            except json.JSONDecodeError:
                self._json({"error": "invalid_json"}, status=400)
                return
            if self.path == "/api/devices":
                host = str(payload.get("host") or "").strip()
                port = int(payload.get("port") or DEFAULT_AGENT_PORT)
                if not host:
                    self._json({"error": "invalid_device"}, status=400)
                    return
                state.add_manual_device(host, port, payload.get("hostname"))
                state.poll_all()
                self._json(state.snapshot(), status=201)
            elif self.path == "/api/settings":
                self._json(state.update_settings(payload))
            else:
                self._json({"error": "not_found"}, status=404)

        def log_message(self, fmt, *args):
            return

        def _headers(self, status=200, content_type="application/json"):
            self.send_response(status)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.send_header("Cache-Control", "no-store, max-age=0")
            self.send_header("Content-Type", content_type)

        def _json(self, payload, status=200):
            encoded = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self._headers(status, "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def _html(self, text):
            encoded = text.encode("utf-8")
            self._headers(200, "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def _file(self, path, content_type):
            if not os.path.exists(path):
                self._json({"error": "not_found"}, status=404)
                return
            with open(path, "rb") as handle:
                data = handle.read()
            self._headers(200, content_type)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    return Handler


INDEX_HTML = r"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Codex 会话</title>
<style>
:root{color-scheme:light;--bg:#f5f6f7;--panel:#fff;--ink:#111820;--muted:#626d78;--line:#d9dee4;--teal:#087f8c;--green:#2f7d32;--amber:#b15f00;--red:#b3261e;--blue:#3366cc;--done:#66717d}
*{box-sizing:border-box}html,body{min-height:100%}body{margin:0;overflow-x:hidden;background:var(--bg);color:var(--ink);font:14px/1.35 system-ui,-apple-system,Segoe UI,sans-serif;letter-spacing:0}.screen{width:calc(100vw - 38px);margin-left:8px}header{position:sticky;top:0;z-index:2;background:rgba(245,246,247,.96);border-bottom:1px solid var(--line);padding:8px 0}.topbar{height:48px;display:flex;align-items:center;gap:10px}.brand{min-width:0;flex:1;font-size:21px;font-weight:900;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.stats{display:flex;gap:5px;align-items:center}.stat{width:56px;height:40px;background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:4px 5px;display:grid;grid-template-columns:5px 1fr;gap:5px;align-items:center}.bar{width:5px;height:26px;border-radius:3px}.stat strong{display:block;font-size:17px;line-height:17px}.stat span{display:block;color:var(--muted);font-size:11px;line-height:14px}.main{padding:10px 0}.list{display:flex;flex-direction:column;gap:7px}.listrow{min-height:70px;background:var(--panel);border:1px solid var(--line);border-left:7px solid var(--accent);border-radius:8px;padding:8px 8px;display:grid;grid-template-columns:66px minmax(0,1fr) 44px;gap:8px;align-items:center;box-shadow:0 1px 2px #0000000d}.listrow.state-thinking,.listrow.state-working{animation:rowPulse 1.8s ease-in-out infinite}.listrow.state-tool_running{background-image:linear-gradient(90deg,var(--panel),var(--soft),var(--panel));background-size:220% 100%;animation:toolSweep 2s linear infinite}.listrow.state-stale,.listrow.state-error_offline{animation:warnPulse 2.4s ease-in-out infinite}.statuspill{height:35px;border-radius:8px;border:1px solid var(--accent);color:var(--accent);display:flex;justify-content:center;align-items:center;gap:5px;font-size:13px;font-weight:900}.motion{width:8px;height:8px;border-radius:50%;background:currentColor;flex:none}.state-thinking .motion,.state-working .motion{animation:dotPulse 1s ease-in-out infinite}.state-tool_running .motion{width:12px;height:12px;background:transparent;border:2px solid currentColor;border-top-color:transparent;animation:spin .75s linear infinite}.state-idle .motion{opacity:.5}.rowmain{min-width:0}.rowhead{display:flex;align-items:center;gap:7px;min-width:0}.device{flex:0 0 auto;max-width:100px;border:1px solid var(--line);border-radius:8px;padding:2px 6px;color:var(--muted);font-size:11px;font-weight:800;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;background:#f9fafb}.rowtitle{flex:1;min-width:0;font-size:16px;font-weight:900;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.rowmeta{margin-top:3px;color:var(--muted);font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.rowtime{text-align:right;color:var(--muted);font-size:12px;font-weight:800;white-space:nowrap}.empty{display:grid;place-items:center;min-height:230px;text-align:center;color:var(--muted)}.empty h2{margin:0 0 6px;color:var(--ink);font-size:20px}.empty p{margin:0}@keyframes spin{to{transform:rotate(360deg)}}@keyframes dotPulse{0%,100%{transform:scale(.8);opacity:.5}50%{transform:scale(1.25);opacity:1}}@keyframes rowPulse{0%,100%{box-shadow:0 0 0 0 color-mix(in srgb,var(--accent) 0%,transparent)}50%{box-shadow:0 0 0 3px color-mix(in srgb,var(--accent) 18%,transparent)}}@keyframes toolSweep{from{background-position:120% 0}to{background-position:-120% 0}}@keyframes warnPulse{0%,100%{filter:saturate(1)}50%{filter:saturate(1.35)}}@media(max-width:520px){.screen{width:calc(100vw - 38px)}header{padding:7px 0}.topbar{gap:7px}.brand{font-size:18px}.stat{width:50px;height:38px;padding:4px}.stat strong{font-size:16px}.stat span{font-size:10px}.listrow{grid-template-columns:58px minmax(0,1fr) 38px;gap:7px;padding:7px}.statuspill{font-size:12px}.device{max-width:82px;font-size:10px}.rowtitle{font-size:15px}.rowmeta{font-size:11px}.rowtime{font-size:11px}}
</style>
<style>
.notices{position:fixed;right:38px;bottom:10px;z-index:5;display:flex;flex-direction:column;gap:6px;width:min(330px,calc(100vw - 54px));pointer-events:none}.notice{background:#111820;color:#fff;border:1px solid #00000033;border-radius:8px;padding:8px 10px;box-shadow:0 10px 24px #0000002e;animation:noticeIn .22s ease-out both}.notice strong{display:block;font-size:14px;line-height:18px}.notice span{display:block;margin-top:2px;color:#dfe5ea;font-size:12px;line-height:16px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.listrow.just-completed{animation:doneFlash 1.2s ease-out 2}@keyframes noticeIn{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:translateY(0)}}@keyframes doneFlash{0%{box-shadow:0 0 0 0 #2f7d3200}35%{box-shadow:0 0 0 4px #2f7d3233}100%{box-shadow:0 1px 2px #0000000d}}@media(max-width:520px){.notices{left:8px;right:38px;bottom:8px;width:auto}.notice{padding:7px 9px}.notice strong{font-size:13px}.notice span{font-size:11px}}
</style>
<style>
:root{--soft-tool:#fff4de;--soft-active:#e7f7f8;--soft-wait:#edf2ff;--soft-warn:#fff4de;--soft-error:#ffecea;--soft-done:#f4f6f8}html[data-theme=dark]{color-scheme:dark;--bg:#0f141b;--panel:#151c24;--ink:#eef3f8;--muted:#9aa7b4;--line:#2b3743;--teal:#36c3d0;--green:#63b66b;--amber:#eba23d;--red:#ff746b;--blue:#88a9ff;--done:#a3afbb;--soft-tool:#352718;--soft-active:#102c31;--soft-wait:#17243c;--soft-warn:#352718;--soft-error:#3a1c1b;--soft-done:#202832}html[data-theme=dark] header{background:rgba(15,20,27,.96)}html[data-theme=dark] .device{background:#1b242e}html[data-theme=dark] .notice{background:#edf2f7;color:#111820;border-color:#ffffff22}html[data-theme=dark] .notice span{color:#44515e}body,.listrow,.stat,.device,header{transition:background-color .25s ease,border-color .25s ease,color .25s ease}
</style>
</head>
<body>
<div class="screen">
<header>
  <div class="topbar">
    <div class="brand">Codex 会话</div>
    <div class="stats">
      <div class="stat"><div class="bar" style="background:var(--teal)"></div><div><strong id="active">0</strong><span>活跃</span></div></div>
      <div class="stat"><div class="bar" style="background:var(--green)"></div><div><strong id="deviceCount">0</strong><span>设备</span></div></div>
    </div>
  </div>
</header>
<main id="main" class="main"></main>
</div>
<div id="notices" class="notices"></div>
<audio id="completeSound" src="/assets/completion.wav" preload="auto"></audio>
<script>
let snapshot={devices:[],conversations:[]};
const activeStatuses=new Set(['thinking','working','tool_running']);
const completionFromStatuses=new Set(['thinking','working','tool_running','waiting_for_user']);
const knownStatuses=new Map();
const recentCompletions=new Map();
const notifiedCompletions=new Set();
let hasLoaded=false;
const statusInfo=s=>({
  tool_running:['工具','var(--amber)','var(--soft-tool)'],
  thinking:['思考','var(--teal)','var(--soft-active)'],
  working:['运行','var(--teal)','var(--soft-active)'],
  waiting_for_user:['等待','var(--blue)','var(--soft-wait)'],
  interrupted:['中断','var(--red)','var(--soft-error)'],
  stale:['过期','var(--amber)','var(--soft-warn)'],
  error_offline:['离线','var(--red)','var(--soft-error)'],
  idle:['完成','var(--done)','var(--soft-done)']
}[s]||[s||'未知','var(--done)','var(--soft-done)']);
function autoDark(){let media=false;try{media=matchMedia('(prefers-color-scheme: dark)').matches}catch(error){}let h=new Date().getHours();return media||h>=19||h<7}
function updateTheme(){document.documentElement.dataset.theme=autoDark()?'dark':'light'}
updateTheme();setInterval(updateTheme,60000);try{let query=matchMedia('(prefers-color-scheme: dark)');if(query.addEventListener)query.addEventListener('change',updateTheme);else if(query.addListener)query.addListener(updateTheme)}catch(error){}
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function basename(path){let p=String(path||'').replace(/\\/g,'/').split('/').filter(Boolean);return p.pop()||''}
function conversationKey(c){return [c.deviceId||c.deviceHost||c.deviceName||'device',c.conversationId||c.turnId||c.title||'conversation'].join(':')}
function completionKey(c){return conversationKey(c)+':'+(c.completedAt||c.lastEventAt||c.seenAt||'done')}
function timeOf(item){return Date.parse(item.lastEventAt||item.seenAt||item.completedAt||0)||0}
function rel(t){let ts=Date.parse(t||0);if(!ts)return'未知';let d=(Date.now()-ts)/1000;if(d<15)return'刚刚';if(d<60)return Math.floor(d)+'秒前';if(d<3600)return Math.floor(d/60)+'分钟前';if(d<86400)return Math.floor(d/3600)+'小时前';return Math.floor(d/86400)+'天前'}
function detail(c){let parts=[];let cwd=basename(c.cwd);if(c.displayDetail)parts.push(c.displayDetail);else if(c.lastExplanation)parts.push(c.lastExplanation);else{if(c.lastToolName)parts.push(c.lastToolName);if(c.lastCommand)parts.push(c.lastCommand);else if(c.lastMessageSummary)parts.push(c.lastMessageSummary)}if(cwd)parts.push(cwd);return parts.join(' / ').slice(0,220)}
async function load(){try{let r=await fetch('/api/conversations',{cache:'no-store'});snapshot=await r.json();render()}catch(error){renderError()}}
function stateClass(s){return String(s||'unknown').replace(/[^a-z0-9_-]/gi,'_')}
function render(){let conversations=[...(snapshot.conversations||[])].sort((a,b)=>timeOf(b)-timeOf(a));detectCompletions(conversations);let active=conversations.filter(c=>activeStatuses.has(c.status)).length;document.getElementById('active').textContent=active;document.getElementById('deviceCount').textContent=(snapshot.devices||[]).length;document.getElementById('main').innerHTML=conversations.length?`<div class="list">${conversations.map(rowItem).join('')}</div>`:`<div class="empty"><div><h2>暂无会话记录</h2><p>${(snapshot.devices||[]).length} 台设备已连接</p></div></div>`}
function detectCompletions(conversations){let now=Date.now();let present=new Set();for(let c of conversations){let key=conversationKey(c);present.add(key);let previous=knownStatuses.get(key);let doneId=completionKey(c);if(hasLoaded&&!c.suppressCompletion&&completionFromStatuses.has(previous)&&c.status==='idle'&&!notifiedCompletions.has(doneId)){notifiedCompletions.add(doneId);recentCompletions.set(key,now);showCompletion(c);playCoinSound()}knownStatuses.set(key,c.status)}for(let [key,stamp] of recentCompletions){if(now-stamp>9000)recentCompletions.delete(key)}for(let key of [...knownStatuses.keys()]){if(!present.has(key))knownStatuses.delete(key)}hasLoaded=true}
function rowItem(c){let info=statusInfo(c.status);let line=detail(c);let glow=recentCompletions.has(conversationKey(c))?' just-completed':'';return `<article class="listrow state-${stateClass(c.status)}${glow}" style="--accent:${info[1]};--soft:${info[2]}"><div class="statuspill"><span class="motion"></span>${esc(info[0])}</div><div class="rowmain"><div class="rowhead"><span class="device">${esc(c.deviceName||c.deviceHost||'未知设备')}</span><div class="rowtitle">${esc(c.title||c.conversationId||'未命名会话')}</div></div><div class="rowmeta">${esc(line||'暂无详情')}</div></div><div class="rowtime">${rel(c.lastEventAt||c.seenAt||c.completedAt)}</div></article>`}
function showCompletion(c){let box=document.getElementById('notices');if(!box)return;let item=document.createElement('div');item.className='notice';let title=c.title||c.conversationId||'未命名会话';let device=c.deviceName||c.deviceHost||'未知设备';item.innerHTML=`<strong>任务完成</strong><span>${esc(device)} · ${esc(title)}</span>`;box.prepend(item);setTimeout(()=>{item.style.opacity='0';item.style.transform='translateY(6px)';item.style.transition='opacity .18s ease, transform .18s ease';setTimeout(()=>item.remove(),220)},5200);while(box.children.length>3)box.lastElementChild.remove()}
function playCoinSound(){try{let audio=document.getElementById('completeSound');if(!audio)return;audio.currentTime=0;let playing=audio.play();if(playing&&playing.catch)playing.catch(()=>{})}catch(error){}}
function renderError(){document.getElementById('active').textContent='0';document.getElementById('deviceCount').textContent='0';document.getElementById('main').innerHTML='<div class="empty"><div><h2>连接中断</h2><p>等待服务恢复</p></div></div>'}
load();setInterval(load,2000);
</script>
</body>
</html>
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=42178)
    args = parser.parse_args()

    state = DashboardState()
    devices = os.environ.get("AGENTBEACON_DEVICES", "")
    for entry in [item.strip() for item in devices.split(",") if item.strip()]:
        host, _, port = entry.partition(":")
        state.add_manual_device(host, int(port or DEFAULT_AGENT_PORT))

    threading.Thread(target=discovery_loop, args=(state,), daemon=True).start()
    threading.Thread(target=poll_loop, args=(state,), daemon=True).start()
    threading.Thread(target=scan_loop, args=(state,), daemon=True).start()
    threading.Thread(target=screen_loop, args=(state,), daemon=True).start()

    server = ThreadingHTTPServer((args.host, args.port), make_handler(state))
    print("AgentBeacon Pi dashboard listening on http://%s:%s" % (args.host, args.port), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
