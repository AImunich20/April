"""
april/agent/loop.py
---------------------
agent loop ของ April: โมเดลตัวเดียวคุมทั้งงาน เรียกเครื่องมือได้หลายรอบจนได้คำตอบ (native tool calling ทุก provider)

ต่างจาก Envy ที่แตกงานเป็น DAG ของ agent เฉพาะทางหลายตัว (planner/decomposer/dispatcher/writer...) — โมเดลรุ่นใหม่
วางแผนและเรียกเครื่องมือเองได้ดีพอแล้ว April จึงเหลือวงเดียว: โมเดล -> เครื่องมือ (ขนานกัน) -> โมเดล ... -> คำตอบ

Agent.run() คืน async generator ของ event (dict) สำหรับหน้าแชท/SSE/CLI:
  session {session_id, run_id} · model {model} · thinking {text} · token {text} · fallback {from, to, reason}
  tool_call {id, name, arguments} · tool_result {id, name, ok, preview} · checklist {checks}
  revision {} (คำตอบที่ส่งไปถูกแทนด้วยฉบับแก้ — token ที่ตามมาคือฉบับใหม่) · error {message}
  done {text, model, session_id, usage}  ← event สุดท้ายเสมอ
"""

import asyncio
import time
import uuid
from typing import AsyncIterator, Callable

from april.agent import checklist, numbers
from april.agent.prompts import BRIEFING_REQUEST, VOICE_STYLE, system_prompt, turn_context
from april.config import settings
from april.llm.router import Router
from april.memory.store import Store
from april.observability import log
from april.tools import builtin  # noqa: F401 — ลงทะเบียนเครื่องมือในตัว
from april.tools.registry import ToolContext, ToolRegistry, registry as default_registry

Emit = Callable[[dict], None]
_STEP_LIMIT_NOTE = "(ระบบ) ใช้เครื่องมือครบจำนวนรอบที่กำหนดแล้ว สรุปคำตอบจากข้อมูลที่มีตอนนี้ ห้ามเรียกเครื่องมือเพิ่ม"


