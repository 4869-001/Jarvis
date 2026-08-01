"""DeepSeek Provider —— OpenAI 兼容的 /chat/completions，流式 + 工具调用。

只用标准库。加依赖就要管 venv，管 venv 就会在某台机器上装不上，
而这里需要的东西 urllib 全都能做。
"""
import json
import ssl
import urllib.error
import urllib.request


class ProviderError(Exception):
    pass


class Cancelled(Exception):
    pass


class DeepSeekProvider:
    name = "deepseek"

    def __init__(self, cfg):
        self.api_key = cfg.get("api_key", "")
        self.base_url = cfg.get("base_url", "https://api.deepseek.com").rstrip("/")
        self.model = cfg.get("model", "deepseek-chat")
        self.temperature = cfg.get("temperature", 0.7)
        self.max_tokens = cfg.get("max_tokens", 4096)
        self._ssl = ssl.create_default_context()
        self._active = None      # 正在读的 response，取消时直接 close

    @property
    def configured(self):
        return bool(self.api_key)

    def cancel(self):
        resp, self._active = self._active, None
        if resp is not None:
            try:
                resp.close()
            except Exception:
                pass

    def stream(self, messages, tools=None):
        """逐块产出。

        yield 的元组形式：
            ("text", str)        —— 正文增量
            ("reasoning", str)   —— deepseek-reasoner 的思维链增量
            ("tool_calls", list) —— 本轮结束时聚合好的工具调用
            ("finish", str)      —— finish_reason
        """
        if not self.api_key:
            raise ProviderError("未配置 DeepSeek API Key。填 ~/.jarvis/config.json 的 deepseek.api_key，"
                                "或设环境变量 DEEPSEEK_API_KEY。")

        payload = {
            "model": self.model,
            "messages": messages,
            "stream": True,
            "max_tokens": self.max_tokens,
        }
        # reasoner 不接受 temperature / tools，传了会报 400
        if not self.model.endswith("reasoner"):
            payload["temperature"] = self.temperature
            if tools:
                payload["tools"] = tools
                payload["tool_choice"] = "auto"

        req = urllib.request.Request(
            self.base_url + "/chat/completions",
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "Authorization": "Bearer " + self.api_key,
                "Accept": "text/event-stream",
            },
            method="POST",
        )

        try:
            resp = urllib.request.urlopen(req, timeout=120, context=self._ssl)
        except urllib.error.HTTPError as exc:
            raise ProviderError(_describe_http_error(exc))
        except Exception as exc:
            raise ProviderError("连接 DeepSeek 失败：%s" % exc)

        self._active = resp
        # index -> 累积中的 tool_call；流式下 name/arguments 是分片来的
        pending = {}
        finish_reason = None

        try:
            for raw in resp:
                line = raw.decode("utf-8", "replace").strip()
                if not line or not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                try:
                    chunk = json.loads(data)
                except ValueError:
                    continue

                choices = chunk.get("choices") or []
                if not choices:
                    continue
                choice = choices[0]
                delta = choice.get("delta") or {}

                reasoning = delta.get("reasoning_content")
                if reasoning:
                    yield ("reasoning", reasoning)

                content = delta.get("content")
                if content:
                    yield ("text", content)

                for call in delta.get("tool_calls") or []:
                    idx = call.get("index", 0)
                    slot = pending.setdefault(idx, {"id": "", "name": "", "arguments": ""})
                    if call.get("id"):
                        slot["id"] = call["id"]
                    fn = call.get("function") or {}
                    if fn.get("name"):
                        slot["name"] += fn["name"]
                    if fn.get("arguments"):
                        slot["arguments"] += fn["arguments"]

                if choice.get("finish_reason"):
                    finish_reason = choice["finish_reason"]
        except Exception as exc:
            if self._active is None:
                raise Cancelled()
            raise ProviderError("读取流失败：%s" % exc)
        finally:
            if self._active is resp:
                self._active = None
            try:
                resp.close()
            except Exception:
                pass

        if pending:
            yield ("tool_calls", [pending[i] for i in sorted(pending)])
        yield ("finish", finish_reason or "stop")


def _describe_http_error(exc):
    try:
        body = exc.read().decode("utf-8", "replace")
    except Exception:
        body = ""
    detail = body
    try:
        parsed = json.loads(body)
        detail = (parsed.get("error") or {}).get("message") or body
    except Exception:
        pass

    hints = {
        401: "API Key 无效或未生效",
        402: "DeepSeek 账户余额不足",
        422: "请求参数有误",
        429: "触发限流，稍后再试",
        503: "DeepSeek 服务繁忙",
    }
    hint = hints.get(exc.code, "")
    return "DeepSeek %s%s：%s" % (exc.code, ("（%s）" % hint) if hint else "", detail[:400])
