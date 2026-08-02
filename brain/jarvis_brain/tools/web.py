"""联网：搜索 + 抓正文。

DeepSeek 官方 API 没有内置搜索，只能自己做。后端优先级：
    Tavily（有 key，结果最适合喂模型）→ Brave（有 key）→ DuckDuckGo（免 key，兜底）
DDG 是 HTML 抓取，会随对方页面改动而失效，所以只当兜底，不当地基。
"""
import gzip
import html
import io
import ipaddress
import json
import re
import socket
import ssl
import urllib.error
import urllib.parse
import urllib.request

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0 Safari/537.36")
_SSL = ssl.create_default_context()


# ---------------------------------------------------------------- SSRF 防线
#
# web_fetch 的 url 直接来自模型（可能是网页提示注入喂给它的），而且是 L1 工具，
# 不经用户确认就会跑。不拦的话它能拿来当探测内网的跳板：127.0.0.1、私网段、
# 甚至先解析出一个公网地址、跳转时再 302 到内网。所以请求前和每次跳转后都要
# 把目标地址解出来，过一遍"是不是本机/内网"这道检查。
# search 那几个后端打的是固定的可信 API 域名，不走这道检查。

_BLOCKED_HOSTNAMES = {"localhost", "localhost.localdomain"}

# 只挡 loopback / RFC1918 私网 / link-local / multicast 这几段真正意义上的
# "内网或本机"——不用 ipaddress 自带的 is_private/is_reserved，那两个在新版
# Python 里把 IANA 保留段（比如 198.18.0.0/15 benchmarking）也算了进去，而不少
# 本地代理（Clash/mihomo 之类的 fake-ip DNS）恰好借用这段地址做透明代理，
# 挡了它们会导致所有正常网页都抓不到。
_BLOCKED_NETWORKS = [ipaddress.ip_network(cidr) for cidr in (
    "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
    "169.254.0.0/16", "0.0.0.0/8",
    "::1/128", "fe80::/10", "fc00::/7",
)]


def _is_blocked_ip(ip_str):
    try:
        ip = ipaddress.ip_address(ip_str)
    except ValueError:
        return True   # 解析不出来的地址，宁可拦下来
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
        ip = ip.ipv4_mapped   # ::ffff:127.0.0.1 这类映射地址，按内层 IPv4 判断
    if ip.is_multicast or ip.is_unspecified:
        return True
    return any(ip in net for net in _BLOCKED_NETWORKS)


def _check_host_allowed(hostname):
    if not hostname:
        raise ValueError("URL 缺少主机名")
    host = hostname.strip().lower().rstrip(".")
    if host in _BLOCKED_HOSTNAMES:
        raise ValueError("不允许访问本机地址：%s" % hostname)
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror as exc:
        raise ValueError("域名解析失败：%s" % exc)
    for info in infos:
        ip = info[4][0]
        if _is_blocked_ip(ip):
            raise ValueError("不允许访问内网/本机地址：%s（%s）" % (hostname, ip))


class _SafeRedirectHandler(urllib.request.HTTPRedirectHandler):
    """跳转目标也要过一遍检查——公网地址 302 到内网是最常见的绕过手法。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        _check_host_allowed(urllib.parse.urlparse(newurl).hostname)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_SAFE_OPENER = urllib.request.build_opener(
    _SafeRedirectHandler, urllib.request.HTTPSHandler(context=_SSL))


def _fetch(url, data=None, headers=None, timeout=20, check_ssrf=False):
    if check_ssrf:
        _check_host_allowed(urllib.parse.urlparse(url).hostname)

    req = urllib.request.Request(url, data=data, method="POST" if data else "GET")
    req.add_header("User-Agent", UA)
    req.add_header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
    req.add_header("Accept-Encoding", "gzip")
    for key, value in (headers or {}).items():
        req.add_header(key, value)

    if check_ssrf:
        resp = _SAFE_OPENER.open(req, timeout=timeout)
    else:
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
        text, final_url = _fetch(url, timeout=25, check_ssrf=True)
    except urllib.error.HTTPError as exc:
        return {"error": "HTTP %s：%s" % (exc.code, url)}
    except ValueError as exc:
        return {"error": str(exc)}
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