class Agent:
    def __init__(self, store: Store, router: Router | None = None, tools: ToolRegistry | None = None):
        self.store = store
        self.router = router or Router()
        self.tools = tools or default_registry
        self.running: dict[str, asyncio.Task] = {}      # งานที่กำลังทำ (หยุดได้จากแท็บ "งาน" ของ Control Center)

    async def run(self, text: str, *, session_id: str | None = None, model: str | None = None,
                  images: list[str] | None = None, voice: bool = False) -> AsyncIterator[dict]:
        """voice=True = คำตอบจะถูกอ่านออกเสียง (แอป Mac โหมดคุยด้วยเสียง) -> ขอคำตอบสั้นแบบภาษาพูด"""
        queue: asyncio.Queue = asyncio.Queue()
        run_id = uuid.uuid4().hex[:10]
        task = asyncio.create_task(self._run_safe(run_id, text, session_id, model, images, voice, queue.put_nowait))
        self.running[run_id] = task
        task.add_done_callback(lambda _: self.running.pop(run_id, None))
        try:
            while (event := await queue.get()) is not None:
                yield event
        finally:
            if not task.done():
                task.cancel()

    def cancel(self, run_id: str) -> bool:
        task = self.running.get(run_id)
        if task is None or task.done():
            return False
        task.cancel()
        return True

    async def ask(self, text: str, **kwargs) -> dict:
        """เหมือน run แต่รอจนจบแล้วคืน event done (ใช้กับ API แบบไม่ stream / งานเบื้องหลัง)"""
        done: dict = {}
        tools: list[dict] = []
        async for event in self.run(text, **kwargs):
            if event["type"] == "tool_result":
                tools.append({k: event[k] for k in ("name", "ok", "preview")})
            if event["type"] == "done":
                done = event
        return {**done, "tools": tools}

    async def _run_safe(self, run_id, text, session_id, model, images, voice, emit: Emit) -> None:
        state: dict = {"run_id": run_id, "session_id": session_id, "tools": [], "model": None, "started": None}
        try:
            await self._run(text, session_id, model, images, voice, emit, state)
        except (asyncio.CancelledError, Exception) as exc:  # noqa: BLE001 — ผู้ใช้ต้องได้ event done เสมอ ไม่ค้าง
            cancelled = isinstance(exc, asyncio.CancelledError)
            message = "หยุดแล้ว" if cancelled else f"{type(exc).__name__}: {exc}"
            self._finish(state, "cancelled" if cancelled else "failed", error=message)
            emit({"type": "error", "message": message})
            emit({"type": "done", "text": "", "model": state["model"], "session_id": state["session_id"], "usage": {}})
        finally:
            emit(None)

    def _finish(self, state: dict, status: str, *, error: str | None = None, answer: str = "",
                usage: dict | None = None) -> None:
        if state["started"] is None:
            return
        self.store.finish_run(state["run_id"], status, model=state["model"], tools=state["tools"], error=error,
                              answer=answer, usage=usage)
        log("request_done", level={"done": "info", "cancelled": "warning"}.get(status, "error"),
            trace_id=state["run_id"], status=status, model=state["model"], tools=state["tools"], error=error,
            seconds=round(time.monotonic() - state["started"], 2), **(usage or {}))

    async def _generate(self, convo: list[dict], model: str | None, emit: Emit | None, use_tools: bool = True):
        specs = self.tools.specs(settings.allow_actions) if use_tools else []
        on_event = (lambda kind, t: emit({"type": kind, "text": t})) if emit else None
        on_fallback = (lambda a, b, why: emit({"type": "fallback", "from": a, "to": b, "reason": why})) if emit else None
        return await self.router.generate(convo, specs, model=model, on_event=on_event, on_fallback=on_fallback)

    async def _run(self, text: str, session_id: str | None, model: str | None, images, voice: bool,
                   emit: Emit, state: dict) -> None:
        sid = self.store.ensure_session(session_id, title=text.strip().splitlines()[0][:60] if text.strip() else "")
        state["session_id"] = sid
        state["started"] = time.monotonic()
        self.store.start_run(state["run_id"], sid, text, voice)
        log("request_start", trace_id=state["run_id"], session=sid, message=text[:160], voice=voice, model=model)
        emit({"type": "session", "session_id": sid, "run_id": state["run_id"]})
        history = self.store.history(sid, settings.history_messages)

        checks: list[str] = []
        if settings.checklist_enabled and checklist.wanted(text):
            raw = await self._generate([{"role": "user", "content": checklist.extract_prompt(text)}], model, None,
                                       use_tools=False)
            checks = checklist.parse_checks(raw.text) if raw.ok else []
            if checks:
                emit({"type": "checklist", "checks": checks})

        content = (text + (checklist.prompt_block(checks) if checks else "") + turn_context()
                   + (VOICE_STYLE if voice else ""))
        user_msg: dict = {"role": "user", "content": content, "text": text}
        if images:
            user_msg["images"] = images
        convo = [{"role": "system", "content": system_prompt(self.store.notes(30))}, *history, user_msg]
        new: list[dict] = [user_msg]
        ctx = ToolContext(store=self.store, session_id=sid, allow_actions=settings.allow_actions)

        res = None
        usage = {"input_tokens": 0, "output_tokens": 0}
        announced = None
        for step in range(settings.max_steps + 1):
            if step == settings.max_steps:   # ใช้รอบเครื่องมือครบ -> ขอคำตอบสรุป (ยังส่ง tools ไปเพราะประวัติมี tool call)
                note = {"role": "user", "content": _STEP_LIMIT_NOTE}
                convo.append(note)
                new.append(note)
            res = await self._generate(convo, model, emit)
            for k in usage:
                usage[k] += int(res.usage.get(k) or 0)
            if res.model != announced:
                emit({"type": "model", "model": res.model})
                announced = state["model"] = res.model
            if not res.ok:
                emit({"type": "error", "message": res.error})
                state["error"] = res.error
                if res.text:
                    new.append({"role": "assistant", "content": res.text})
                break
            msg = res.assistant_message()
            if step == settings.max_steps:
                msg.pop("tool_calls", None)
                msg.pop("native", None)   # มี tool call ที่ไม่ได้รัน — ส่งกลับแบบเดิมไม่ได้
            convo.append(msg)
            new.append(msg)
            if not msg.get("tool_calls"):
                break
            state["tools"] += [c.name for c in res.tool_calls]
            results = await self._run_tools(res.tool_calls, ctx, emit, state["run_id"])
            convo.extend(results)
            new.extend(results)

        final = res.text if res is not None and res.ok else ""
        if checks and final.strip():
            final = await self._review(text, final, checks, convo, new, model, emit)
        if final.strip():
            final = await self._check_numbers(final, convo, new, model, emit)

        self.store.add_messages(sid, new)
        self._finish(state, "done" if final or not state.get("error") else "failed", error=state.get("error"),
                     answer=final, usage=usage)
        emit({"type": "done", "text": final, "model": res.model if res else None, "session_id": sid, "usage": usage})

    async def _run_tools(self, calls, ctx: ToolContext, emit: Emit, run_id: str = "-") -> list[dict]:
        for call in calls:
            emit({"type": "tool_call", "id": call.id, "name": call.name, "arguments": call.arguments})
            log("tool_call", trace_id=run_id, name=call.name, arguments=call.arguments)
        outcomes = await asyncio.gather(*(self.tools.call(c.name, c.arguments, ctx, settings.tool_timeout_seconds)
                                          for c in calls))
        results = []
        for call, (ok, output) in zip(calls, outcomes):
            emit({"type": "tool_result", "id": call.id, "name": call.name, "ok": ok, "preview": output[:300]})
            if not ok:
                log("tool_error", level="warning", trace_id=run_id, name=call.name, error=output[:300])
            msg = {"role": "tool", "tool_call_id": call.id, "name": call.name, "content": output}
            if not ok:
                msg["is_error"] = True
            results.append(msg)
        return results

    async def _review(self, question: str, answer: str, checks: list[str], convo: list[dict], new: list[dict],
                      model: str | None, emit: Emit) -> str:
        raw = await self._generate([{"role": "user", "content": checklist.review_prompt(question, answer, checks)}],
                                   model, None, use_tools=False)
        failed = checklist.parse_review(raw.text, checks) if raw.ok else []
        if not failed:
            return answer
        emit({"type": "revision", "failed": failed})
        retry = await self._generate([*convo, {"role": "user", "content": checklist.retry_instruction(failed)}],
                                     model, emit)
        if not retry.ok or not retry.text.strip():
            return answer
        # เก็บฉบับแก้แทนคำตอบเดิม เป็นข้อความธรรมดา (thinking ของฉบับแก้เกิดในบริบทที่มีคำสั่งตรวจ ส่งกลับไม่ได้)
        new[-1] = {"role": "assistant", "content": retry.text}
        return retry.text

    async def _check_numbers(self, answer: str, convo: list[dict], new: list[dict], model: str | None,
                             emit: Emit) -> str:
        """ตัวเลขในคำตอบต้องตรงกับผลการคำนวณล่าสุด — โมเดลเล็กชอบแปลงเป็นคำอ่านเองแล้วผิด
        (วัดจริง qwen3.5:4b โหมดเสียง: calculate ได้ 67,500 แต่ตอบ "หกหมื่นเจ็ดพันหกล้านบาท")
        ไม่ตรง -> ให้เขียนใหม่ 1 ครั้งพร้อมบอกตัวเลขที่ถูก และใช้ฉบับใหม่เฉพาะเมื่อมีตัวเลขนี้จริง"""
        expected = numbers.last_result(new)
        if expected is None or numbers.mentions(answer, expected):
            return answer
        log("number_mismatch", level="warning", expected=expected, answer=answer[:200])
        emit({"type": "revision", "reason": "number"})
        fix = {"role": "user", "content": numbers.fix_instruction(expected)}
        retry = await self._generate([*convo, fix], model, emit)
        if not retry.ok or not numbers.mentions(retry.text, expected):
            log("number_fix_failed", level="warning", expected=expected)
            return answer
        new[-1] = {"role": "assistant", "content": retry.text}
        return retry.text

    async def briefing(self) -> str:
        """สรุปประจำวัน (scheduler เรียกตามเวลา / POST /briefing) -> ประกาศ + แจ้งเตือนขึ้นจอ"""
        from datetime import datetime

        from april.tools.builtin import mac_notify, tz

        sid = f"briefing-{datetime.now(tz()):%Y%m%d}"
        result = await self.ask(BRIEFING_REQUEST, session_id=sid)
        text = result.get("text") or ""
        if text:
            self.store.announce("briefing", "สรุปประจำวัน", text)
            await mac_notify(f"{settings.name} · สรุปประจำวัน", text)
        return text
