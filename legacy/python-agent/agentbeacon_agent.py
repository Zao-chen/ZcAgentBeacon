#!/usr/bin/env python3
import argparse
import json
import os
import platform
import re
import socket
import sqlite3
import subprocess
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


DISCOVERY_ADDRESS = "239.255.42.99"
DISCOVERY_PORT = 42179
DEFAULT_PORT = 42180
TAIL_BYTES = int(os.environ.get("AGENTBEACON_TAIL_BYTES", 384 * 1024))
TAIL_LINES = int(os.environ.get("AGENTBEACON_TAIL_LINES", 2500))
PROCESS_FRESHNESS_SECONDS = 45
ACTIVE_EVENT_FRESHNESS_SECONDS = 600
MAX_THREADS_TO_SCAN = int(os.environ.get("AGENTBEACON_MAX_THREADS", 10))
RAW_EVENT_LIMIT = int(os.environ.get("AGENTBEACON_RAW_EVENT_LIMIT", 360))
ABORT_EVENT_MARKERS = ("abort", "cancel", "interrupt")


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


def iso_from_ms(value):
    if not value:
        return None
    return datetime.fromtimestamp(value / 1000, timezone.utc).isoformat().replace("+00:00", "Z")


def iso_from_ts(value):
    if not value:
        return None
    return datetime.fromtimestamp(value, timezone.utc).isoformat().replace("+00:00", "Z")


def parse_time(value):
    if not value:
        return None
    if isinstance(value, (int, float)):
        return value / 1000 if value > 100000000000 else value
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def mask(value, max_length=1200):
    if value is None:
        return ""
    text = str(value)
    scan_limit = max(max_length * 2, max_length)
    if len(text) > scan_limit:
        text = text[:scan_limit] + "..."
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


def run_command(args, **kwargs):
    if platform.system().lower() == "windows":
        kwargs.setdefault("creationflags", getattr(subprocess, "CREATE_NO_WINDOW", 0))
    return subprocess.run(args, **kwargs)


def codex_home():
    override = os.environ.get("AGENTBEACON_CODEX_HOME")
    if override:
        return Path(override)
    return Path.home() / ".codex"


class SessionActivity:
    def __init__(self):
        self.has_open_turn = False
        self.pending_calls = set()
        self.completed_turn_ids = set()
        self.turn_id = None
        self.last_event_at = None
        self.last_turn_activity_at = None
        self.last_response_at = None
        self.last_activity_kind = None
        self.last_task_complete_at = None
        self.last_terminal_status = None
        self.last_tool_name = None
        self.last_command = None
        self.last_tool_output = None
        self.last_explanation = None
        self.last_message_summary = None
        self.display_detail = None
        self.display_detail_at = None
        self.display_detail_source = None

    @property
    def has_pending_tool(self):
        return bool(self.pending_calls)

    @property
    def is_active(self):
        if self.has_open_turn or self.has_pending_tool:
            return True
        return bool(
            self.last_response_at
            and time.time() - self.last_response_at <= ACTIVE_EVENT_FRESHNESS_SECONDS
            and (not self.last_task_complete_at or self.last_response_at > self.last_task_complete_at)
        )

    @property
    def status(self):
        if not self.is_active:
            if (
                self.last_terminal_status == "interrupted"
                and self.last_task_complete_at
                and time.time() - self.last_task_complete_at <= ACTIVE_EVENT_FRESHNESS_SECONDS
            ):
                return "interrupted"
            return "idle"
        return "tool_running" if self.has_pending_tool else "thinking"

    def note_activity(self, kind, event_at):
        if event_at:
            self.last_turn_activity_at = event_at
            self.last_activity_kind = kind

    def note_response(self, kind, event_at, turn_id=None):
        if turn_id and turn_id not in self.completed_turn_ids:
            self.turn_id = turn_id
        self.last_terminal_status = None
        if event_at:
            self.last_response_at = event_at
        self.note_activity(kind, event_at)

    def finish_turn(self, turn_id_key, event_at, completed_at=None, terminal_status="idle"):
        self.has_open_turn = False
        self.pending_calls.clear()
        if turn_id_key:
            self.completed_turn_ids.add(turn_id_key)
        if completed_at and event_at:
            completed_at = max(completed_at, event_at)
        self.last_task_complete_at = completed_at or event_at
        self.last_terminal_status = terminal_status
        self.note_activity(terminal_status, self.last_task_complete_at)

    def set_detail(self, text, event_at, source, max_length=360):
        if not text:
            return
        if self.display_detail_at and event_at and event_at < self.display_detail_at:
            return
        self.display_detail = mask(text, max_length)
        self.display_detail_at = event_at
        self.display_detail_source = source


