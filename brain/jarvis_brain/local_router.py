"""不经过大模型的确定性意图路由。

只接管低歧义、可验证的常用指令；拿不准就返回 None，继续交给配置的推理模型。
这样既缩短播放/时间/身份问答的延迟，也避免让模型用“下一首”冒充歌曲搜索。
"""
import re
import time


def _clean_music_query(text):
    value = re.sub(r"^(?:请|帮我|麻烦你)?\s*(?:在\s*)?(?:网易云音乐|网易云)?\s*"
                   r"(?:搜索并播放|搜索播放|播放|放一下|放一首)\s*", "", text,
                   flags=re.I).strip(" ：:，,。.!！\"“”'")
    return value


def route(text, identity):
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

    match = re.match(r"^(?:请|帮我|麻烦你)?\s*(?:打开|启动|open)\s+?(.+?)\s*$", raw, re.I)
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
