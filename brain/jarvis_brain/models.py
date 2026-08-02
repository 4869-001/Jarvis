"""可配置的模型列表。

内置一个 "default" 条目，代表 config.json 里的 cfg["deepseek"]——不落盘，
永远存在，删不掉。用户加的都是自定义 OpenAI 兼容端点，存在 ~/.jarvis/models.json，
持久化模式照抄 memory.py 的 MemoryStore：单文件 JSON、整体读写、原子替换、
chmod 600。

DeepSeekProvider 本身就是通用的 OpenAI 兼容 /chat/completions 客户端，不是
DeepSeek 专属实现——加新模型不需要新的 Provider 类，喂给它一个
{api_key, base_url, model, ...} dict 就够。这个文件只负责管这份 dict 从哪来。
"""
import json
import os
import threading
import time
import uuid

from . import config

MODELS_PATH = os.path.join(config.JARVIS_DIR, "models.json")
DEFAULT_MODEL_ID = "default"
DEFAULT_LABEL = "默认"

# 自定义模型复用这套采样参数默认值，跟 config.DEFAULTS["deepseek"] 保持一致——
# 大多数 OpenAI 兼容端点都认这几个字段，没必要为每个模型单独配一套。
_SAMPLING_DEFAULTS = {
    "temperature": 0.7,
    "max_tokens": 4096,
    "frequency_penalty": 0.4,
}


class ModelStore:
    def __init__(self, path=MODELS_PATH):
        self.path = path
        self._lock = threading.RLock()
        self._entries = []          # 只存自定义模型，default 不落盘
        self._active = DEFAULT_MODEL_ID
        self._loaded = False

    # ------------------------------------------------------------ 持久化

    def _load(self):
        if self._loaded:
            return
        self._loaded = True
        try:
            with open(self.path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
        except FileNotFoundError:
            return
        except Exception:
            # 文件坏了不能让 Brain 起不来，留个副本，从空的重新开始。
            try:
                os.replace(self.path, self.path + ".corrupt")
            except Exception:
                pass
            return

        if not isinstance(data, dict):
            return
        entries = data.get("entries")
        if isinstance(entries, list):
            self._entries = [e for e in entries if isinstance(e, dict) and e.get("id")]
        active = data.get("active")
        if isinstance(active, str) and active:
            self._active = active

    def _save(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".tmp"
        payload = {"version": 1, "active": self._active, "entries": self._entries}
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=1)
        os.replace(tmp, self.path)          # 原子替换，崩在中途也不会剩半个文件
        try:
            os.chmod(self.path, 0o600)      # 里面有 API Key，权限跟 config.json 一个规格
        except OSError:
            pass

    # ------------------------------------------------------------ 读

    def _default_entry(self, deepseek_cfg):
        return {"id": DEFAULT_MODEL_ID, "label": DEFAULT_LABEL,
                "model": (deepseek_cfg or {}).get("model", ""), "builtin": True}

    def list_public(self, deepseek_cfg):
        """给前端渲染用。不含 api_key/base_url——这份数据要经过 IPC 到网页里，
        真正带 key 的 dict 只在 get_provider_cfg() 里流转，不出宿主进程。"""
        with self._lock:
            self._load()
            items = [self._default_entry(deepseek_cfg)]
            for entry in self._entries:
                items.append({"id": entry["id"], "label": entry.get("label") or entry["id"],
                              "model": entry.get("model", ""),
                              "base_url": entry.get("base_url", ""),
                              "has_api_key": bool(entry.get("api_key")), "builtin": False})
            return items

    def get_provider_cfg(self, model_id, deepseek_cfg):
        """返回可以直接喂给 DeepSeekProvider(...) 的完整 dict（含 key）。
        model_id 不存在时返回 None。"""
        if model_id == DEFAULT_MODEL_ID or not model_id:
            return deepseek_cfg
        with self._lock:
            self._load()
            entry = next((e for e in self._entries if e["id"] == model_id), None)
        if not entry:
            return None
        cfg = dict(_SAMPLING_DEFAULTS)
        cfg.update({
            "api_key": entry.get("api_key", ""),
            "base_url": entry.get("base_url", ""),
            "model": entry.get("model", ""),
        })
        return cfg

    def active_id(self):
        with self._lock:
            self._load()
            return self._active

    # ------------------------------------------------------------ 写

    def add(self, label, base_url, api_key, model):
        label = (label or "").strip()
        base_url = (base_url or "").strip().rstrip("/")
        api_key = (api_key or "").strip()
        model = (model or "").strip()
        if not label or not base_url or not model:
            raise ValueError("名称、Base URL、模型名称都不能为空")

        with self._lock:
            self._load()
            entry = {
                "id": uuid.uuid4().hex[:8],
                "label": label,
                "base_url": base_url,
                "api_key": api_key,
                "model": model,
                "created": time.time(),
            }
            self._entries.append(entry)
            self._save()
            return entry

    def remove(self, model_id):
        if model_id == DEFAULT_MODEL_ID:
            raise ValueError("默认模型不能删除")
        with self._lock:
            self._load()
            entry = next((e for e in self._entries if e["id"] == model_id), None)
            if not entry:
                return None
            self._entries.remove(entry)
            if self._active == model_id:
                self._active = DEFAULT_MODEL_ID
            self._save()
            return entry

    def update(self, model_id, label, base_url, api_key, model):
        if model_id == DEFAULT_MODEL_ID:
            raise ValueError("默认模型请在 config.json 中修改")
        label = (label or "").strip()
        base_url = (base_url or "").strip().rstrip("/")
        model = (model or "").strip()
        if not label or not base_url or not model:
            raise ValueError("名称、Base URL、模型名称都不能为空")
        with self._lock:
            self._load()
            entry = next((e for e in self._entries if e["id"] == model_id), None)
            if not entry:
                raise ValueError("模型不存在")
            entry.update({"label": label, "base_url": base_url, "model": model,
                          "updated": time.time()})
            if (api_key or "").strip():
                entry["api_key"] = api_key.strip()
            self._save()
            return entry

    def set_active(self, model_id):
        with self._lock:
            self._load()
            self._active = model_id
            self._save()


STORE = ModelStore()
