"""天气：联网取数，但**不经过大模型**。

放在本地路由那条链路上的理由和时间、打开应用一样：这是个确定性查询，
答案只取决于数据源，不需要推理。走模型的话每问一次天气就是一轮完整的
工具调用往返——几千 token 的工具表 + 系统提示，只为拿回一个温度。

数据源用 wttr.in 的 j1 接口：免 key、免注册，不填地点时按出口 IP 定位。
Brain「只用标准库」这条底线在这里照样成立，urllib 够用。

天气描述**在本地翻译**，不靠接口的多语言字段——实测 j1 的 `lang_zh` 仍然返回英文，
而 `weatherCode` 是一组固定的数字码，本地映射既准确又零成本。
"""
import json
import ssl
import threading
import time
import urllib.parse
import urllib.request

ENDPOINT = "https://wttr.in/%s?format=j1"
_SSL = ssl.create_default_context()

# 缓存：天气不会一分钟变一次，而用户可能连着问好几遍（"今天天气""要带伞吗"）。
# 每次都打网络既慢又没必要。
_CACHE_SECONDS = 600
_cache = {}
_lock = threading.Lock()

# WorldWeatherOnline 的天气码 → (英文, 中文)。
# 用码而不是用接口给的描述字符串：描述字符串会随接口措辞变，码是稳定的。
CODES = {
    113: ("Clear", "晴"),
    116: ("Partly cloudy", "多云"),
    119: ("Cloudy", "阴"),
    122: ("Overcast", "阴沉"),
    143: ("Misty", "有雾"),
    176: ("Patchy rain nearby", "附近有零星降雨"),
    179: ("Patchy snow", "零星小雪"),
    182: ("Patchy sleet", "零星雨夹雪"),
    185: ("Patchy freezing drizzle", "零星冻毛毛雨"),
    200: ("Thundery outbreaks", "有雷阵雨"),
    227: ("Blowing snow", "吹雪"),
    230: ("Blizzard", "暴风雪"),
    248: ("Foggy", "有雾"),
    260: ("Freezing fog", "冻雾"),
    263: ("Patchy light drizzle", "零星毛毛雨"),
    266: ("Light drizzle", "毛毛雨"),
    281: ("Freezing drizzle", "冻毛毛雨"),
    284: ("Heavy freezing drizzle", "强冻毛毛雨"),
    293: ("Patchy light rain", "零星小雨"),
    296: ("Light rain", "小雨"),
    299: ("Moderate rain at times", "间歇中雨"),
    302: ("Moderate rain", "中雨"),
    305: ("Heavy rain at times", "间歇大雨"),
    308: ("Heavy rain", "大雨"),
    311: ("Light freezing rain", "冻雨"),
    314: ("Heavy freezing rain", "强冻雨"),
    317: ("Light sleet", "小雨夹雪"),
    320: ("Heavy sleet", "大雨夹雪"),
    323: ("Patchy light snow", "零星小雪"),
    326: ("Light snow", "小雪"),
    329: ("Patchy moderate snow", "零星中雪"),
    332: ("Moderate snow", "中雪"),
    335: ("Patchy heavy snow", "零星大雪"),
    338: ("Heavy snow", "大雪"),
    350: ("Ice pellets", "冰粒"),
    353: ("Light rain shower", "阵雨"),
    356: ("Heavy rain shower", "强阵雨"),
    359: ("Torrential rain shower", "暴雨"),
    362: ("Light sleet showers", "阵雨夹雪"),
    365: ("Heavy sleet showers", "强阵雨夹雪"),
    368: ("Light snow showers", "阵雪"),
    371: ("Heavy snow showers", "强阵雪"),
    374: ("Light ice pellet showers", "小冰粒"),
    377: ("Heavy ice pellet showers", "强冰粒"),
    386: ("Thundery showers", "雷阵雨"),
    389: ("Heavy thundery showers", "强雷阵雨"),
    392: ("Thundery snow showers", "雷阵雪"),
    395: ("Heavy thundery snow showers", "强雷阵雪"),
}


