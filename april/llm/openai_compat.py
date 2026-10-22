"""
april/llm/openai_compat.py
----------------------------
ผู้ให้บริการที่ใช้ endpoint แบบ OpenAI (/chat/completions): ChatGPT, Gemini และเจ้าอื่นที่ compatible
(OpenRouter, Groq, vLLM ... ใส่ base_url เองใน models.yaml) — อ้างอิงจาก Envy (inference/brain.py)
"""

import json

import httpx

from april.llm.catalog import ModelEntry
from april.llm.types import EventSink, LLMResponse, ToolCall, ToolSpec

BASE_URLS = {"openai": "https://api.openai.com/v1",
             "gemini": "https://generativelanguage.googleapis.com/v1beta/openai"}


def to_openai(messages: list[dict]) -> list[dict]:
    out = []
    for m in messages:
        role = m["role"]
        if role == "assistant" and m.get("tool_calls"):
            out.append({"role": "assistant", "content": m.get("content") or "",
                        "tool_calls": [{"id": c["id"], "type": "function",
                                        "function": {"name": c["name"],
                                                     "arguments": json.dumps(c.get("arguments") or {},
                                                                             ensure_ascii=False)}}
                                       for c in m["tool_calls"]]})
        elif role == "tool":
            out.append({"role": "tool", "tool_call_id": m.get("tool_call_id", ""), "content": str(m.get("content", ""))})
        elif m.get("images"):
            parts = [{"type": "text", "text": m.get("content") or ""}]
            parts += [{"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b}"}} for b in m["images"]]
            out.append({"role": role, "content": parts})
        else:
            out.append({"role": role, "content": m.get("content") or ""})
    return out


def tool_payload(tools: list[ToolSpec]) -> list[dict]:
    return [{"type": "function", "function": {"name": t.name, "description": t.description, "parameters": t.parameters}}
            for t in tools]


def _error(status: int, body: str) -> str:
    try:
        data = json.loads(body)
        err = data[0].get("error") if isinstance(data, list) else data.get("error")
        msg = err.get("message") if isinstance(err, dict) else (err or data)
    except (ValueError, AttributeError, IndexError):
        msg = body
    return f"HTTP {status}: {str(msg)[:300]}"


class OpenAICompatProvider:
    async def generate(self, entry: ModelEntry, messages: list[dict], tools: list[ToolSpec],
                       on_event: EventSink | None = None) -> LLMResponse:
        base = (entry.base_url or BASE_URLS.get(entry.provider, "")).rstrip("/")
        res = LLMResponse(model=entry.id)
        if not base:
            res.error = f"{entry.id}: ไม่ได้ตั้ง base_url"
            return res
        payload: dict = {"model": entry.model, "messages": to_openai(messages), "stream": True,
                         "stream_options": {"include_usage": True}}
        if tools:
            payload["tools"] = tool_payload(tools)
        if entry.effort and entry.provider == "openai":
            payload["reasoning_effort"] = entry.effort
        headers = {"Authorization": f"Bearer {entry.api_key}"}
        parts: list[str] = []
        slots: dict[int, dict] = {}
        try:
            async with httpx.AsyncClient(base_url=base, timeout=httpx.Timeout(300.0, connect=15.0)) as client:
                async with client.stream("POST", "/chat/completions", json=payload, headers=headers) as r:
                    if r.status_code >= 400:
                        res.error = _error(r.status_code, (await r.aread()).decode(errors="replace"))
                        return res
                    async for line in r.aiter_lines():
                        if not line.startswith("data:"):
                            continue
                        data = line[5:].strip()
                        if data == "[DONE]":
                            break
                        try:
                            chunk = json.loads(data)
                        except ValueError:
                            continue
                        if chunk.get("usage"):
                            u = chunk["usage"]
                            res.usage = {"input_tokens": u.get("prompt_tokens"), "output_tokens": u.get("completion_tokens")}
                        for choice in chunk.get("choices") or []:
                            delta = choice.get("delta") or {}
                            if delta.get("content"):
                                parts.append(delta["content"])
                                res.streamed = True
                                if on_event:
                                    on_event("token", delta["content"])
                            for tc in delta.get("tool_calls") or []:
                                slot = slots.setdefault(tc.get("index", 0), {"id": None, "name": "", "args": ""})
                                slot["id"] = tc.get("id") or slot["id"]
                                fn = tc.get("function") or {}
                                slot["name"] += fn.get("name") or ""
                                slot["args"] += fn.get("arguments") or ""
                            if choice.get("finish_reason"):
                                res.stop_reason = choice["finish_reason"]
        except httpx.HTTPError as exc:
            res.error = f"{entry.id}: {type(exc).__name__}: {exc}"
        res.text = "".join(parts)
        for i, slot in sorted(slots.items()):
            try:
                args = json.loads(slot["args"] or "{}")
            except ValueError:
                args = {"_invalid_json": slot["args"]}
            res.tool_calls.append(ToolCall(id=slot["id"] or f"call_{i}", name=slot["name"],
                                           arguments=args if isinstance(args, dict) else {}))
        return res
