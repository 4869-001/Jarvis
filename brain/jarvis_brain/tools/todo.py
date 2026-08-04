"""待办清单。Agent 模式下用来把一个长任务拆开、并把进度亮给用户看。

它不是"给模型做笔记"，而是**面板上那块进度面板的唯一数据源**——所以状态机管得死：
同一时刻只允许一条 in_progress，模型漏了这条就在返回里直接纠正它，
否则面板会同时高亮三行，用户看不出到底在干哪件事。
"""
STATUSES = ("pending", "in_progress", "completed")


def todo_write(args, ctx):
    raw = args.get("todos")
    if not isinstance(raw, list):
        return {"error": "todos 必须是数组"}
    if len(raw) > 30:
        return {"error": "待办超过 30 条，先做完一批再列"}

    todos = []
    for index, item in enumerate(raw):
        if not isinstance(item, dict):
            return {"error": "第 %d 条待办不是对象" % (index + 1)}
        content = (item.get("content") or "").strip()
        if not content:
            return {"error": "第 %d 条待办缺少 content" % (index + 1)}
        status = item.get("status") or "pending"
        if status not in STATUSES:
            return {"error": "第 %d 条待办的 status 非法：%s" % (index + 1, status)}
        todos.append({
            "content": content[:120],
            # 进行中那条在面板上显示为"正在……"，所以要一句动词短语
            "active_form": (item.get("active_form") or content)[:120],
            "status": status,
        })

    running = [t for t in todos if t["status"] == "in_progress"]
    warning = ""
    if len(running) > 1:
        # 不报错、不丢改动：这时候把整批打回去，模型往往会重列一遍浪费一步。
        # 保留第一条为进行中，其余降回 pending，然后在返回里说清楚。
        for extra in running[1:]:
            extra["status"] = "pending"
        warning = "同一时刻只能有一条 in_progress，已把多出来的降回 pending。"

    ctx["set_todos"](todos)
    done = sum(1 for t in todos if t["status"] == "completed")
    return {
        "total": len(todos),
        "completed": done,
        "in_progress": running[0]["content"] if running else None,
        "note": warning or "待办已更新，用户能在面板上看到。",
    }
