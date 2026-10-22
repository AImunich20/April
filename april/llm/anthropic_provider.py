"""
april/llm/anthropic_provider.py
---------------------------------
Claude ผ่าน Anthropic SDK ทางการ (AsyncAnthropic, streaming + tool use)

- thinking แบบ adaptive + display "summarized" -> สรุปการคิดขึ้นหน้าจอระหว่างรอ, ความลึกคุมด้วย effort ใน models.yaml
- เครื่องมือเปิด eager_input_streaming (argument ยาวไม่ค้าง) -> SDK ไม่ตรวจ input ให้แล้ว: argument ถูกตรวจกับ schema
  ที่ tools/registry.py ก่อนรันเสมอ, JSON ที่ parse ไม่ได้เลย (ValueError จาก stream) = ส่งคำขอใหม่ไม่เกิน 2 ครั้ง
- Opus 5.5 / Sonnet 5.5: เปิด server-side fallback (fallbacks="default") — ถ้า safety classifier ปฏิเสธคำขอที่ปกติ
  API จะส่งต่อให้โมเดลสำรองในคำขอเดียวกัน
- content ดั้งเดิม (รวม thinking block) เก็บไว้ใน native แล้วส่งกลับแบบไม่แก้ไขในรอบถัดไปของโมเดลเดียวกัน
- top-level cache_control: system prompt + เครื่องมือ + ประวัติแชทถูก cache ข้ามรอบ (ไม่มีเวลาปัจจุบันใน system)
"""

import anthropic

from april.llm.catalog import ModelEntry
from april.llm.types import EventSink, LLMResponse, ToolCall, ToolSpec

MAX_TOKENS = 64000
_FALLBACK_MODELS = {"claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1"}
_FALLBACK_BETA = "server-side-fallback-2026-07-01"
# ฟิลด์ที่ส่งกลับได้ของแต่ละ block (block ที่ได้จาก response มีฟิลด์ฝั่ง output ปนมา)
_KEEP = {"text": ("type", "text"), "thinking": ("type", "thinking", "signature"),
         "redacted_thinking": ("type", "data"), "tool_use": ("type", "id", "name", "input")}


def _replay(block: dict) -> dict:
    keep = _KEEP.get(block.get("type"))
    return {k: block[k] for k in keep if k in block} if keep else block


def to_anthropic(messages: list[dict], model: str) -> tuple[str, list[dict]]:
    """ข้อความกลาง -> (system, messages ของ Claude) · tool result ที่ติดกันรวมเป็น user message เดียว"""
    system: list[str] = []
    out: list[dict] = []
    pending_results: list[dict] = []

    def flush():
        if pending_results:
            out.append({"role": "user", "content": list(pending_results)})
            pending_results.clear()

    for m in messages:
        role = m["role"]
        if role == "system":
            system.append(m.get("content") or "")
            continue
        if role == "tool":
            pending_results.append({"type": "tool_result", "tool_use_id": m.get("tool_call_id", ""),
                                    "content": str(m.get("content") or "(ว่าง)"),
                                    **({"is_error": True} if m.get("is_error") else {})})
            continue
        flush()
        if role == "assistant":
            native = m.get("native") or {}
            if native.get("provider") == "anthropic" and native.get("model") == model and native.get("content"):
                out.append({"role": "assistant", "content": [_replay(b) for b in native["content"]]})
                continue
            blocks: list[dict] = []
            if (m.get("content") or "").strip():
                blocks.append({"type": "text", "text": m["content"]})
            blocks += [{"type": "tool_use", "id": c["id"], "name": c["name"], "input": c.get("arguments") or {}}
                       for c in m.get("tool_calls") or []]
            if blocks:
                out.append({"role": "assistant", "content": blocks})
        else:
            if m.get("images"):
                content = [{"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": b}}
                           for b in m["images"]]
                content.append({"type": "text", "text": m.get("content") or ""})
                out.append({"role": "user", "content": content})
            else:
                out.append({"role": "user", "content": m.get("content") or ""})
    flush()
    return "\n\n".join(s for s in system if s), out


def tool_payload(tools: list[ToolSpec]) -> list[dict]:
    return [{"name": t.name, "description": t.description, "input_schema": t.parameters,
             "eager_input_streaming": True} for t in tools]


