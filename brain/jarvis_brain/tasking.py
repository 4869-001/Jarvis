"""工具任务流水账：记录真实执行，不保存模型思维过程。"""
import json
import os
import threading
import time
import uuid

from . import config

TASKS_PATH = os.path.join(config.JARVIS_DIR, "tasks.json")


def _compact(value, depth=0):
    """任务证据只留摘要，防止文件正文、密钥或工具输出把流水账撑大。"""
    if depth > 3:
        return "…"
    if isinstance(value, dict):
        out = {}
        for key, item in list(value.items())[:20]:
            if any(secret in str(key).lower() for secret in ("key", "token", "password")):
                out[key] = "***"
            else:
                out[key] = _compact(item, depth + 1)
        return out
    if isinstance(value, list):
        return [_compact(item, depth + 1) for item in value[:20]]
    if isinstance(value, str):
        return value if len(value) <= 500 else value[:500] + "…"
    return value


class TaskJournal:
    def __init__(self, path=TASKS_PATH, keep=50):
        self.path = path
        self.keep = keep
        self.lock = threading.RLock()
        self.items = []
        self.loaded = False

    def _load(self):
        if self.loaded:
            return
        self.loaded = True
        try:
            with open(self.path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
            if isinstance(data, list):
                self.items = [x for x in data if isinstance(x, dict)][-self.keep:]
        except Exception:
            self.items = []

    def _save(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".tmp"
        self.items = self.items[-self.keep:]
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(self.items, fh, ensure_ascii=False, indent=1)
        os.replace(tmp, self.path)
        try:
            os.chmod(self.path, 0o600)
        except OSError:
            pass

    def start(self, query, session_id):
        with self.lock:
            self._load()
            task = {"id": uuid.uuid4().hex[:10], "session_id": session_id,
                    "goal": (query or "")[:500], "status": "running",
                    "created": time.time(), "updated": time.time(), "steps": []}
            self.items.append(task)
            self._save()
            return task

    def step_started(self, task, call_id, name, arguments, risk, summary):
        with self.lock:
            step = {"call_id": call_id, "name": name, "arguments": _compact(arguments),
                    "risk": risk, "summary": summary, "status": "running",
                    "started": time.time(), "attempts": 1}
            task["steps"].append(step)
            task["updated"] = time.time()
            self._save()
            return step

    def retry(self, task, step):
        with self.lock:
            step["attempts"] = int(step.get("attempts") or 1) + 1
            task["updated"] = time.time()
            self._save()

    def step_finished(self, task, step, success, summary, evidence=None):
        with self.lock:
            step.update({"status": "completed" if success else "failed",
                         "finished": time.time(), "result": (summary or "")[:1000]})
            if evidence:
                step["evidence"] = evidence
            task["updated"] = time.time()
            self._save()

    def finish(self, task, status):
        if not task:
            return
        with self.lock:
            # 中途取消/崩溃时，正在跑的那一步永远停在 running——task 已经终结，
            # 它的步骤不该再挂着。跟着 task 一起收口，避免留一条永远"进行中"的死记录。
            if status != "completed":
                for step in task.get("steps") or []:
                    if step.get("status") == "running":
                        step["status"] = status
                        step["finished"] = time.time()
            task["status"] = status
            task["updated"] = time.time()
            self._save()
        # 只把真正有分量的已完成任务沉淀成情景记忆：多步骤，或发生过写操作。
        # 简单查一次状态不值得永久记住；完整参数/证据仍只留在 tasks.json。
        steps = task.get("steps") or []
        important = len(steps) >= 2 or any(s.get("risk") in ("L2", "L3", "L4") for s in steps)
        if status == "completed" and important:
            try:
                from .memory import STORE
                actions = "、".join(s.get("summary") or s.get("name") or "" for s in steps[:6])
                when = time.strftime("%Y-%m-%d")
                STORE.save("%s，Jarvis 与用户完成了：%s。执行：%s" %
                           (when, task.get("goal") or "一项工具任务", actions),
                           kind="episode", tags=["task", "completed"],
                           subject="task:" + task["id"], source="system", confidence=1.0,
                           status="completed")
            except Exception:
                pass                         # 情景沉淀不能反过来拖垮任务收尾

    def recent(self, limit=5, recoverable_only=False):
        with self.lock:
            self._load()
            items = reversed(self.items)
            if recoverable_only:
                items = (x for x in items if x.get("status") in ("failed", "interrupted"))
            out = []
            for task in items:
                out.append({"id": task.get("id"), "goal": task.get("goal"),
                            "status": task.get("status"), "updated": task.get("updated"),
                            "steps": [{"name": s.get("name"), "summary": s.get("summary"),
                                       "status": s.get("status"), "result": s.get("result"),
                                       "evidence": s.get("evidence")}
                                      for s in task.get("steps", [])]})
                if len(out) >= limit:
                    break
            return out


def task_history(args, ctx):
    return {"items": JOURNAL.recent(int(args.get("limit") or 5),
                                    bool(args.get("recoverable_only")))}


JOURNAL = TaskJournal()
