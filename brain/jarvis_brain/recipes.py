"""界面操作剧本：把一段摸索成功的 UI 流程存下来，以后一句话重放。

存在的理由：`ui_inspect` → `ui_action` 这条通道是**通用**的，但代价是每次都要现场
摸索。钉钉写日志那条路实测要二十来步、几十秒，中间还埋着三个只有撞过才知道的坑
（日志入口是不可 press 的静态文字、点完会弹确认框、输入框的 AX 值读不回来）。
模型每次重新踩一遍，既慢又不稳。

**但这不是"给钉钉写一个工具"。** 项目里写死的原则是不为每个 App 写工具——写死的
工具只覆盖当初想到的那几个。剧本是通用机制：钉钉审批、报销、任何应用的任何重复
流程都能存，而且剧本是数据不是代码，界面改版重录一遍就行，不用改 Jarvis。

## 三条设计约束

1. **按标签定位，不存硬路径。** `ui_inspect` 给的 `11/5/0/7/0/0` 这种下标路径，
   界面稍微一变就指到别的东西上——那正是 `ui_action` 说明里警告过的。剧本存的是
   "找标签是「日志」的那个元素"，每次重新 inspect 现找。慢一点，但不会点错。

2. **每步都验证。** 这是 2026-08-05 学到的：Qt 应用的点击**返回成功不代表界面动了**。
   所以每步可以带 `expect`，点完必须看到某段文字才算这一步成功，看不到就停下来
   报告，绝不带着错误状态往下跑——那会在用户的真实账号里造成谁也说不清的后果。

3. **有副作用的步骤要么标 confirm，要么根本不写进剧本。** 提交、发送、删除这类
   不可撤销的动作默认走确认框；用户明确要"跑到哪一步为止"时，剧本就到那步为止。
"""
import json
import os
import re
import time

RECIPE_DIR = os.path.expanduser("~/.jarvis/recipes")

# 一个剧本最多几步。不是怕慢，是怕**跑飞**：一段在真实应用里点上百下的脚本，
# 出错时用户根本没法判断它到底做了什么。
MAX_STEPS = 40

# 每步之后等界面稳定的默认时长。太短会在动画还没结束时就 inspect，
# 拿到的是上一帧的元素。
SETTLE = 0.6


class RecipeError(Exception):
    pass


# ---------------------------------------------------------------- 存取

def _path_for(name):
    safe = re.sub(r"[^a-zA-Z0-9_一-鿿-]", "_", name or "")[:60]
    if not safe:
        raise RecipeError("剧本名不能为空")
    return os.path.join(RECIPE_DIR, safe + ".json")


