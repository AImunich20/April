"""
april/tools/registry.py
-------------------------
ทะเบียนเครื่องมือในตัวของ April (ไม่มีระบบปลั๊กอิน — เครื่องมือทั้งหมดอยู่ใน tools/builtin.py)

- @tool(...) ลงทะเบียนฟังก์ชัน async พร้อม JSON Schema ของ argument
- action=True = เครื่องมือที่ทำอะไรกับเครื่องจริง (เปิดแอป/เว็บ/แจ้งเตือน) — ปิดทั้งกลุ่มได้ด้วย APRIL_ALLOW_ACTIONS=false
- argument จากโมเดลถูกตรวจกับ schema ก่อนรันเสมอ (Claude ใช้ eager input streaming ซึ่ง API ไม่ตรวจให้)
- ผลลัพธ์เป็นข้อความเสมอ ล้ม = (False, "ERROR: ...") ให้โมเดลอ่านสาเหตุแล้วแก้เอง ไม่ทำให้ทั้งคำขอล้ม
"""

import asyncio
import inspect
import json
from dataclasses import dataclass
from typing import Awaitable, Callable

from april.llm.types import ToolSpec

_TYPES = {"string": str, "integer": int, "number": (int, float), "boolean": bool, "array": list, "object": dict}


@dataclass
class Tool:
    name: str
    description: str
    parameters: dict
    func: Callable[..., Awaitable]
    action: bool = False

    def spec(self) -> ToolSpec:
        return ToolSpec(self.name, self.description, self.parameters)


@dataclass
class ToolContext:
    store: object                 # memory.store.Store
    session_id: str = ""
    allow_actions: bool = True


def coerce(params: dict, args: dict) -> dict:
    """แก้รูปแบบที่โมเดลเล็กส่งมาบ่อย: ตัวเลขเป็นสตริง ("5"), 5.0 ในช่อง integer, ค่า null ของ argument ที่ไม่บังคับ"""
    props = params.get("properties", {})
    out = {}
    for key, value in args.items():
        if value is None:
            continue
        kind = (props.get(key) or {}).get("type")
        if kind in ("integer", "number") and isinstance(value, str):
            try:
                value = float(value.replace(",", ""))
            except ValueError:
                pass
        if kind == "integer" and isinstance(value, float) and value.is_integer():
            value = int(value)
        out[key] = value
    return out


def validate(params: dict, args: dict) -> str | None:
    """ข้อผิดพลาดแรกของ argument (None = ผ่าน)"""
    if "_invalid_json" in args:
        return "argument ไม่ใช่ JSON ที่ถูกต้อง"
    props = params.get("properties", {})
    for key in params.get("required", []):
        if args.get(key) in (None, ""):
            return f"ขาด argument '{key}'"
    for key, value in args.items():
        spec = props.get(key)
        if spec is None:
            return f"ไม่รู้จัก argument '{key}'"
        kind = spec.get("type")
        expected = _TYPES.get(kind)
        if expected and (not isinstance(value, expected) or (kind in ("integer", "number") and isinstance(value, bool))):
            return f"'{key}' ต้องเป็น {kind}"
        if "enum" in spec and value not in spec["enum"]:
            return f"'{key}' ต้องเป็นหนึ่งใน {spec['enum']}"
    return None


class ToolRegistry:
    def __init__(self):
        self.tools: dict[str, Tool] = {}

    def tool(self, name: str, description: str, parameters: dict | None = None, action: bool = False):
        params = parameters or {"type": "object", "properties": {}}
        params.setdefault("required", [])
        params.setdefault("additionalProperties", False)

        def register(func):
            self.tools[name] = Tool(name, description, params, func, action)
            return func
        return register

    def specs(self, allow_actions: bool = True) -> list[ToolSpec]:
        return [t.spec() for t in self.tools.values() if allow_actions or not t.action]

    async def call(self, name: str, args: dict, ctx: ToolContext, timeout: float = 30.0) -> tuple[bool, str]:
        tool = self.tools.get(name)
        if tool is None:
            return False, f"ERROR: ไม่มีเครื่องมือชื่อ '{name}'"
        if tool.action and not ctx.allow_actions:
            return False, "ERROR: เจ้านายปิดเครื่องมือที่สั่งงานเครื่องไว้ (APRIL_ALLOW_ACTIONS=false)"
        args = coerce(tool.parameters, args) if isinstance(args, dict) else {"_invalid_json": args}
        problem = validate(tool.parameters, args)
        if problem:
            return False, f"ERROR: {problem}"
        kwargs = dict(args)
        if "ctx" in inspect.signature(tool.func).parameters:
            kwargs["ctx"] = ctx
        try:
            result = await asyncio.wait_for(tool.func(**kwargs), timeout)
        except asyncio.TimeoutError:
            return False, f"ERROR: เครื่องมือไม่ตอบภายใน {timeout:.0f} วินาที"
        except Exception as exc:  # noqa: BLE001 — ทุกข้อผิดพลาดกลายเป็นข้อความให้โมเดลอ่าน
            return False, f"ERROR: {type(exc).__name__}: {exc}"
        if isinstance(result, str):
            return not result.startswith("ERROR"), result
        return True, json.dumps(result, ensure_ascii=False, default=str)


registry = ToolRegistry()
