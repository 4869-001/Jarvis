"""联网：搜索 + 抓正文。

DeepSeek 官方 API 没有内置搜索，只能自己做。后端优先级：
    Tavily（有 key，结果最适合喂模型）→ Brave（有 key）→ DuckDuckGo（免 key，兜底）
DDG 是 HTML 抓取，会随对方页面改动而失效，所以只当兜底，不当地基。
"""
import gzip
import html
import io
import json
import re
import ssl
import urllib.error
import urllib.parse
import urllib.request

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0 Safari/537.36")
_SSL = ssl.create_default_context()


def _fetch(url, data=None, headers=None, timeout=20):
    req = urllib.request.Request(url, data=data, method="POST" if data else "GET")
    req.add_header("User-Agent", UA)
    req.add_header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
    req.add_header("Accept-Encoding", "gzip")
    for key, value in (headers or {}).items():
        req.add_header(key, value)

    resp = urllib.request.urlopen(req, timeout=timeout, context=_SSL)
    try:
        blob = resp.read(6 * 1024 * 1024)
        if resp.headers.get("Content-Encoding") == "gzip":
            blob = gzip.GzipFile(fileobj=io.BytesIO(blob)).read()
        charset = resp.headers.get_content_charset() or "utf-8"
        return blob.decode(charset, "replace"), resp.geturl()
    finally:
        resp.close()


# ---------------------------------------------------------------- 搜索后端

def _search_tavily(query, count, key):
    body = json.dumps({
        "api_key": key, "query": query, "max_results": count,
        "search_depth": "basic", "include_answer": True,
    }).encode("utf-8")
    text, _ = _fetch("https://api.tavily.com/search", data=body,
                     headers={"Content-Type": "application/json"})
    payload = json.loads(text)
    results = [{
        "title": item.get("title", ""),
        "url": item.get("url", ""),
        "snippet": (item.get("content") or "")[:500],
    } for item in payload.get("results", [])]
    return results, payload.get("answer") or ""


def _search_brave(query, count, key):
    url = "https://api.search.brave.com/res/v1/web/search?" + urllib.parse.urlencode(
        {"q": query, "count": count})
    text, _ = _fetch(url, headers={"Accept": "application/json", "X-Subscription-Token": key})
    payload = json.loads(text)
    results = [{
        "title": item.get("title", ""),
        "url": item.get("url", ""),
        "snippet": _strip_tags(item.get("description") or "")[:500],
    } for item in (payload.get("web") or {}).get("results", [])]
    return results, ""


_DDG_ROW = re.compile(
    r'<a[^>]+class="result__a"[^>]+href="(?P<url>[^"]+)"[^>]*>(?P<title>.*?)</a>'
    r'.*?class="result__snippet"[^>]*>(?P<snippet>.*?)</a>',
    re.S,
)


def _search_duckduckgo(query, count):
    text, _ = _fetch("https://html.duckduckgo.com/html/",
                     data=urllib.parse.urlencode({"q": query}).encode("utf-8"),
                     headers={"Content-Type": "application/x-www-form-urlencoded"})
    results = []
    for match in _DDG_ROW.finditer(text):
        url = html.unescape(match.group("url"))
        # DDG 会把真实地址包在 /l/?uddg= 里
        if "uddg=" in url:
            parsed = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
            url = (parsed.get("uddg") or [url])[0]
        if url.startswith("//"):
            url = "https:" + url
        # y.js 是广告跳转位，喂给模型只会污染上下文
        if "duckduckgo.com/y.js" in url or url.startswith("https://duckduckgo.com/l/"):
            continue
        results.append({
            "title": _strip_tags(match.group("title")),
            "url": url,
            "snippet": _strip_tags(match.group("snippet"))[:500],
        })
        if len(results) >= count:
            break
    return results, ""


def web_search(args, ctx):
    query = (args.get("query") or "").strip()
    if not query:
        return {"error": "缺少 query"}

    cfg = ctx["search"]
    count = min(int(args.get("count") or cfg.get("max_results") or 5), 10)
    backend = cfg.get("backend", "auto")

    chain = []
    if backend in ("auto", "tavily") and cfg.get("tavily_api_key"):
        chain.append(("tavily", lambda: _search_tavily(query, count, cfg["tavily_api_key"])))
    if backend in ("auto", "brave") and cfg.get("brave_api_key"):
        chain.append(("brave", lambda: _search_brave(query, count, cfg["brave_api_key"])))
    if backend in ("auto", "duckduckgo"):
        chain.append(("duckduckgo", lambda: _search_duckduckgo(query, count)))

    if not chain:
        return {"error": "搜索后端 %s 未配置 API Key" % backend}

    failures = []
    for name, run in chain:
        try:
            results, answer = run()
        except Exception as exc:
            failures.append("%s: %s" % (name, exc))
            continue
        if not results:
            failures.append("%s: 无结果" % name)
            continue
        out = {"query": query, "backend": name, "count": len(results), "results": results}
        if answer:
            out["answer"] = answer
        return out

    return {"error": "所有搜索后端都失败了（%s）" % "；".join(failures)}


# ---------------------------------------------------------------- 抓正文

_DROP_BLOCKS = re.compile(r"<(script|style|noscript|svg|head)[^>]*>.*?</\1>", re.S | re.I)
_TAGS = re.compile(r"<[^>]+>")
_BLANKS = re.compile(r"\n{3,}")


def _strip_tags(fragment):
    return html.unescape(_TAGS.sub("", fragment)).strip()


def web_fetch(args, ctx):
    url = (args.get("url") or "").strip()
    if not url:
        return {"error": "缺少 url"}
    if not url.startswith(("http://", "https://")):
        url = "https://" + url

    try:
        text, final_url = _fetch(url, timeout=25)
    except urllib.error.HTTPError as exc:
        return {"error": "HTTP %s：%s" % (exc.code, url)}
    except Exception as exc:
        return {"error": "抓取失败：%s" % exc}

    title_match = re.search(r"<title[^>]*>(.*?)</title>", text, re.S | re.I)
    body = _DROP_BLOCKS.sub(" ", text)
    body = re.sub(r"<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>", "\n", body, flags=re.I)
    body = _BLANKS.sub("\n\n", _strip_tags(body))
    body = "\n".join(line.strip() for line in body.splitlines())
    body = _BLANKS.sub("\n\n", body)

    max_chars = min(int(args.get("max_chars") or 8000), ctx["max_output_chars"])
    return {
        "url": final_url,
        "title": _strip_tags(title_match.group(1)) if title_match else "",
        "truncated": len(body) > max_chars,
        "content": body[:max_chars],
    }
