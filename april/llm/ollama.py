"""
april/llm/ollama.py
---------------------
Ollama ทั้งในเครื่อง (http://127.0.0.1:11434) และ Ollama Cloud (https://ollama.com + API key) — API เดียวกัน
อ้างอิงจาก Envy (inference/ollama_backend.py): ขยาย num_ctx เมื่อ prompt ยาวกว่า context ไม่งั้น Ollama
ตัดต้น prompt ทิ้งเงียบๆ (system prompt หาย) และแปลข้อผิดพลาด HTTP เป็นข้อความที่อ่านรู้เรื่อง
"""

import json
import uuid

import httpx

from april.config import settings
from april.llm.catalog import ModelEntry
from april.llm.types import EventSink, LLMResponse, ToolCall, ToolSpec

CLOUD_URL = "https://ollama.com"
_HINTS = {401: "API key ไม่ถูกต้อง/ไม่ได้ตั้ง", 402: "โมเดลนี้ต้องเติมเครดิต", 403: "ไม่มีสิทธิ์ใช้โมเดลนี้",
          404: "ไม่พบโมเดลนี้ (ollama pull ก่อน?)", 429: "เกินโควตาการใช้งาน"}


def to_ollama(messages: list[dict]) -> list[dict]:
    out = []
    for m in messages:
        role = m["role"]
        if role == "tool":
            out.append({"role": "tool", "content": str(m.get("content", "")), "tool_name": m.get("name", "")})
        elif role == "assistant" and m.get("tool_calls"):
            out.append({"role": "assistant", "content": m.get("content") or "",
                        "tool_calls": [{"function": {"name": c["name"], "arguments": c.get("arguments") or {}}}
                                       for c in m["tool_calls"]]})
        else:
            msg = {"role": role, "content": m.get("content") or ""}
            if m.get("images"):
                msg["images"] = m["images"]
            out.append(msg)
    return out


def tool_payload(tools: list[ToolSpec]) -> list[dict]:
    return [{"type": "function", "function": {"name": t.name, "description": t.description, "parameters": t.parameters}}
            for t in tools]


def _fit_context(payload: dict) -> None:
    """ประมาณ token แบบเผื่อ (~3 ตัวอักษร/token — ไทยวัดได้ ~3.9) ถ้าเกิน num_ctx ขยายเฉพาะคำขอนี้ (ปัดขึ้นทีละ 2048)"""
    options = payload.setdefault("options", {})
    current = int(options.get("num_ctx") or 0)
    chars = sum(len(str(m.get("content") or "")) for m in payload["messages"])
    chars += len(json.dumps(payload.get("tools") or [], ensure_ascii=False))
    needed = chars // 3 + 2048
    if current and needed > current:
        options["num_ctx"] = min(131072, -(-needed // 2048) * 2048)


def _error(status: int, body: str) -> str:
    try:
        detail = json.loads(body).get("error", "")
    except ValueError:
        detail = body[:200]
    return f"HTTP {status} {_HINTS.get(status, '')} {detail}".strip()


class OllamaProvider:
    async def generate(self, entry: ModelEntry, messages: list[dict], tools: list[ToolSpec],
                       on_event: EventSink | None = None) -> LLMResponse:
        cloud = entry.provider == "ollama_cloud"
        base = entry.base_url or (CLOUD_URL if cloud else settings.ollama_url)
        headers = {"Authorization": f"Bearer {entry.api_key}"} if cloud else {}
        payload: dict = {"model": entry.model, "messages": to_ollama(messages), "stream": True}
        if tools:
            payload["tools"] = tool_payload(tools)
        if entry.think is not None:
            payload["think"] = entry.think
        if entry.options:
            payload["options"] = dict(entry.options)
        if cloud:
            payload.get("options", {}).pop("num_ctx", None)   # cloud จัดการ context เอง
        else:
            payload["keep_alive"] = "30m"
            _fit_context(payload)

        res = LLMResponse(model=entry.id)
        parts: list[str] = []
        try:
            async with httpx.AsyncClient(base_url=base, headers=headers,
                                         timeout=httpx.Timeout(300.0, connect=10.0)) as client:
                async with client.stream("POST", "/api/chat", json=payload) as r:
                    if r.status_code >= 400:
                        res.error = _error(r.status_code, (await r.aread()).decode(errors="replace"))
                        return res
                    async for line in r.aiter_lines():
                        if not line.strip():
                            continue
                        chunk = json.loads(line)
                        if chunk.get("error"):
                            res.error = str(chunk["error"])
                            break
                        msg = chunk.get("message") or {}
                        for call in msg.get("tool_calls") or []:
                            fn = call.get("function") or {}
                            args = fn.get("arguments") or {}
                            if isinstance(args, str):
                                try:
                                    args = json.loads(args)
                                except ValueError:
                                    args = {"_invalid_json": args}
                            res.tool_calls.append(ToolCall(id=call.get("id") or f"call_{uuid.uuid4().hex[:8]}",
                                                           name=fn.get("name", ""), arguments=args))
                        if msg.get("thinking") and on_event:
                            on_event("thinking", msg["thinking"])
                        if msg.get("content"):
                            parts.append(msg["content"])
                            res.streamed = True
                            if on_event:
                                on_event("token", msg["content"])
                        if chunk.get("done"):
                            res.stop_reason = chunk.get("done_reason", "stop")
                            res.usage = {"input_tokens": chunk.get("prompt_eval_count"),
                                         "output_tokens": chunk.get("eval_count")}
        except (httpx.HTTPError, ValueError) as exc:
            res.error = f"{type(exc).__name__}: {exc}" if str(exc) else type(exc).__name__
            if not cloud and isinstance(exc, httpx.ConnectError):
                res.error = f"ต่อ Ollama ที่ {base} ไม่ได้ — เปิด Ollama ก่อน (ollama serve)"
        res.text = "".join(parts)
        return res

    async def health(self) -> dict:
        try:
            async with httpx.AsyncClient(base_url=settings.ollama_url, timeout=3.0) as client:
                r = await client.get("/api/tags")
                return {"online": True, "models": [m["name"] for m in r.json().get("models", [])]}
        except (httpx.HTTPError, ValueError) as exc:
            return {"online": False, "error": str(exc) or type(exc).__name__}