def content_text(value):
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        parts = []
        for item in value:
            if isinstance(item, dict):
                text = item.get("text") or item.get("message")
                if text:
                    parts.append(str(text))
            elif item:
                parts.append(str(item))
        return " ".join(parts)
    if isinstance(value, dict):
        return str(value.get("text") or value.get("message") or "")
    return str(value)


def extract_explanation(arguments):
    if not arguments:
        return ""
    data = arguments
    if isinstance(arguments, str):
        try:
            data = json.loads(arguments)
        except json.JSONDecodeError:
            return ""
    if not isinstance(data, dict):
        return ""
    return content_text(data.get("explanation"))


def event_turn_id(data, payload):
    metadata = data.get("internal_chat_message_metadata_passthrough")
    if not isinstance(metadata, dict):
        metadata = payload.get("internal_chat_message_metadata_passthrough")
    if not isinstance(metadata, dict):
        metadata = {}
    return data.get("turn_id") or payload.get("turn_id") or metadata.get("turn_id")


def is_abort_event(event_type):
    value = str(event_type or "").lower()
    return any(marker in value for marker in ABORT_EVENT_MARKERS)


def terminal_time(data, event_at):
    for key in ("completed_at", "aborted_at", "cancelled_at", "canceled_at", "interrupted_at", "ended_at"):
        parsed = parse_time(data.get(key))
        if parsed:
            return parsed
    return event_at


def is_assistant_message(data):
    role = data.get("role")
    content = data.get("content")
    if role in ("user", "developer", "system"):
        return False
    if isinstance(content, list):
        return any(isinstance(item, dict) and item.get("type") == "output_text" for item in content)
    return bool(content and role not in ("user", "developer", "system"))


def parse_session_lines(lines):
    activity = SessionActivity()
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            decoded = json.loads(line)
        except json.JSONDecodeError:
            continue
        event_at = parse_time(decoded.get("timestamp") or decoded.get("ts") or decoded.get("created_at"))
        if event_at and (not activity.last_event_at or event_at > activity.last_event_at):
            activity.last_event_at = event_at
        payload = decoded.get("payload") or {}
        item = payload.get("item") or {}
        data = item if isinstance(item, dict) and item else payload
        if not isinstance(data, dict):
            continue
        event_type = data.get("type") or payload.get("type")
        turn_id = event_turn_id(data, payload)
        turn_id_key = str(turn_id) if turn_id else None
        if event_type == "task_started":
            activity.has_open_turn = True
            activity.turn_id = turn_id
            if turn_id_key:
                activity.completed_turn_ids.discard(turn_id_key)
            activity.note_activity("task_started", event_at)
        elif event_type == "task_complete" or is_abort_event(event_type):
            interrupted = is_abort_event(event_type)
            completed_at = terminal_time(data, event_at)
            activity.finish_turn(turn_id_key, event_at, completed_at, "interrupted" if interrupted else "idle")
            if data.get("last_agent_message"):
                activity.last_message_summary = mask(data.get("last_agent_message"))
                activity.set_detail(data.get("last_agent_message"), activity.last_task_complete_at, "complete")
            elif interrupted:
                detail = data.get("reason") or data.get("message") or data.get("error") or "会话已中断"
                activity.last_message_summary = mask(detail)
                activity.set_detail(detail, activity.last_task_complete_at, "interrupted", 120)
        elif event_type == "function_call":
            if turn_id_key and turn_id_key in activity.completed_turn_ids:
                continue
            activity.note_response("function_call", event_at, turn_id)
            call_id = data.get("call_id") or data.get("id")
            if call_id:
                activity.pending_calls.add(str(call_id))
            tool_name = str(data.get("name") or "tool")
            explanation = extract_explanation(data.get("arguments"))
            if explanation:
                activity.last_explanation = mask(explanation, 360)
                activity.last_message_summary = activity.last_explanation
                activity.last_tool_name = "explanation" if tool_name == "update_plan" else tool_name
                activity.last_command = ""
                activity.set_detail(explanation, event_at, "explanation")
            else:
                activity.last_tool_name = tool_name
                activity.last_command = mask(json.dumps(data.get("arguments"), ensure_ascii=False) if not isinstance(data.get("arguments"), str) else data.get("arguments"))
                activity.set_detail(activity.last_command, event_at, "command")
        elif event_type == "function_call_output":
            if turn_id_key and turn_id_key in activity.completed_turn_ids:
                continue
            activity.note_response("function_call_output", event_at, turn_id)
            call_id = data.get("call_id") or data.get("id")
            if call_id:
                activity.pending_calls.discard(str(call_id))
            activity.last_tool_output = mask(data.get("output"))
            activity.set_detail(activity.last_tool_output, event_at, "output")
        elif event_type == "agent_message":
            if (turn_id_key and turn_id_key in activity.completed_turn_ids) or (
                not turn_id_key and activity.last_task_complete_at and event_at and event_at > activity.last_task_complete_at and not activity.has_open_turn
            ):
                continue
            activity.note_response("agent_message", event_at, turn_id)
            activity.last_message_summary = mask(data.get("message"))
            activity.set_detail(data.get("message"), event_at, "message")
        elif event_type == "message":
            if turn_id_key and turn_id_key in activity.completed_turn_ids:
                continue
            text = content_text(data.get("content"))
            if text and is_assistant_message(data):
                activity.note_response("message", event_at, turn_id)
                activity.last_message_summary = mask(text)
                activity.set_detail(text, event_at, "message")
        elif event_type == "reasoning":
            if turn_id_key and turn_id_key in activity.completed_turn_ids:
                continue
            activity.note_response("reasoning", event_at, turn_id)
            summary = data.get("summary")
            if summary:
                activity.last_message_summary = mask(content_text(summary) or json.dumps(summary, ensure_ascii=False))
                activity.set_detail(activity.last_message_summary, event_at, "reasoning")
            explanation = content_text(data.get("explanation"))
            if explanation:
                activity.last_explanation = mask(explanation, 360)
                activity.last_message_summary = activity.last_explanation
                activity.set_detail(explanation, event_at, "explanation")
            elif not activity.display_detail:
                activity.set_detail("正在思考...", event_at, "reasoning", 80)
    return activity