def _api_error(exc: Exception) -> str:
    if isinstance(exc, anthropic.AuthenticationError):
        return "Claude: API key ไม่ถูกต้อง"
    if isinstance(exc, anthropic.RateLimitError):
        return "Claude: เกินอัตราการใช้งาน (429)"
    if isinstance(exc, anthropic.APIStatusError):
        return f"Claude: HTTP {exc.status_code} {exc.message}"[:300]
    if isinstance(exc, anthropic.APIConnectionError):
        return "Claude: เชื่อมต่อไม่ได้ (เน็ตหลุด?)"
    return f"Claude: {type(exc).__name__}: {exc}"[:300]


class AnthropicProvider:
    def __init__(self):
        self._clients: dict[str, anthropic.AsyncAnthropic] = {}

    def _client(self, entry: ModelEntry) -> anthropic.AsyncAnthropic:
        key = entry.api_key
        if key not in self._clients:
            self._clients[key] = anthropic.AsyncAnthropic(api_key=key or None, base_url=entry.base_url or None)
        return self._clients[key]

    def _params(self, entry: ModelEntry, messages: list[dict], tools: list[ToolSpec]) -> dict:
        system, msgs = to_anthropic(messages, entry.model)
        params: dict = {"model": entry.model, "max_tokens": MAX_TOKENS, "messages": msgs,
                        "thinking": {"type": "adaptive", "display": "summarized"},
                        "cache_control": {"type": "ephemeral"}}
        if system:
            params["system"] = system
        if tools:
            params["tools"] = tool_payload(tools)
        if entry.effort:
            params["output_config"] = {"effort": entry.effort}
        if entry.model in _FALLBACK_MODELS:
            params["betas"] = [_FALLBACK_BETA]
            params["fallbacks"] = "default"
        return params

    async def generate(self, entry: ModelEntry, messages: list[dict], tools: list[ToolSpec],
                       on_event: EventSink | None = None) -> LLMResponse:
        params = self._params(entry, messages, tools)
        res = LLMResponse(model=entry.id)
        for attempt in range(3):
            res = LLMResponse(model=entry.id)
            try:
                async with self._client(entry).beta.messages.stream(**params) as stream:
                    async for event in stream:
                        if event.type != "content_block_delta":
                            continue
                        delta = event.delta
                        if delta.type == "text_delta" and delta.text:
                            res.streamed = True
                            if on_event:
                                on_event("token", delta.text)
                        elif delta.type == "thinking_delta" and delta.thinking and on_event:
                            on_event("thinking", delta.thinking)
                    final = await stream.get_final_message()
                break
            except ValueError:
                # JSON ของ argument ที่ parse ไม่ได้เลย — ยังไม่มี tool_use_id ให้ตอบ จึงส่งคำขอเดิมใหม่
                if attempt == 2 or res.streamed:
                    res.error = "Claude: argument ของเครื่องมือเป็น JSON ที่อ่านไม่ได้"
                    return res
            except anthropic.AnthropicError as exc:
                res.error = _api_error(exc)
                return res

        blocks = [b.model_dump(mode="json", exclude_none=True) for b in final.content]
        res.text = "".join(b.get("text", "") for b in blocks if b.get("type") == "text")
        res.stop_reason = final.stop_reason or ""
        usage = final.usage
        res.usage = {"input_tokens": usage.input_tokens, "output_tokens": usage.output_tokens,
                     "cache_read_input_tokens": getattr(usage, "cache_read_input_tokens", None)}
        res.native = {"provider": "anthropic", "model": entry.model, "content": blocks}
        if final.stop_reason == "refusal":
            details = getattr(final, "stop_details", None)
            category = getattr(details, "category", None) if details else None
            res.error = f"Claude ปฏิเสธคำขอนี้{f' ({category})' if category else ''}"
            return res
        calls = [b for b in blocks if b.get("type") == "tool_use"]
        if final.stop_reason == "max_tokens" and calls:
            # argument ที่ถูกตัดกลางทาง parse ได้เป็น object ที่ไม่ครบ — ห้ามรัน
            res.error = "Claude: คำตอบยาวเกิน max_tokens ระหว่างเรียกเครื่องมือ"
            return res
        res.tool_calls = [ToolCall(id=b["id"], name=b["name"],
                                   arguments=b.get("input") if isinstance(b.get("input"), dict) else {})
                          for b in calls]
        return res
