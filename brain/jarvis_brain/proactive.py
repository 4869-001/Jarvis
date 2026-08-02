"""低打扰主动提醒：只处理带明确 remind_at 的未完成承诺。"""
import datetime as dt
import threading
import time
import uuid


def _parse_iso(value):
    try:
        return dt.datetime.fromisoformat((value or "").replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None


def _minutes(value):
    try:
        hour, minute = value.split(":", 1)
        return int(hour) * 60 + int(minute)
    except Exception:
        return 0


class ProactiveReminderEngine:
    def __init__(self, cfg, store, emit, log, connected):
        self.cfg = cfg or {}
        self.store = store
        self.emit = emit
        self.log = log
        self.connected = connected
        self.stop_event = threading.Event()
        self.thread = None

    def start(self):
        if not self.cfg.get("enabled", True) or self.thread:
            return
        self.thread = threading.Thread(target=self._run, name="jarvis-reminders", daemon=True)
        self.thread.start()

    def stop(self):
        self.stop_event.set()

    def _run(self):
        interval = max(15, min(int(self.cfg.get("check_interval") or 30), 300))
        while not self.stop_event.wait(interval):
            try:
                self.check_once()
            except Exception as exc:
                self.log("主动提醒检查失败：%s" % exc)

    def _quiet(self, now):
        current = now.hour * 60 + now.minute
        start = _minutes(self.cfg.get("quiet_start") or "22:30")
        end = _minutes(self.cfg.get("quiet_end") or "08:00")
        return start <= current < end if start < end else current >= start or current < end

    def check_once(self, now=None):
        now = now or dt.datetime.now().astimezone()
        if self._quiet(now) or not self.connected():
            return 0
        entries = self.store.all("commitment")
        today = now.date()
        reminded_today = sum(1 for e in entries if e.get("last_reminded") and
                             dt.datetime.fromtimestamp(e["last_reminded"], now.tzinfo).date() == today)
        daily_limit = max(1, min(int(self.cfg.get("daily_limit") or 6), 20))
        cooldown = max(15, int(self.cfg.get("cooldown_minutes") or 120)) * 60
        sent = 0
        for entry in entries:
            if reminded_today + sent >= daily_limit:
                break
            if entry.get("status", "pending") != "pending":
                continue
            due = _parse_iso(entry.get("remind_at"))
            if not due:
                continue
            if due.tzinfo is None:
                due = due.replace(tzinfo=now.tzinfo)
            if due > now or time.time() - float(entry.get("last_reminded") or 0) < cooldown:
                continue
            request_id = "reminder_" + uuid.uuid4().hex[:10]
            self.emit({"type": "native_tool_request", "id": request_id,
                       "request_id": request_id, "name": "system_notify",
                       "arguments": {"title": "J.A.R.V.I.S. · 提醒",
                                     "body": entry.get("text", "")[:180]}})
            self.store.mark_reminded(entry.get("id"), time.time())
            sent += 1
        return sent
