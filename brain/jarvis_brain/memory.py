"""Jarvis 的长期记忆。

一句话说清它是什么：**跨会话、跨重启都还在的一小撮事实**。
`session.history` 是这一轮对话的短期记忆，`new_session` 一按就没；这里存的是
"这个人是谁、他偏好什么、他手上在做什么"——那些下次开口时理应已经知道的东西。

设计上刻意保守，因为 Brain 只用标准库：

- **没有向量检索。** 用字符/词重叠打分。中文按 2-gram 切、英文按词切，
  这对"记一句话、下次按关键词捞回来"这个量级（几百条）完全够用，
  而且零依赖、零加载时间。真正的语义检索要嵌入模型，那会把 Brain 的
  "纯标准库"这条底线打掉，不值得。
- **单文件 JSON，整体读写。** 几百条记忆撑死几十 KB。上锁 + 原子替换，
  避免宿主崩在写一半时把记忆弄丢。
- **pinned 类别常驻上下文。** identity / preference 是"每一轮都该知道"的，
  不该靠关键词碰运气召回；其余按当前这句话检索。

写入由模型通过 memory_save 工具显式发起，不做隐式抓取——隐式抓取会把
闲聊噪音塞满记忆，而且用户无从知道 Jarvis 到底记了什么。
"""
import json
import os
import re
import threading
import time
import uuid

from . import config

MEMORY_PATH = os.path.join(config.JARVIS_DIR, "memory.json")

# 每一轮都注入的类别。自我身份与用户身份/偏好不该靠关键词碰运气。
PINNED_KINDS = ("self", "identity", "preference")

KINDS = {
    "self":       "Jarvis 对自己的认知：诞生日、创造者、身份",
    "identity":   "用户是谁：姓名、称呼、身份、所在地、设备",
    "preference": "偏好与习惯：喜欢怎么被回应、常用工具、忌讳",
    "project":    "手上在做的事：项目、目标、进度",
    "relationship": "人物与关系：家人、同事、客户，以及与用户的关系",
    "commitment": "尚未完成的承诺、待办或未来事项",
    "episode":    "共同经历过的事件或完成过的任务（带时间线）",
    "lesson":     "从成功或失败中形成、以后应复用的经验",
    "fact":       "其他值得记住的事实",
}

LAYERS = {
    "core": ("self", "identity", "preference"),
    "semantic": ("relationship", "project", "lesson", "fact"),
    "episodic": ("episode",),
    "prospective": ("commitment",),
}

# 上下文预算。记忆再有用也不能把 token 吃光——超出就按分数截断。
MAX_PINNED = 20
MAX_RECALLED = 8
MAX_ENTRIES = 500
MAX_TEXT = 600
# 单文件硬上限。正常情况下 500 条短记忆远低于这个值；若大量长内容把文件
# 顶到上限，就淘汰低频、最旧的非内置记录，避免每轮加载和整体写回越来越慢。
MAX_FILE_BYTES = 512 * 1024
MAX_CONTEXT_CHARS = 8000

# 稳定 id 让升级、重启和重复初始化都不会多写一条。时间为
# 2026-08-01 00:00:00 +08:00；这是 Jarvis 的软件诞生日。
BUILTIN_MEMORIES = ({
    "id": "jarvis-birthday",
    "text": "Jarvis 的诞生日是 2026 年 8 月 1 日，创造者是 Frank。Jarvis was created by Frank on August 1, 2026.",
    "kind": "self",
    "tags": ["birthday", "creation", "origin", "诞生日", "创造"],
    "created": 1785513600,
    "updated": 1785674745,
    "used": 0,
    "subject": "jarvis:origin",
    "source": "system",
    "confidence": 1.0,
    "status": "active",
    "builtin": True,
},)

_CJK = re.compile(r"[一-鿿]")
_WORD = re.compile(r"[a-zA-Z0-9_]+")
_STOP = {
    "的", "了", "是", "在", "我", "你", "他", "她", "它", "们", "和", "与", "吗", "呢",
    "a", "an", "the", "is", "are", "was", "were", "to", "of", "and", "or", "in", "on",
    "for", "it", "i", "you", "my", "me", "that", "this", "with", "do", "does",
}