def save(recipe):
    """写一份剧本。整表覆盖同名的。"""
    name = (recipe or {}).get("name")
    if not name:
        raise RecipeError("剧本缺少 name")
    steps = recipe.get("steps")
    if not isinstance(steps, list) or not steps:
        raise RecipeError("剧本至少要有一步")
    if len(steps) > MAX_STEPS:
        raise RecipeError("步骤太多（%d > %d）" % (len(steps), MAX_STEPS))
    for index, step in enumerate(steps):
        if not isinstance(step, dict) or not step.get("action"):
            raise RecipeError("第 %d 步没有 action" % (index + 1))
        if step["action"] not in ACTIONS:
            raise RecipeError("第 %d 步的 action「%s」不认识，可用：%s"
                              % (index + 1, step["action"], "、".join(sorted(ACTIONS))))
    os.makedirs(RECIPE_DIR, exist_ok=True)
    recipe = dict(recipe)
    recipe["saved_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    path = _path_for(name)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(recipe, fh, ensure_ascii=False, indent=2)
    os.replace(tmp, path)
    return path


def load(name):
    path = _path_for(name)
    if not os.path.exists(path):
        raise RecipeError("没有叫「%s」的剧本。用 ui_recipe_list 看有哪些。" % name)
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def listing():
    if not os.path.isdir(RECIPE_DIR):
        return []
    out = []
    for filename in sorted(os.listdir(RECIPE_DIR)):
        if not filename.endswith(".json"):
            continue
        try:
            with open(os.path.join(RECIPE_DIR, filename), "r", encoding="utf-8") as fh:
                recipe = json.load(fh)
        except Exception:
            continue
        out.append({
            "name": recipe.get("name"),
            "title": recipe.get("title") or recipe.get("name"),
            "description": recipe.get("description") or "",
            "app": recipe.get("app") or "",
            "steps": len(recipe.get("steps") or []),
            "params": [p.get("name") for p in (recipe.get("params") or [])],
        })
    return out


def delete(name):
    path = _path_for(name)
    if not os.path.exists(path):
        raise RecipeError("没有叫「%s」的剧本" % name)
    os.unlink(path)
    return path


# ---------------------------------------------------------------- 定位

def _readable(node):
    """一个元素身上所有能当"名字"用的文字。inferred_label 排第一——
    图标按钮的 title 是图标字体的乱码，真正的名字在兄弟节点上。"""
    for key in ("inferred_label", "title", "label", "value"):
        text = (node.get(key) or "").strip()
        if text:
            yield text


def _in_region(node, region):
    """元素落在指定的屏幕区域里吗。

    ⚠️ 这不是可有可无的过滤器。实测钉钉侧边栏「最近使用」里会出现一个叫「写日志」的
    小程序入口，而日志列表页的内容区里**也**有一个「写日志」按钮——两者文字一模一样，
    点错了进的是完全不同的界面。而且侧边栏那几项的名字和顺序**会随最近使用情况变**，
    没法靠"第几个"区分。区域是这里唯一稳的判据：侧边栏永远在左边那条窄的里。

    用坐标而不是元素路径，是因为路径一改版就废，而"内容区在右边"这件事
    比任何下标都稳。
    """
    if not region:
        return True
    frame = node.get("frame") or {}
    if not frame:
        return False           # 要求了区域却没坐标，宁可漏掉也不要点错
    x, y = frame.get("x", 0), frame.get("y", 0)
    if "x_min" in region and x < region["x_min"]: return False
    if "x_max" in region and x > region["x_max"]: return False
    if "y_min" in region and y < region["y_min"]: return False
    if "y_max" in region and y > region["y_max"]: return False
    return True


def find(nodes, wanted, role=None, exact=False, region=None):
    """在 inspect 结果里按文字找元素。返回 (节点, 说明)。

    优先完全相等再退到包含：「日志」在钉钉里既是侧边栏入口也出现在一堆消息标题里，
    只做包含匹配的话会点进某条聊天记录。
    """
    wanted = (wanted or "").strip()
    if not wanted:
        raise RecipeError("find 不能为空")

    candidates = [n for n in nodes if not role or n.get("role") == role]
    if region:
        candidates = [n for n in candidates if _in_region(n, region)]
    equal = [n for n in candidates if any(t == wanted for t in _readable(n))]
    if equal:
        return equal[0], "完全匹配"
    if exact:
        return None, "没有文字完全等于「%s」的元素" % wanted
    partial = [n for n in candidates if any(wanted in t for t in _readable(n))]
    if not partial:
        return None, "界面上找不到含「%s」的元素" % wanted
    # 多个候选时挑文字最短的：最短的那个通常就是标签本身，
    # 长的那些是把它当作子串包含进去的正文。
    partial.sort(key=lambda n: min(len(t) for t in _readable(n)))
    return partial[0], "包含匹配（%d 个候选里取文字最短的）" % len(partial)


def texts_of(nodes):
    out = []
    for node in nodes:
        for text in _readable(node):
            out.append(text)
            break
    return out


# ---------------------------------------------------------------- 执行

ACTIONS = {"open_app", "click", "press", "type", "expect", "read", "wait", "optional_click"}


class RecipeRun:
    """跑一遍剧本。`host` 提供三个回调，把 native 工具接进来。"""

    def __init__(self, recipe, params, host, emit=None, log=None):
        self.recipe = recipe
        self.params = params or {}
        self.host = host
        self.emit = emit or (lambda event: None)
        self.log = log or (lambda message: None)
        self.app = recipe.get("app") or ""
        self.trace = []
        self.readings = {}

    # -------------------------------------------------- 参数

    def substitute(self, text):
        """把 {{参数名}} 换成实参。缺参数直接报错，不留空——
        留空会让"填入空字符串"看起来像成功。"""
        if not isinstance(text, str):
            return text

        def replace(match):
            key = match.group(1).strip()
            if key not in self.params:
                raise RecipeError("剧本要一个叫「%s」的参数，但没有传" % key)
            return str(self.params[key])

        return re.sub(r"\{\{([^}]+)\}\}", replace, text)

    # -------------------------------------------------- 界面

    def inspect(self):
        result = self.host.inspect(self.app)
        if result.get("error"):
            raise RecipeError("读取「%s」界面失败：%s" % (self.app, result["error"]))
        return result.get("elements") or []

    def wait_for(self, wanted, timeout=8.0, role=None, region=None):
        """等某段文字出现。轮询而不是固定 sleep：界面快就快、慢就多等。"""
        wanted = self.substitute(wanted)
        deadline = time.time() + timeout
        last = []
        while time.time() < deadline:
            last = self.inspect()
            node, _ = find(last, wanted, role=role, region=region)
            if node:
                return node
            time.sleep(0.4)
        raise RecipeError(
            "等了 %.0fs 也没看到「%s」。当前界面上有：%s"
            % (timeout, wanted, "、".join(sorted(set(texts_of(last)))[:25]) or "（读不到任何文字）"))

    # -------------------------------------------------- 单步

    def run_step(self, index, step):
        action = step["action"]
        note = step.get("note") or ""
        described = "%d/%d %s%s" % (index + 1, len(self.recipe["steps"]), action,
                                    ("（%s）" % note) if note else "")
        self.emit({"type": "recipe_step", "step": index + 1,
                   "total": len(self.recipe["steps"]),
                   "action": action, "note": note})

        if action == "open_app":
            result = self.host.open_app(self.app)
            if result.get("error"):
                raise RecipeError("打开「%s」失败：%s" % (self.app, result["error"]))

        elif action in ("click", "press", "optional_click"):
            wanted = self.substitute(step.get("find") or "")
            nodes = self.inspect()
            node, why = find(nodes, wanted, role=step.get("role"),
                             exact=step.get("exact", False), region=step.get("region"))
            if not node:
                if action == "optional_click":
                    self.trace.append("%s → 没有「%s」，按剧本跳过" % (described, wanted))
                    return
                raise RecipeError(
                    "%s：%s。当前界面上有：%s"
                    % (described, why, "、".join(sorted(set(texts_of(nodes)))[:25])))
            how = "press" if action == "press" else "click"
            result = self.host.act(self.app, node["path"], how)
            if result.get("error"):
                raise RecipeError("%s：点「%s」失败：%s" % (described, wanted, result["error"]))
            self.trace.append("%s → 点了「%s」（%s）" % (described, wanted, why))

        elif action == "type":
            wanted = self.substitute(step.get("find") or "")
            text = self.substitute(step.get("text") or "")
            nodes = self.inspect()
            node, why = find(nodes, wanted, role=step.get("role"),
                             exact=step.get("exact", False), region=step.get("region"))
            if not node:
                raise RecipeError("%s：找不到要填的「%s」" % (described, wanted))
            # 先点一下让它拿到焦点。键盘事件是发给焦点的，不点的话字会落到别处。
            clicked = self.host.act(self.app, node["path"], "click")
            if clicked.get("error"):
                raise RecipeError("%s：点不动输入框「%s」：%s" % (described, wanted, clicked["error"]))
            time.sleep(0.3)
            typed = self.host.type_text(self.app, text)
            if typed.get("error"):
                raise RecipeError("%s：输入失败：%s" % (described, typed["error"]))
            self.trace.append("%s → 往「%s」敲了 %d 个字" % (described, wanted, len(text)))

        elif action in ("expect", "wait"):
            wanted = step.get("find") or ""
            timeout = float(step.get("timeout") or 8.0)
            self.wait_for(wanted, timeout=timeout, role=step.get("role"),
                          region=step.get("region"))
            self.trace.append("%s → 看到了「%s」" % (described, self.substitute(wanted)))

        elif action == "read":
            nodes = self.inspect()
            self.readings.update(self._read_sections(nodes, step))
            self.trace.append("%s → 读回 %d 项" % (described, len(self.readings)))

        else:
            raise RecipeError("不认识的 action：%s" % action)

        if step.get("expect"):
            # expect 要有自己的区域约束。踩过：钉钉侧边栏「最近使用」里恰好有个叫
            # 「写日志」的项，于是 expect:"写日志" 被侧边栏满足了——**内容区根本没变，
            # 验证却过了**。假阳性的验证比没有验证更糟：它让剧本带着错误状态继续点。
            # expect 检查的文字必须是"只在目标状态下才会出现"的，必要时用区域钉死。
            self.wait_for(step["expect"], timeout=float(step.get("expect_timeout") or 8.0),
                          region=step.get("expect_region"))
            self.trace.append("   ↳ 验证：界面上出现了「%s」" % self.substitute(step["expect"]))

        time.sleep(float(step.get("settle") or SETTLE))

    def _read_sections(self, nodes, step):
        """按"栏目标题 → 它后面的内容"读回文本。

        钉钉这类应用**填好的内容不在输入框的 AXValue 里**（读回来是空的），
        而是渲染成紧跟标题的静态文字。所以按界面顺序取标题之后、下一个标题之前
        的那些文字，比读输入框可靠。
        """
        sections = step.get("sections") or []
        if not sections:
            return {"全部文字": texts_of(nodes)[:80]}

        def order(node):
            return [int(x) if x.isdigit() else 0 for x in (node.get("path") or "").split("/")]

        ordered = sorted(nodes, key=order)
        flat = []
        for node in ordered:
            for text in _readable(node):
                flat.append(text)
                break

        skip = set(step.get("ignore") or [])
        out = {}
        current = None
        for text in flat:
            if text in sections:
                current = text
                out[current] = []
            elif current and text not in sections:
                if text in skip or len(text) <= 1:
                    continue
                out[current].append(text)
        # 只保留剧本点名要的那几栏，且把明显是别的控件的行留给调用方判断
        return {key: value for key, value in out.items() if key in sections}

    # -------------------------------------------------- 整体

    def run(self):
        steps = self.recipe.get("steps") or []
        if len(steps) > MAX_STEPS:
            raise RecipeError("步骤太多")
        started = time.time()
        self.emit({"type": "recipe_started", "name": self.recipe.get("name"),
                   "title": self.recipe.get("title") or self.recipe.get("name"),
                   "steps": len(steps), "app": self.app})
        try:
            for index, step in enumerate(steps):
                self.run_step(index, step)
        except RecipeError as exc:
            self.emit({"type": "recipe_done", "name": self.recipe.get("name"),
                       "ok": False, "step": len(self.trace) + 1})
            # 失败时把已经做过的步骤原样交出去。用户的真实应用已经被动过了，
            # 只说一句"失败"会让他不知道现在停在哪、要不要手动收拾。
            return {"error": str(exc),
                    "completed_steps": self.trace,
                    "note": "剧本中途停下了。上面是已经真实执行过的步骤——"
                            "界面现在停在最后一步之后的状态，不是原样。"}
        elapsed = time.time() - started
        self.emit({"type": "recipe_done", "name": self.recipe.get("name"),
                   "ok": True, "ms": int(elapsed * 1000)})
        result = {"ok": True,
                  "recipe": self.recipe.get("title") or self.recipe.get("name"),
                  "seconds": round(elapsed, 1),
                  "steps": self.trace}
        if self.readings:
            result["read"] = self.readings
        if self.recipe.get("stops_at"):
            result["stopped_at"] = self.recipe["stops_at"]
        return result
