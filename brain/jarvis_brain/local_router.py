"""不经过大模型的确定性意图路由。

只接管低歧义、可验证的常用指令；拿不准就返回 None，继续交给配置的推理模型。
这样既缩短播放/时间/身份问答的延迟，也避免让模型用“下一首”冒充歌曲搜索。
"""
import json
import re
import time

from . import weather as weather_mod


def _clean_music_query(text):
    value = re.sub(r"^(?:请|帮我|麻烦你)?\s*(?:在\s*)?(?:网易云音乐|网易云)?\s*"
                   r"(?:搜索并播放|搜索播放|播放|放一下|放一首)\s*", "", text,
                   flags=re.I).strip(" ：:，,。.!！\"“”'")
    return value


def route(text, identity, cfg=None):
    raw = (text or "").strip()
    folded = raw.casefold()

    if any(key in folded for key in ("谁创造了你", "谁创造的你", "你的创造者", "who created you")):
        creator = identity.data["creator"]
        return {"response": lambda _:
                ("I was created by %s, sir." % creator,
                 "我是由 %s 创造的，先生。" % creator)}

    if any(key in folded for key in ("你是谁", "你是什么", "who are you")):
        return {"response": lambda _:
                ("I am J.A.R.V.I.S., Frank's private intelligent assistant.",
                 "我是 J.A.R.V.I.S.，Frank 的私人智能助理。")}

    if any(key in folded for key in ("你诞生多久", "你被创造多久", "你多大", "how old are you")):
        def age_response(_):
            days, hours = identity.age()
            en = "I have been operational for %d day%s and %d hour%s, sir." % (
                days, "" if days == 1 else "s", hours, "" if hours == 1 else "s")
            zh = "我已经运行了 %d 天 %d 小时，先生。" % (days, hours)
            return en, zh
        return {"response": age_response}

    if any(key in folded for key in ("你的生日", "你的诞生日", "你什么时候被创造",
                                      "when were you created")):
        return {"response": lambda _:
                ("I was created on August 1st, 2026, sir.",
                 "我于 2026 年 8 月 1 日被创造，先生。")}

    if re.search(r"(现在)?几点|现在时间|what time is it|current time", folded):
        return {"response": lambda _:
                (time.strftime("%-I:%M %p") + ", sir.",
                 "现在是 " + time.strftime("%H:%M") + "，先生。")}

    if re.search(r"(今天)?(几号|日期)|what(?:'s| is) the date", folded):
        return {"response": lambda _:
                (time.strftime("%A, %B %-d, %Y") + ", sir.",
                 time.strftime("今天是 %Y 年 %-m 月 %-d 日，先生。"))}

    media_actions = (
        (("暂停音乐", "暂停播放", "pause the music", "pause playback"), "pause"),
        (("下一首", "切下一首", "next track", "next song"), "next"),
        (("上一首", "切上一首", "previous track", "previous song"), "previous"),
        (("继续播放", "恢复播放", "播放啊", "播放吧", "播放音乐",
          "resume playback", "play the music"), "play"),
        (("喜欢这首", "收藏这首", "like this song", "like this track"), "like"),
        (("现在放的什么", "这是什么歌", "what is playing", "what song is this"), "status"),
    )
    for phrases, action in media_actions:
        if any(phrase in folded for phrase in phrases):
            return _media_route(action)

    if re.match(r"^(?:请|帮我|麻烦你)?\s*(?:在\s*)?(?:网易云音乐|网易云)?\s*"
                r"(?:搜索并播放|搜索播放|播放|放一下|放一首)\s*\S+", raw, re.I):
        query = _clean_music_query(raw)
        if query:
            return _media_route("search_play", query=query)

    # ---- 天气：联网取数但不经过模型 ----
    if re.search(r"天气|气温|下雨|weather|temperature", folded):
        # 「XX 的天气」里把地名摘出来；摘不到就让数据源按 IP 自己定位。
        place = ((cfg or {}).get("weather") or {}).get("location") or ""
        # ⚠️ 非贪婪 + 显式去掉结尾的「的」。贪婪匹配会把「上海的」整个当成城市名
        # ——「的」也在中文字符区间里。「北京天气」没有「的」所以测不出来，
        # 「上海的天气」就 500 了。这类 bug 只在带「的」的说法上出现。
        spot = re.search(r"([\u4e00-\u9fa5A-Za-z]{2,12}?)\s*的?\s*天气", raw)
        if spot:
            named = spot.group(1).rstrip("的").strip()
            if named and named not in ("今天", "现在", "明天", "外面", "今日", "这里"):
                place = named          # 用户点名了城市就以他说的为准
        return {"response": lambda _: weather_mod.spoken(place)}

    # ---- 设备状态：全部来自本机，没有任何推理成分 ----
    if re.search(r"设备状态|本机状态|电脑状态|机器状态|系统状态|"
                 r"电量|电池|内存|磁盘|存储空间|剩余空间|"
                 r"device status|battery|memory|disk space", folded):
        return {"tool": "system_info", "arguments": {}, "response": _system_response(folded)}

    match = re.match(r"^(?:请|帮我|麻烦你)?\s*(?:打开|启动|开一下|开个|运行|open|launch)\s*(.+?)\s*$",
                     raw, re.I)
    if not match:
        # 「把 Safari 打开」「Safari 打开一下」这类倒装，前面那条正则接不住
        match = re.match(r"^(?:请|帮我|麻烦你)?\s*(?:把)?\s*(.+?)\s*(?:打开|启动|开一下)\s*$",
                         raw, re.I)
    if match and len(match.group(1)) <= 80:
        app = match.group(1).strip(" 。.!！")
        return {
            "tool": "app_open", "arguments": {"name": app},
            "response": lambda result: (
                ("%s is open, sir." % app) if "error" not in result
                else ("I couldn't open %s: %s" % (app, result["error"])),
                ("已打开 %s，先生。" % app) if "error" not in result
                else ("无法打开 %s：%s" % (app, result["error"])),
            ),
        }
    return None


