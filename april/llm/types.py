"""
april/llm/types.py
--------------------
รูปแบบข้อมูลกลางที่ทุก provider ใช้ร่วมกัน (provider แปลงเป็นรูปแบบของตัวเองตอนส่ง)

ข้อความ (dict ธรรมดา เก็บลงฐานข้อมูลเป็น JSON ได้ตรงๆ):
  {"role": "system" | "user" | "assistant" | "tool", "content": str}
  user       + "images": [base64, ...]                       (ไม่บังคับ)
  assistant  + "tool_calls": [{"id", "name", "arguments": dict}]
             + "native": {"provider", "model", "content"}     (ไม่บังคับ — content ดั้งเดิมของ provider
               เช่น thinking block ของ Claude ที่ต้องส่งกลับแบบไม่แก้ไข ใช้เมื่อส่งกลับไป provider+model เดิม)
  tool       + "tool_call_id", "name"
"""

from dataclasses import dataclass, field
from typing import Callable

# on_event(kind, text): kind = "token" (ข้อความคำตอบ) | "thinking" (สรุปการคิด)
EventSink = Callable[[str, str], None]


@dataclass
class ToolCall:
    id: str
    name: str
    arguments: dict

    def as_dict(self) -> dict:
        return {"id": self.id, "name": self.name, "arguments": self.arguments}


@dataclass
class ToolSpec:
    name: str
    description: str
    parameters: dict          # JSON Schema ของ argument


@dataclass
class LLMResponse:
    text: str = ""
    tool_calls: list[ToolCall] = field(default_factory=list)
    model: str = ""
    stop_reason: str = ""
    usage: dict = field(default_factory=dict)
    error: str | None = None
    native: dict | None = None            # ดู docstring ด้านบน
    streamed: bool = False                # ส่ง token ถึงผู้ใช้ไปแล้วอย่างน้อย 1 ตัว (fallback ไม่ได้แล้ว)

    @property
    def ok(self) -> bool:
        return self.error is None

    def assistant_message(self) -> dict:
        msg: dict = {"role": "assistant", "content": self.text}
        if self.tool_calls:
            msg["tool_calls"] = [c.as_dict() for c in self.tool_calls]
        if self.native:
            msg["native"] = self.native
        return msg
