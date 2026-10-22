"""
april/llm/router.py
---------------------
เลือกโมเดลและสำรองอัตโนมัติ: ลองตามลำดับของ Catalog.chain() — cloud ที่ขอ/auto_order แล้วปิดท้ายด้วยโมเดลในเครื่อง
ตัวไหนล้มก่อนส่ง token แรกถึงผู้ใช้ -> ลองตัวถัดไปในคำขอเดียวกัน (ส่ง token ไปแล้ว = คืน error เพราะผู้ใช้เห็นครึ่งคำตอบแล้ว)
cloud ที่ล้มด้วยเหตุถาวร (คีย์ผิด/เกินโควตา/ต้องเติมเงิน) ถูกพักไว้ COOLDOWN วินาที ไม่ต้องเสียเวลาลองทุกคำขอ
"""

import asyncio
import time
from typing import Callable

from april.llm.anthropic_provider import AnthropicProvider
from april.llm.catalog import Catalog, ModelEntry, load_catalog
from april.llm.ollama import OllamaProvider
from april.llm.openai_compat import OpenAICompatProvider
from april.llm.types import EventSink, LLMResponse, ToolSpec
from april.observability import log

COOLDOWN = 600
_STICKY = ("401", "402", "403", "429", "API key", "เกินโควตา", "เกินอัตรา", "เติมเครดิต")


class Router:
    def __init__(self, catalog: Catalog | None = None, providers: dict | None = None):
        self.catalog = catalog or load_catalog()
        ollama = OllamaProvider()
        compat = OpenAICompatProvider()
        self.providers = providers or {"ollama": ollama, "ollama_cloud": ollama, "anthropic": AnthropicProvider(),
                                       "openai": compat, "gemini": compat, "openai_compat": compat}
        self.status: dict[str, dict] = {}
        # สถิติตั้งแต่เปิดเซิร์ฟเวอร์ (แท็บภาพรวม/โมเดลของ Control Center)
        self.stats: dict[str, dict] = {}

    def _cooling(self, entry: ModelEntry) -> bool:
        s = self.status.get(entry.id) or {}
        return not entry.local and bool(s.get("sticky")) and time.time() - s.get("at", 0) < COOLDOWN

    def _record(self, entry: ModelEntry, res: LLMResponse, seconds: float) -> None:
        self.status[entry.id] = {"at": time.time(), "ok": res.ok, "error": res.error, "seconds": round(seconds, 2),
                                 "sticky": bool(res.error and any(s in res.error for s in _STICKY))}
        st = self.stats.setdefault(entry.id, {"calls": 0, "errors": 0, "seconds": 0.0, "input_tokens": 0,
                                              "output_tokens": 0})
        st["calls"] += 1
        st["errors"] += 0 if res.ok else 1
        st["seconds"] += seconds
        st["input_tokens"] += int(res.usage.get("input_tokens") or 0)
        st["output_tokens"] += int(res.usage.get("output_tokens") or 0)
        log("llm_call", level="info" if res.ok else "warning", model=entry.id, seconds=round(seconds, 2),
            error=res.error, **{k: res.usage.get(k) for k in ("input_tokens", "output_tokens") if res.usage.get(k)})

    def totals(self) -> dict:
        keys = ("calls", "errors", "input_tokens", "output_tokens")
        return {k: sum(s[k] for s in self.stats.values()) for k in keys}

    async def probe(self, timeout: float = 30) -> None:
        """ลองเรียก cloud ทุกตัวที่ตั้งค่าครบด้วยข้อความสั้นมาก (ปุ่ม "ตรวจตอนนี้") — ตัวที่ตอบได้หายจากสถานะพักทันที"""
        async def one(entry: ModelEntry) -> None:
            started = time.monotonic()
            try:
                res = await asyncio.wait_for(self.providers[entry.provider].generate(
                    entry, [{"role": "user", "content": "ตอบคำเดียว: ok"}], [], None), timeout)
            except asyncio.TimeoutError:
                res = LLMResponse(error=f"ไม่ตอบภายใน {timeout:.0f} วิ")
            self._record(entry, res, time.monotonic() - started)

        await asyncio.gather(*(one(m) for m in self.catalog.cloud if m.ready()))

    def plan(self, requested: str | None) -> list[ModelEntry]:
        chain = self.catalog.chain(requested)
        return [m for m in chain if not self._cooling(m)] or [self.catalog.local]

    async def generate(self, messages: list[dict], tools: list[ToolSpec], *, model: str | None = None,
                       on_event: EventSink | None = None,
                       on_fallback: Callable[[str, str, str], None] | None = None) -> LLMResponse:
        chain = self.plan(model)
        res = LLMResponse(error="ไม่มีโมเดลที่ใช้ได้")
        for i, entry in enumerate(chain):
            started = time.monotonic()
            res = await self.providers[entry.provider].generate(entry, messages, tools, on_event)
            self._record(entry, res, time.monotonic() - started)
            if res.ok or res.streamed or i == len(chain) - 1:
                return res
            if on_fallback:
                on_fallback(entry.id, chain[i + 1].id, res.error or "")
        return res

    def describe(self) -> list[dict]:
        out = []
        for m in self.catalog.all():
            d = m.describe()
            s = self.status.get(m.id)
            if s:
                d["last"] = {k: s[k] for k in ("ok", "error", "seconds", "at")}
            d["cooling"] = self._cooling(m)
            st = self.stats.get(m.id)
            if st:
                d["stats"] = {**st, "avg_seconds": round(st["seconds"] / st["calls"], 2) if st["calls"] else None}
            if not m.ready():
                d["state"] = "unset"
            elif d["cooling"]:
                d["state"] = "paused"
            elif not s:
                d["state"] = "unknown"
            else:
                d["state"] = "online" if s["ok"] else "error"
            out.append(d)
        return out
