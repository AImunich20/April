"""
april/llm/catalog.py
----------------------
โหลด models.yaml -> ModelEntry (โมเดลในเครื่อง 1 ตัว + cloud หลายตัว) และบอกว่าตัวไหนพร้อมใช้
"""

import os
import re
from dataclasses import dataclass, field
from pathlib import Path

import yaml

from april.config import settings

_ENV = re.compile(r"\$\{([A-Z0-9_]+)(?::([^}]*))?\}")


def _expand(value):
    if isinstance(value, str):
        return _ENV.sub(lambda m: os.environ.get(m.group(1)) or _dotenv().get(m.group(1)) or (m.group(2) or ""), value)
    if isinstance(value, dict):
        return {k: _expand(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_expand(v) for v in value]
    return value


def _dotenv() -> dict:
    """ค่าใน .env (pydantic-settings อ่านเฉพาะฟิลด์ของ Settings — ตัวแปรอื่นที่ models.yaml อ้างต้องอ่านเอง)"""
    path = Path(settings.model_config["env_file"])
    out = {}
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return out


@dataclass
class ModelEntry:
    id: str
    provider: str                 # ollama | ollama_cloud | anthropic | openai | gemini | openai_compat
    model: str
    label: str = ""
    local: bool = False
    api_key_env: str = ""
    base_url: str = ""
    effort: str = ""
    think: bool | None = None
    options: dict = field(default_factory=dict)

    @property
    def api_key(self) -> str:
        return settings.key(self.api_key_env) or (os.environ.get(self.api_key_env, "") if self.api_key_env else "")

    def ready(self) -> bool:
        """ตั้งค่าครบพอจะลองเรียกได้ (ไม่ได้รับประกันว่าออนไลน์)"""
        if not self.model:
            return False
        return self.local or bool(self.api_key)

    def describe(self) -> dict:
        return {"id": self.id, "provider": self.provider, "model": self.model, "label": self.label or self.model,
                "local": self.local, "ready": self.ready()}


@dataclass
class Catalog:
    local: ModelEntry
    cloud: list[ModelEntry]
    auto_order: list[str]

    def get(self, model_id: str) -> ModelEntry | None:
        if model_id == self.local.id:
            return self.local
        return next((m for m in self.cloud if m.id == model_id), None)

    def all(self) -> list[ModelEntry]:
        return [self.local, *self.cloud]

    def chain(self, requested: str | None) -> list[ModelEntry]:
        """ลำดับที่จะลอง: ตัวที่ขอ (หรือ auto_order) ที่พร้อม แล้วปิดท้ายด้วยโมเดลในเครื่องเสมอ"""
        requested = requested or settings.default_model
        if requested == "auto":
            first = [m for m in (self.get(i) for i in self.auto_order) if m and m.ready()]
        else:
            entry = self.get(requested)
            if entry is None:
                raise KeyError(f"ไม่รู้จักโมเดล '{requested}' (ดู GET /models)")
            first = [entry] if entry.ready() else []
        return [m for m in first if not m.local] + [self.local]


def load_catalog(path: Path | None = None) -> Catalog:
    data = _expand(yaml.safe_load(Path(path or settings.models_file).read_text(encoding="utf-8")))
    loc = data["local"]
    local = ModelEntry(id=loc.get("id", "local"), provider=loc.get("provider", "ollama"), model=loc["model"],
                       label=loc.get("label", ""), local=True, think=loc.get("think"),
                       options=loc.get("options") or {})
    cloud = [ModelEntry(id=c["id"], provider=c["provider"], model=c.get("model") or "", label=c.get("label", ""),
                        api_key_env=c.get("api_key_env", ""), base_url=c.get("base_url", ""),
                        effort=c.get("effort", ""), think=c.get("think"), options=c.get("options") or {})
             for c in data.get("cloud") or []]
    return Catalog(local=local, cloud=cloud, auto_order=list(data.get("auto_order") or [c.id for c in cloud]))