def raw_event_signal(decoded):
    event_at = parse_time(decoded.get("timestamp") or decoded.get("ts") or decoded.get("created_at"))
    payload = decoded.get("payload") or {}
    item = payload.get("item") or {}
    data = item if isinstance(item, dict) and item else payload
    if not isinstance(data, dict):
        return None
    event_type = data.get("type") or payload.get("type")
    if not event_type:
        return None
    turn_id = event_turn_id(data, payload)
    signal = {
        "type": str(event_type),
        "turnId": turn_id,
        "eventAt": iso_from_ts(event_at),
    }
    call_id = data.get("call_id") or data.get("id")
    if call_id:
        signal["callId"] = call_id
    if data.get("name"):
        signal["toolName"] = str(data.get("name"))
    if data.get("role"):
        signal["role"] = data.get("role")
    for source_key, target_key in (
        ("completed_at", "completedAt"),
        ("aborted_at", "completedAt"),
        ("cancelled_at", "completedAt"),
        ("canceled_at", "completedAt"),
        ("interrupted_at", "completedAt"),
        ("ended_at", "completedAt"),
    ):
        parsed = parse_time(data.get(source_key))
        if parsed:
            signal[target_key] = iso_from_ts(parsed)
            break
    for key in ("last_agent_message", "reason", "message", "error"):
        if data.get(key):
            signal["messageSummary"] = mask(data.get(key), 360)
            break
    if data.get("arguments") is not None:
        arguments = data.get("arguments")
        signal["argumentsSummary"] = mask(arguments if isinstance(arguments, str) else json.dumps(arguments, ensure_ascii=False), 500)
    if data.get("output") is not None:
        signal["outputSummary"] = mask(data.get("output"), 500)
    explanation = extract_explanation(data.get("arguments"))
    if explanation:
        signal["explanation"] = mask(explanation, 360)
    if event_type == "task_started":
        signal["kind"] = "turn_start"
    elif event_type == "task_complete" or is_abort_event(event_type):
        interrupted = is_abort_event(event_type)
        completed_at = terminal_time(data, event_at)
        signal["kind"] = "turn_end"
        signal["terminalStatus"] = "interrupted" if interrupted else "complete"
        signal["completedAt"] = iso_from_ts(completed_at)
    elif event_type == "function_call":
        signal["kind"] = "tool_call"
        signal["toolName"] = signal.get("toolName") or "tool"
    elif event_type == "function_call_output":
        signal["kind"] = "tool_output"
    elif event_type == "agent_message":
        signal["kind"] = "assistant_message"
    elif event_type == "message":
        signal["kind"] = "message"
        text = content_text(data.get("content"))
        if text and is_assistant_message(data):
            signal["messageSummary"] = mask(text, 360)
    elif event_type == "reasoning":
        signal["kind"] = "reasoning"
        summary = data.get("summary")
        if summary:
            signal["messageSummary"] = mask(content_text(summary) or json.dumps(summary, ensure_ascii=False), 360)
        explanation = content_text(data.get("explanation"))
        if explanation:
            signal["explanation"] = mask(explanation, 360)
    else:
        signal["kind"] = "event"
        signal["keys"] = sorted(str(key) for key in data.keys())[:30]
    return {key: value for key, value in signal.items() if value not in (None, "")}