def _tokens(text):
    """切成可比对的片段：英文按词、中文按 2-gram。

    中文不做分词——标准库没有词典，2-gram 在"记忆召回"这个精度要求下
    比按单字比更准（单字重叠率虚高），比装 jieba 便宜得多。
    """
    text = (text or "").lower()
    out = set()
    for word in _WORD.findall(text):
        if word not in _STOP and len(word) > 1:
            out.add(word)
    run = ""
    for char in text:
        if _CJK.match(char):
            run += char
        else:
            run = ""
            continue
        if len(run) >= 2:
            out.add(run[-2:])
    return out


class MemoryStore:
    def __init__(self, path=MEMORY_PATH):
        self.path = path
        self._lock = threading.RLock()
        self._entries = []
        self._loaded = False

    # ------------------------------------------------------------ 持久化

    def _load(self):
        if self._loaded:
            return
        self._loaded = True
        try:
            with open(self.path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
            if isinstance(data, dict):
                data = data.get("entries") or []
            self._entries = [e for e in data if isinstance(e, dict) and e.get("text")]
        except FileNotFoundError:
            self._entries = []
        except Exception:
            # 记忆文件坏了不能让 Brain 起不来。留个副本，从空的重新开始。
            try:
                os.replace(self.path, self.path + ".corrupt")
            except Exception:
                pass
            self._entries = []

        # 内置自我记忆与用户记忆保存在同一个文件中，但用稳定 id 去重。
        # 这样不需要额外数据库，也不会在每次启动时重复增长。
        # v1 memory.json did not require the layered-memory metadata. Normalize it
        # once on load so every later read can stay fast and branch-free.
        now = time.time()
        added = False
        for entry in self._entries:
            defaults = {
                "id": uuid.uuid4().hex[:8],
                "kind": "fact",
                "tags": [],
                "created": now,
                "updated": entry.get("created", now),
                "used": 0,
                "source": "system" if entry.get("builtin") else "user",
                "confidence": 1.0,
            }
            for key, value in defaults.items():
                if key not in entry:
                    entry[key] = value
                    added = True

        by_id = {e.get("id"): e for e in self._entries}
        for builtin in BUILTIN_MEMORIES:
            existing = by_id.get(builtin["id"])
            if existing is None:
                self._entries.append(dict(builtin))
                added = True
                continue
            # 内置身份以代码中的版本为准：升级时能够修正创造者、日期等事实，
            # 同时保留运行期累计的 used/last_used，不把使用统计清零。
            for key in ("text", "kind", "tags", "created", "updated", "subject", "source",
                        "confidence", "status", "builtin"):
                if existing.get(key) != builtin.get(key):
                    existing[key] = builtin[key]
                    added = True
        if added:
            self._evict()
            self._save()

    def _save(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".tmp"
        payload = {"version": 1, "entries": self._entries}
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=1)
        os.replace(tmp, self.path)          # 原子替换，崩在中途也不会剩半个文件
        try:
            os.chmod(self.path, 0o600)
        except OSError:
            pass

    # ------------------------------------------------------------ 写

    def save(self, text, kind="fact", tags=None, subject=None, source="user", confidence=1.0,
             status=None, remind_at=None):
        """新增或就地更新一条。返回 (entry, created)。"""
        text = (text or "").strip()[:MAX_TEXT]
        if not text:
            raise ValueError("记忆内容不能为空")
        if kind not in KINDS:
            kind = "fact"

        with self._lock:
            self._load()
            subject = (subject or "").strip()[:120] or None
            existing = self._find_similar(text, kind, subject)
            now = time.time()
            if existing:
                # 同一件事被重复告知就是"更新"，不是"再记一条"——
                # 否则"我叫 X"改成"我叫 Y"会让两条互相打架，模型只能瞎猜。
                existing["text"] = text
                existing["kind"] = kind
                existing["tags"] = sorted(set(tags or []) | set(existing.get("tags") or []))
                if subject:
                    existing["subject"] = subject
                existing["source"] = source or existing.get("source") or "user"
                existing["confidence"] = max(0.0, min(float(confidence), 1.0))
                if status:
                    existing["status"] = status
                if remind_at is not None:
                    existing["remind_at"] = (remind_at or "").strip()[:40] or None
                existing["updated"] = now
                self._save()
                return existing, False

            entry = {
                "id": uuid.uuid4().hex[:8],
                "text": text,
                "kind": kind,
                "tags": sorted(set(tags or [])),
                "created": now,
                "updated": now,
                "used": 0,
                "subject": subject,
                "source": source or "user",
                "confidence": max(0.0, min(float(confidence), 1.0)),
            }
            if status:
                entry["status"] = status
            if remind_at:
                entry["remind_at"] = remind_at.strip()[:40]
            self._entries.append(entry)
            self._evict()
            self._save()
            return entry, True

    def forget(self, entry_id=None, query=None):
        """按 id 精确删，或按关键词删掉最匹配的一条。返回被删的那条。"""
        with self._lock:
            self._load()
            target = None
            if entry_id:
                target = next((e for e in self._entries if e["id"] == entry_id), None)
            elif query:
                ranked = self._rank(query, self._entries)
                if ranked and ranked[0][0] > 0:
                    target = ranked[0][1]
            if not target:
                return None
            if target.get("builtin"):
                raise ValueError("内置身份记忆不能通过对话删除")
            self._entries.remove(target)
            self._save()
            return target

    def update(self, entry_id, text=None, status=None, confidence=None, remind_at=None):
        """按稳定 id 修改状态或内容；用于承诺完成、事实纠正。"""
        with self._lock:
            self._load()
            entry = next((e for e in self._entries if e.get("id") == entry_id), None)
            if not entry:
                return None
            if text is not None:
                cleaned = text.strip()[:MAX_TEXT]
                if not cleaned:
                    raise ValueError("记忆内容不能为空")
                entry["text"] = cleaned
            if status:
                entry["status"] = status
            if confidence is not None:
                entry["confidence"] = max(0.0, min(float(confidence), 1.0))
            if remind_at is not None:
                entry["remind_at"] = (remind_at or "").strip()[:40] or None
            entry["updated"] = time.time()
            self._save()
            return entry

    def mark_reminded(self, entry_id, when=None):
        """记录通知时间；不改变承诺状态，用户确认完成后才真正收口。"""
        with self._lock:
            self._load()
            entry = next((e for e in self._entries if e.get("id") == entry_id), None)
            if not entry:
                return False
            entry["last_reminded"] = float(when or time.time())
            self._save()
            return True

    def clear(self):
        with self._lock:
            self._load()
            removable = [e for e in self._entries if not e.get("builtin")]
            count = len(removable)
            self._entries = [e for e in self._entries if e.get("builtin")]
            self._save()
            return count

    # ------------------------------------------------------------ 读

    def all(self, kind=None):
        with self._lock:
            self._load()
            items = [e for e in self._entries if not kind or e["kind"] == kind]
            return sorted(items, key=lambda e: e["updated"], reverse=True)

    def search(self, query, limit=MAX_RECALLED):
        with self._lock:
            self._load()
            ranked = self._rank(query, self._entries)
            return [entry for score, entry in ranked[:limit] if score > 0]

    def recall(self, query, limit=MAX_RECALLED):
        """检索并记一次命中。命中次数用于淘汰时保住常用的那些。"""
        hits = self.search(query, limit)
        if hits:
            with self._lock:
                for entry in hits:
                    entry["used"] = entry.get("used", 0) + 1
                    entry["last_used"] = time.time()
                self._save()
        return hits

    def context_block(self, query=None, limit=MAX_RECALLED):
        """拼成塞进 system prompt 的那段文本。没有记忆就返回空串。"""
        with self._lock:
            self._load()
            if not self._entries:
                return ""

        all_entries = self.all()
        pinned = [e for e in all_entries if e["kind"] in PINNED_KINDS][:MAX_PINNED]
        pinned_ids = {e["id"] for e in pinned}
        recalled = [e for e in (self.recall(query, limit) if query and limit else [])
                    if e["id"] not in pinned_ids]

        lines = []
        self_memories = [e for e in pinned if e["kind"] == "self"]
        user_memories = [e for e in pinned if e["kind"] != "self"]
        if self_memories:
            lines.append("Known about yourself (always true):")
            lines += ["- %s" % e["text"] for e in self_memories]
        if user_memories:
            if lines:
                lines.append("")
            lines.append("Known about the user (always true):")
            lines += ["- [%s] %s" % (e["kind"], e["text"]) for e in user_memories]
        if recalled:
            if lines:
                lines.append("")
            lines.append("Possibly relevant to what was just said:")
            lines += ["- [%s] %s" % (e["kind"], e["text"]) for e in recalled]
        commitments = [e for e in all_entries
                       if e.get("kind") == "commitment" and e.get("status", "pending") == "pending"][:5]
        if commitments:
            if lines:
                lines.append("")
            lines.append("Open commitments (not completed yet):")
            lines += ["- %s" % e["text"] for e in commitments]
        if not lines:
            return ""
        return "\n".join(lines)[:MAX_CONTEXT_CHARS]

    # ------------------------------------------------------------ 内部

    def _rank(self, query, entries):
        query_tokens = _tokens(query)
        if not query_tokens:
            return []
        now = time.time()
        ranked = []
        for entry in entries:
            entry_tokens = _tokens(entry["text"] + " " + " ".join(entry.get("tags") or []))
            if not entry_tokens:
                continue
            overlap = len(query_tokens & entry_tokens)
            if not overlap:
                continue
            # 用 query 的长度归一，短查询不会因为记忆条目长就被稀释
            score = overlap / float(len(query_tokens))
            score *= max(0.25, min(float(entry.get("confidence", 1.0)), 1.0))
            # 新鲜度：一个月内的略微加权，避免陈年旧事压过刚说的事
            age_days = (now - entry.get("updated", now)) / 86400.0
            score *= 1.0 + max(0.0, (30.0 - age_days)) / 100.0
            ranked.append((score, entry))
        ranked.sort(key=lambda pair: pair[0], reverse=True)
        return ranked

    def _find_similar(self, text, kind, subject=None):
        """找语义上"同一件事"的旧条目。阈值定得高，宁可多记也别错误覆盖。"""
        new_tokens = _tokens(text)
        if not new_tokens:
            return None
        for entry in self._entries:
            if entry["kind"] != kind:
                continue
            if subject and entry.get("subject") == subject:
                return entry
            old_tokens = _tokens(entry["text"])
            if not old_tokens:
                continue
            union = len(new_tokens | old_tokens)
            if union and len(new_tokens & old_tokens) / float(union) >= 0.6:
                return entry
        return None

    def _evict(self):
        """同时约束条目数和序列化体积，内置身份和 pinned 类别永不淘汰。

        pinned（self/identity/preference）走 context_block 的常驻注入，不经
        recall()，used 永远是 0——按 (used, updated) 挑受害者的话，它们会最先
        被淘汰，跟"这两类不该靠关键词碰运气"的设计初衷正好相反。数量已经靠
        MAX_PINNED 在读取时软限制（只注入最近更新的 20 条），不需要在这里
        再靠强制删除控制体量。
        """
        def encoded_size():
            payload = {"version": 1, "entries": self._entries}
            return len(json.dumps(payload, ensure_ascii=False).encode("utf-8"))

        while len(self._entries) > MAX_ENTRIES or encoded_size() > MAX_FILE_BYTES:
            candidates = [e for e in self._entries
                          if not e.get("builtin") and e.get("kind") not in PINNED_KINDS]
            if not candidates:
                break
            victim = min(candidates,
                         key=lambda e: (e.get("used", 0), e.get("updated", 0)))
            self._entries.remove(victim)


STORE = MemoryStore()