def _system_response(folded):
    """把 system_info 的结果说成人话。问什么答什么——问电量就别把磁盘也报一遍。

    ⚠️ system_info 返回的是**已经排版好的中文字符串**（battery 是 "100%（充电中）"
    这种），不是结构化字段。所以这里用正则把数字抠出来再各说各话，
    别按字典去取——取不到，而且不会报错，只会静默少一段。
    """
    wants_battery = bool(re.search(r"电量|电池|battery", folded))
    wants_memory = bool(re.search(r"内存|memory", folded))
    wants_disk = bool(re.search(r"磁盘|存储空间|剩余空间|disk", folded))
    specific = wants_battery or wants_memory or wants_disk

    def response(result):
        if "error" in result:
            return ("I couldn't read the system status: %s" % result["error"],
                    "读取系统状态失败：%s" % result["error"])
        en, zh = [], []

        battery = str(result.get("battery") or "")
        if (wants_battery or not specific) and battery:
            level = re.search(r"(\d+)\s*%", battery)
            charging = "充电" in battery
            if level:
                en.append("battery %s%%%s" % (level.group(1), ", charging" if charging else ""))
                zh.append("电量 %s%%%s" % (level.group(1), "，充电中" if charging else ""))

        memory = str(result.get("memory") or "")
        if (wants_memory or not specific) and memory:
            pair = re.search(r"已用\s*([\d.]+)\s*/\s*([\d.]+)\s*GB", memory)
            if pair:
                en.append("memory %s of %sGB used" % (pair.group(1), pair.group(2)))
                zh.append("内存已用 %s / %s GB" % (pair.group(1), pair.group(2)))

        disk = str(result.get("disk") or "")
        if (wants_disk or not specific) and disk:
            free = re.search(r"剩余\s*([\d.]+)\s*GB", disk)
            if free:
                en.append("%sGB free on disk" % free.group(1))
                zh.append("磁盘剩余 %s GB" % free.group(1))

        if not en:
            # 解析不出来就把原文交出去，别硬编一句好听的。
            raw = json.dumps({k: result.get(k) for k in ("battery", "memory", "disk")},
                             ensure_ascii=False)
            return ("Here's the raw status: %s" % raw[:200], "当前状态：%s" % raw[:200])
        return ("%s%s, sir." % (en[0][0].upper(), ", ".join(en)[1:]), "%s，先生。" % "，".join(zh))
    return response


def _media_route(action, query=None):
    arguments = {"action": action, "player": "netease"}
    if query:
        arguments["query"] = query

    def response(result):
        if "error" in result:
            return "Music control failed: %s" % result["error"], "音乐控制失败：%s" % result["error"]
        if action == "search_play":
            title = result.get("title") or query
            artist = result.get("artist")
            if result.get("verified"):
                en = "Playing %s%s, sir." % (title, " by " + artist if artist else "")
                zh = "正在播放%s%s，先生。" % (title, " — " + artist if artist else "")
                return en, zh
            note = result.get("note") or "the selected track could not be verified"
            return "I found the results, but could not verify playback: %s" % note, \
                   "已找到搜索结果，但无法确认播放：%s" % note
        if action == "status":
            title = result.get("title")
            artist = result.get("artist")
            if title:
                return ("Playing %s%s, sir." % (title, " by " + artist if artist else ""),
                        "正在播放%s%s，先生。" % (title, " — " + artist if artist else ""))
            return "Nothing is playing, sir.", "目前没有音乐在播放，先生。"
        messages = {
            "pause": ("Playback paused, sir.", "已暂停播放，先生。"),
            "play": ("Playback resumed, sir.", "已继续播放，先生。"),
            "next": ("Next track, sir.", "已切换到下一首，先生。"),
            "previous": ("Previous track, sir.", "已切换到上一首，先生。"),
            "like": ("Added to your favourites, sir.", "已加入喜欢，先生。"),
        }
        return messages[action]

    return {"tool": "media_control", "arguments": arguments, "response": response}
