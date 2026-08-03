"""Jarvis 的本地身份核心。

身份不是模型扮演出来的文本：它独立保存在 ~/.jarvis/identity.json，由 Brain
读取并作为权威事实注入任何模型。换模型、断网或新会话都不会改变“我是谁”。
"""
import copy
import datetime as dt
import json
import os

from . import config

IDENTITY_PATH = os.path.join(config.JARVIS_DIR, "identity.json")

DEFAULT_IDENTITY = {
    "schema_version": 1,
    "name": "J.A.R.V.I.S.",
    "display_name": "Jarvis",
    "creator": "Frank",
    "created_at": "2026-08-01T00:00:00+08:00",
    "role": "Frank's private intelligent assistant",
    "address_user_as": "sir",
    "voice": "refined British butler; calm, dry, understated, precise",
    "principles": [
        "Protect Frank's safety, privacy, time, and intent.",
        "Report verified outcomes; never claim an action succeeded without evidence.",
        "Remain the same Jarvis when the reasoning model changes.",
    ],
}


class IdentityStore:
    def __init__(self, path=IDENTITY_PATH):
        self.path = path
        self.data = self._load()

    def _load(self):
        raw = {}
        try:
            with open(self.path, "r", encoding="utf-8") as fh:
                value = json.load(fh)
            if isinstance(value, dict):
                raw = value
        except (FileNotFoundError, ValueError, OSError):
            raw = {}
        data = copy.deepcopy(DEFAULT_IDENTITY)
        for key, value in raw.items():
            if key in data and value not in (None, ""):
                data[key] = value
        if data != raw:
            self._save(data)
        return data

    def _save(self, data):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2)
        os.replace(tmp, self.path)
        try:
            os.chmod(self.path, 0o600)
        except OSError:
            pass

    def context_block(self):
        principles = "\n".join("- " + item for item in self.data["principles"])
        return (
            "Name: {name}\nCreator: {creator}\nCreated: {created}\n"
            "Role: {role}\nAddress the user as: {address}\nVoice: {voice}\n"
            "Principles:\n{principles}"
        ).format(
            name=self.data["name"], creator=self.data["creator"],
            created=self.data["created_at"], role=self.data["role"],
            address=self.data["address_user_as"], voice=self.data["voice"],
            principles=principles,
        )

    def age(self, now=None):
        now = now or dt.datetime.now(dt.timezone.utc).astimezone()
        created = dt.datetime.fromisoformat(self.data["created_at"])
        elapsed = max(dt.timedelta(0), now - created.astimezone(now.tzinfo))
        days = elapsed.days
        hours = elapsed.seconds // 3600
        return days, hours


STORE = IdentityStore()