# 常用中文城市名 → 拼音。wttr.in 中文名也能认，但 URL 短、命中稳定，
# 而且这个免费服务**会限流抖动**（实测同一个城市名先 500 后 200），
# 少一个不确定因素是一个。
CITIES = {
    "北京": "Beijing", "上海": "Shanghai", "广州": "Guangzhou", "深圳": "Shenzhen",
    "西安": "Xian", "成都": "Chengdu", "杭州": "Hangzhou", "南京": "Nanjing",
    "武汉": "Wuhan", "重庆": "Chongqing", "天津": "Tianjin", "苏州": "Suzhou",
    "长沙": "Changsha", "郑州": "Zhengzhou", "青岛": "Qingdao", "合肥": "Hefei",
    "济南": "Jinan", "厦门": "Xiamen", "福州": "Fuzhou", "昆明": "Kunming",
    "大连": "Dalian", "沈阳": "Shenyang", "哈尔滨": "Harbin", "长春": "Changchun",
    "石家庄": "Shijiazhuang", "太原": "Taiyuan", "南昌": "Nanchang", "贵阳": "Guiyang",
    "南宁": "Nanning", "兰州": "Lanzhou", "银川": "Yinchuan", "西宁": "Xining",
    "乌鲁木齐": "Urumqi", "呼和浩特": "Hohhot", "拉萨": "Lhasa", "海口": "Haikou",
    "无锡": "Wuxi", "宁波": "Ningbo", "temperature": "", "香港": "Hong Kong",
    "澳门": "Macau", "台北": "Taipei",
}


def _normalize(location):
    key = (location or "").strip()
    return CITIES.get(key, key)


def _describe(code):
    return CODES.get(int(code or 0), ("Unsettled", "天气多变"))


def fetch(location="", timeout=6.0):
    """拿一份当前天气。失败时抛异常，由调用方决定怎么说。"""
    asked = (location or "").strip()          # 用户原话里的城市名，用于显示
    location = _normalize(location)
    key = (location or "").strip().lower()
    with _lock:
        hit = _cache.get(key)
        if hit and time.time() - hit[0] < _CACHE_SECONDS:
            return hit[1]

    url = ENDPOINT % urllib.parse.quote(location or "")
    request = urllib.request.Request(url, headers={
        # wttr.in 对普通 UA 返回 ASCII 图，带 curl 标识才稳定给 JSON
        "User-Agent": "curl/8.4.0",
        "Accept": "application/json",
    })
    # wttr.in 偶发 500（实测同一个城市名先失败后成功）。重试一次就够，
    # 别更多——这条路径是同步的，用户在等着听回答。
    payload = None
    last = None
    for attempt in range(2):
        try:
            with urllib.request.urlopen(request, timeout=timeout, context=_SSL) as response:
                payload = json.loads(response.read().decode("utf-8", "replace"))
            break
        except Exception as exc:
            last = exc
            if attempt == 0:
                time.sleep(0.6)
    if payload is None:
        # wttr.in 是免费服务，会限流。手里有过期数据的话，报一句"几分钟前的"
        # 远好过"连不上"——天气本来就不是秒级变化的东西。
        with _lock:
            stale = _cache.get(key)
        if stale:
            data = dict(stale[1])
            data["stale_minutes"] = int((time.time() - stale[0]) / 60)
            return data
        raise last

    current = (payload.get("current_condition") or [{}])[0]
    today = (payload.get("weather") or [{}])[0]
    area = (payload.get("nearest_area") or [{}])[0]

    def first(node, field):
        items = node.get(field) or [{}]
        return (items[0] or {}).get("value") or ""

    english, chinese = _describe(current.get("weatherCode"))
    # 用用户问的城市名显示，而不是接口返回的最近气象站名——
    # 上海会回 "Pootung"、深圳会回 "Ma Tso Lung"，听起来像答非所问。
    station = first(area, "areaName")
    data = {
        "place_en": location or station or "your area",
        "place_zh": asked or location or station or "当前位置",
        "temp": current.get("temp_C"),
        "feels": current.get("FeelsLikeC"),
        "low": today.get("mintempC"),
        "high": today.get("maxtempC"),
        "humidity": current.get("humidity"),
        "wind": current.get("windspeedKmph"),
        "desc_en": english,
        "desc_zh": chinese,
    }
    with _lock:
        _cache[key] = (time.time(), data)
    return data


def spoken(location="", timeout=6.0):
    """返回 (英文, 中文) 两句话。这条链路不经过模型，措辞就在这里定死。"""
    try:
        w = fetch(location, timeout=timeout)
    except Exception as exc:
        return ("I couldn't reach the weather service just now, sir.",
                "暂时连不上天气服务，先生。（%s）" % str(exc)[:60])

    en = "%s in %s, %s°C, feels like %s. Today %s to %s°C, humidity %s%%." % (
        w["desc_en"], w["place_en"], w["temp"], w["feels"], w["low"], w["high"], w["humidity"])
    zh = "%s，%s，%s°C，体感 %s°C。今天 %s 到 %s°C，湿度 %s%%。" % (
        w["place_zh"], w["desc_zh"], w["temp"], w["feels"], w["low"], w["high"], w["humidity"])
    stale = w.get("stale_minutes")
    if stale:
        # 说清楚这是旧数据。不说的话用户会拿几十分钟前的天气当此刻的。
        en += " That reading is %d minutes old — the service is unreachable right now." % stale
        zh += "（这是 %d 分钟前的数据，天气服务当前连不上）" % stale
    return en + " Sir.", zh + "先生。"
