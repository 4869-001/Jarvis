"""记忆工具。薄薄一层，真正的逻辑都在 ../memory.py。

这几个工具刻意不设确认弹窗（L1）：记东西是对话里最高频的副作用，
每记一条弹一次框会让人干脆不用它。代价是模型可能记些没用的，
但记忆有上限也能被 memory_forget 删掉，可逆。
"""
from ..memory import KINDS, STORE


def _brief(entry):
    return {"id": entry["id"], "kind": entry["kind"], "text": entry["text"],
            "tags": entry.get("tags") or [], "subject": entry.get("subject"),
            "source": entry.get("source"), "confidence": entry.get("confidence", 1.0),
            "status": entry.get("status"), "remind_at": entry.get("remind_at"),
            "last_reminded": entry.get("last_reminded")}


def memory_save(args, ctx):
    text = (args.get("text") or "").strip()
    if not text:
        return {"error": "缺少 text"}
    tags = args.get("tags")
    if isinstance(tags, str):
        tags = [t.strip() for t in tags.split(",") if t.strip()]
    try:
        entry, created = STORE.save(text, args.get("kind") or "fact", tags,
                                    subject=args.get("subject"), source="user",
                                    confidence=args.get("confidence", 1.0),
                                    status=args.get("status"), remind_at=args.get("remind_at"))
    except ValueError as exc:
        return {"error": str(exc)}
    return {"saved": _brief(entry), "created": created,
            "note": "已记住" if created else "已更新原有的同类记忆"}


def memory_recall(args, ctx):
    query = (args.get("query") or "").strip()
    if not query:
        return {"error": "缺少 query"}
    limit = max(1, min(int(args.get("limit") or 8), 20))
    hits = STORE.recall(query, limit)
    return {"query": query, "count": len(hits), "memories": [_brief(e) for e in hits]}


def memory_list(args, ctx):
    kind = args.get("kind")
    if kind and kind not in KINDS:
        return {"error": "kind 只能是 %s" % "/".join(KINDS)}
    entries = STORE.all(kind)
    return {"count": len(entries), "memories": [_brief(e) for e in entries[:100]]}


def memory_forget(args, ctx):
    entry_id = (args.get("id") or "").strip() or None
    query = (args.get("query") or "").strip() or None
    if not entry_id and not query:
        return {"error": "要么给 id，要么给 query"}
    try:
        entry = STORE.forget(entry_id, query)
    except ValueError as exc:
        return {"error": str(exc)}
    if not entry:
        return {"error": "没找到匹配的记忆"}
    return {"forgot": _brief(entry)}


def memory_update(args, ctx):
    entry_id = (args.get("id") or "").strip()
    if not entry_id:
        return {"error": "缺少 id"}
    try:
        entry = STORE.update(entry_id, args.get("text"), args.get("status"),
                             args.get("confidence"), args.get("remind_at"))
    except ValueError as exc:
        return {"error": str(exc)}
    if not entry:
        return {"error": "没找到这条记忆"}
    return {"updated": _brief(entry)}