def parse_raw_session_lines(lines):
    signals = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            decoded = json.loads(line)
        except json.JSONDecodeError:
            continue
        signal = raw_event_signal(decoded)
        if signal:
            signals.append(signal)
    return signals[-RAW_EVENT_LIMIT:]


def read_tail_lines(path):
    try:
        size = path.stat().st_size
        start = max(0, size - TAIL_BYTES)
        with path.open("rb") as handle:
            handle.seek(start)
            data = handle.read()
        text = data.decode("utf-8", "replace")
        lines = text.splitlines()
        if start > 0 and lines:
            lines = lines[1:]
        return lines[-TAIL_LINES:]
    except OSError:
        return []


def read_threads(home, errors):
    db = home / "state_5.sqlite"
    if not db.exists():
        errors.append("Codex state database not found: %s" % db)
        return []
    try:
        conn = sqlite3.connect(str(db))
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            select id,
                   coalesce(nullif(title, ''), nullif(preview, ''), id) as title,
                   cwd,
                   rollout_path,
                   coalesce(updated_at_ms, updated_at * 1000) as updated_at_ms
            from threads
            where archived = 0
            order by coalesce(recency_at_ms, updated_at_ms, updated_at * 1000) desc
            """
        ).fetchall()
        conn.close()
    except sqlite3.Error as error:
        errors.append("SQLite read failed: %s" % error)
        return []
    out = []
    for row in rows:
        title = re.sub(r"\s+", " ", row["title"] or "Untitled").strip()
        if len(title) > 180:
            title = title[:180] + "..."
        out.append({
            "id": row["id"],
            "title": title or "Untitled",
            "cwd": row["cwd"] or "",
            "rolloutPath": row["rollout_path"] or "",
            "updatedAtMs": int(row["updated_at_ms"] or 0),
        })
    return out


def resolve_session_file(home, thread):
    rollout = thread.get("rolloutPath") or ""
    if rollout:
        direct = Path(rollout)
        if direct.exists():
            return direct
        relative = home / rollout
        if relative.exists():
            return relative
    sessions = home / "sessions"
    if not sessions.exists():
        return None
    matches = list(sessions.rglob("*%s*.jsonl" % thread["id"]))
    return matches[0] if matches else None


def read_chat_processes(home, errors):
    path = home / "process_manager" / "chat_processes.json"
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        errors.append("Unable to read chat_processes.json: %s" % error)
        return []
    out = []
    for item in data if isinstance(data, list) else []:
        if not isinstance(item, dict) or not item.get("conversationId"):
            continue
        updated = item.get("updatedAtMs") or item.get("startedAtMs")
        if not updated:
            continue
        out.append({
            "conversationId": str(item.get("conversationId")),
            "turnId": item.get("turnId"),
            "cwd": item.get("cwd") or "",
            "command": item.get("command") or "",
            "chatTitle": item.get("chatTitle"),
            "updatedAtMs": int(updated),
        })
    cutoff = time.time() - PROCESS_FRESHNESS_SECONDS
    return [item for item in out if item["updatedAtMs"] / 1000 >= cutoff]


def codex_process_count():
    system = platform.system().lower()
    try:
        if system == "windows":
            result = run_command(["tasklist", "/FO", "CSV", "/NH"], capture_output=True, text=True, timeout=4)
            return len(re.findall(r'"codex\.exe"', result.stdout, re.I))
        result = run_command(["ps", "-axo", "comm="], capture_output=True, text=True, timeout=4)
        return sum(1 for line in result.stdout.splitlines() if line.strip().lower() == "codex")
    except Exception:
        return 0


def node_id(home):
    override = os.environ.get("AGENTBEACON_NODE_ID")
    if override:
        return override
    path = home / "installation_id"
    if path.exists():
        value = path.read_text(encoding="utf-8", errors="replace").strip()
        if value:
            return value
    return "%s-%s" % (socket.gethostname(), platform.system().lower())


def collect_snapshot():
    errors = []
    home = codex_home()
    process_count = codex_process_count()
    threads = read_threads(home, errors)
    thread_by_id = {item["id"]: item for item in threads}
    chat_processes = read_chat_processes(home, errors)
    chat_process_ids = {item["conversationId"] for item in chat_processes}
    raw_conversations = {}

    candidates = []
    cutoff = time.time() - ACTIVE_EVENT_FRESHNESS_SECONDS
    for thread in threads:
        updated_at = (thread.get("updatedAtMs") or 0) / 1000
        if thread["id"] in chat_process_ids or updated_at >= cutoff:
            candidates.append(thread)
        if len(candidates) >= MAX_THREADS_TO_SCAN:
            break

    for thread in candidates:
        session = resolve_session_file(home, thread)
        if not session:
            continue
        lines = read_tail_lines(session)
        raw_conversations[thread["id"]] = {
            "conversationId": thread["id"],
            "title": thread["title"],
            "cwd": thread["cwd"],
            "updatedAt": iso_from_ms(thread.get("updatedAtMs")),
            "events": parse_raw_session_lines(lines),
            "processes": [],
            "detailLevel": "signals",
        }

    for proc in chat_processes:
        raw = raw_conversations.get(proc["conversationId"])
        if not raw:
            thread = thread_by_id.get(proc["conversationId"])
            raw = {
                "conversationId": proc["conversationId"],
                "title": proc.get("chatTitle") or (thread or {}).get("title") or proc["conversationId"],
                "cwd": proc.get("cwd") or (thread or {}).get("cwd") or "",
                "updatedAt": iso_from_ms(proc["updatedAtMs"]),
                "events": [],
                "processes": [],
                "detailLevel": "signals",
            }
            raw_conversations[proc["conversationId"]] = raw
        raw["processes"].append({
            "turnId": proc.get("turnId"),
            "command": mask(proc.get("command"), 500),
            "updatedAt": iso_from_ms(proc["updatedAtMs"]),
            "updatedAtMs": proc["updatedAtMs"],
        })

    return {
        "nodeId": node_id(home),
        "hostname": socket.gethostname(),
        "os": platform.system().lower(),
        "agentVersion": "0.2.0-raw-signals",
        "codexRunning": process_count > 0,
        "rawConversations": list(raw_conversations.values()),
        "errors": errors,
        "collectedAt": now_iso(),
    }


def local_lan_ip():
    override = os.environ.get("AGENTBEACON_AGENT_HOST")
    if override:
        return override
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.connect(("192.168.5.63", 42178))
        value = sock.getsockname()[0]
        sock.close()
        return value
    except OSError:
        return "0.0.0.0"


class AgentHandler(BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            self._json({"ok": True})
        elif self.path == "/status":
            self._json(collect_snapshot())
        else:
            self._json({"error": "not_found"}, status=404)

    def log_message(self, fmt, *args):
        return

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _json(self, payload, status=200):
        encoded = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self._cors()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


def beacon_loop(port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    payload = {
        "kind": "agentbeacon.agent",
        "version": "0.1.0-python",
        "hostname": socket.gethostname(),
        "os": platform.system().lower(),
        "port": port,
    }
    while True:
        payload["sentAt"] = now_iso()
        try:
            sock.sendto(json.dumps(payload).encode("utf-8"), (DISCOVERY_ADDRESS, DISCOVERY_PORT))
        except OSError:
            pass
        time.sleep(5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default=local_lan_ip())
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    args = parser.parse_args()
    threading.Thread(target=beacon_loop, args=(args.port,), daemon=True).start()
    server = ThreadingHTTPServer((args.host, args.port), AgentHandler)
    print("AgentBeacon local agent listening on http://%s:%s/status" % (args.host, args.port), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
