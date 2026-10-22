import os
import tempfile

# ต้องตั้งก่อน import april (settings อ่าน env ตอน import) — ไม่แตะข้อมูลจริง ไม่แจ้งเตือนขึ้นจอ ไม่ใช้คีย์จริงจาก .env
os.environ["APRIL_DATA_DIR"] = tempfile.mkdtemp(prefix="april-test-")
os.environ["APRIL_NOTIFY_MAC"] = "false"
os.environ["APRIL_BRIEFING_TIME"] = ""
for key in ("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY", "OLLAMA_API_KEY"):
    os.environ[key] = ""

import pytest  # noqa: E402

from april.llm.catalog import Catalog, ModelEntry  # noqa: E402
from april.llm.types import LLMResponse, ToolCall  # noqa: E402
from april.memory.store import Store  # noqa: E402


class FakeProvider:
    """ตอบตามสคริปต์: รายการของ LLMResponse หรือ callable(entry, messages, tools) -> LLMResponse"""

    def __init__(self, script):
        self.script = list(script)
        self.calls = []

    async def generate(self, entry, messages, tools, on_event=None):
        self.calls.append({"entry": entry.id, "messages": [dict(m) for m in messages], "tools": [t.name for t in tools]})
        step = self.script.pop(0)
        res = step(entry, messages, tools) if callable(step) else step
        res.model = entry.id
        if res.ok and res.text and on_event:
            on_event("token", res.text)
            res.streamed = True
        return res


def reply(text="", calls=(), error=None):
    return LLMResponse(text=text, tool_calls=[ToolCall(f"c{i}", n, a) for i, (n, a) in enumerate(calls)], error=error)


def catalog(cloud_ready=False):
    local = ModelEntry(id="local", provider="fake_local", model="tiny", local=True)
    cloud = ModelEntry(id="cloud", provider="fake_cloud", model="big", api_key_env="FAKE_KEY")
    if cloud_ready:
        os.environ["FAKE_KEY"] = "k"
    else:
        os.environ.pop("FAKE_KEY", None)
    return Catalog(local=local, cloud=[cloud], auto_order=["cloud"])


@pytest.fixture
def store():
    return Store(":memory:")
