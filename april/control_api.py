"""
april/control_api.py
----------------------
API ของ Control Center ในแอป Mac (/api/*) — โครงเดียวกับหน้า "ระบบ" ของ Envy
  GET  /api/overview                ภาพรวม: งาน 24 ชม., การเรียกโมเดล, token, ความจำ, Ollama, cloud
  GET  /api/runs · POST /api/runs/{id}/cancel                    ประวัติงาน / หยุดงานที่กำลังทำ
  GET  /api/models · POST /api/models/check                      โมเดลในเครื่อง + cloud / ลองเรียก cloud ทุกตัว
  GET  /api/power · POST /api/power/unload · POST /api/power/clear  RAM + โมเดลที่ค้างใน Ollama
  GET  /api/events · GET /api/events/stream (SSE)                Log สด
  GET  /api/reminders?status= · DELETE /api/reminders/{id}       ตั้งเวลา
  POST /api/notes                                                 จดความจำเอง
  GET  /api/persona                                               ตัวตน + system prompt ที่ใช้จริง
  GET  /api/tools · POST /api/tools/{name}/run                    เครื่องมือในตัว + ทดลองรัน (ไม่ผ่านโมเดล)
  GET  /api/config · GET /api/version
ค่าตั้งแก้ที่ไฟล์ .env (แอปเขียนให้) แล้วเริ่มเซิร์ฟเวอร์ใหม่
"""

import asyncio
import json
import time
from datetime import datetime, timedelta
from typing import Callable

from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from april import __version__, observability, system_monitor
from april.agent.prompts import system_prompt
from april.config import settings
from april.llm.ollama import OllamaProvider
from april.tools.builtin import tz
from april.tools.registry import ToolContext

STARTED = time.time()
_KEYS = ("ANTHROPIC_API_KEY", "OLLAMA_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY")


class NoteIn(BaseModel):
    text: str


class UnloadIn(BaseModel):
    models: list[str]


class ToolRunIn(BaseModel):
    arguments: dict = {}


def _mask(key: str) -> str:
    return f"{key[:7]}…{key[-4:]}" if len(key) > 14 else ("ตั้งแล้ว" if key else "")


def register(app: FastAPI, get_agent: Callable) -> None:

    @app.get("/api/version")
    async def version():
        return {"version": __version__}

    @app.get("/api/overview")
    async def overview():
        agent = get_agent()
        since = time.time() - 86400
        totals = agent.router.totals()
        chain = [m.id for m in agent.router.plan(None)]
        ollama = await OllamaProvider().health()
        loaded = [m["name"] for m in await system_monitor.loaded_models()] if ollama.get("online") else []
        return {
            "uptime_seconds": round(time.time() - STARTED),
            "active_runs": len(agent.running),
            "runs_24h": agent.store.run_stats(since),
            "llm_calls": totals["calls"], "llm_errors": totals["errors"],
            "tokens": {"input": totals["input_tokens"], "output": totals["output_tokens"]},
            "tool_calls": len(agent.tools.recent),
            **agent.store.counts(),
            "ollama": {"online": ollama.get("online", False), "error": ollama.get("error"), "loaded": loaded,
                       "installed": len(ollama.get("models", []))},
            "cloud": {"default": settings.default_model, "chain": chain,
                      "ready": [m.id for m in agent.router.catalog.cloud if m.ready()],
                      "cooling": [m["id"] for m in agent.router.describe() if m.get("cooling")]},
            "announcements": agent.store.announcements(limit=5),
        }

    @app.get("/api/runs")
    async def runs(limit: int = 150):
        agent = get_agent()
        rows = agent.store.runs(min(limit, 500))
        for r in rows:   # งานที่ค้าง running แต่ไม่ได้ทำอยู่จริง (เซิร์ฟเวอร์เคยปิดกลางคัน)
            if r["status"] == "running" and r["id"] not in agent.running:
                r["status"] = "cancelled"
        return {"runs": rows}

    @app.post("/api/runs/{run_id}/cancel")
    async def cancel(run_id: str):
        if not get_agent().cancel(run_id):
            raise HTTPException(404, "งานนี้ไม่ได้ทำอยู่แล้ว")
        return {"ok": True}

    @app.get("/api/models")
    async def models():
        agent = get_agent()
        health = await OllamaProvider().health()
        installed = {}
        try:
            import httpx
            async with httpx.AsyncClient(base_url=settings.ollama_url, timeout=3.0) as client:
                for m in (await client.get("/api/tags")).json().get("models", []):
                    installed[m["name"]] = {"size": m.get("size"), **(m.get("details") or {})}
        except Exception:  # noqa: BLE001 — Ollama ปิดอยู่ก็ยังแสดง cloud ได้
            pass
        loaded = {m["name"] for m in await system_monitor.loaded_models()}
        described = agent.router.describe()
        local = next(d for d in described if d["local"])
        name = local["model"]
        local.update(installed=name in installed or f"{name}:latest" in installed, loaded=name in loaded,
                     info=installed.get(name) or installed.get(f"{name}:latest") or {})
        return {"default": settings.default_model, "auto_order": agent.router.catalog.auto_order,
                "ollama": {"online": health.get("online", False), "error": health.get("error")},
                "local": local, "cloud": [d for d in described if not d["local"]],
                "unused": [{"name": n, "size": i.get("size")} for n, i in installed.items()
                           if n not in (name, f"{name}:latest")]}

    @app.post("/api/models/warm")
    async def warm():
        """โหลดโมเดลในเครื่องขึ้น RAM ไว้ก่อน (แอปเรียกทันทีที่ผู้ใช้เรียก April) — ไม่รอให้โหลดเสร็จ"""
        local = get_agent().router.catalog.local

        async def load():
            try:
                import httpx
                async with httpx.AsyncClient(base_url=settings.ollama_url, timeout=120) as client:
                    await client.post("/api/generate", json={"model": local.model, "keep_alive": "30m"})
            except Exception as exc:  # noqa: BLE001 — โหลดล่วงหน้าไม่สำเร็จก็แค่ช้าลงตอนตอบ
                observability.log("warm_failed", level="warning", model=local.model, error=str(exc))

        asyncio.create_task(load())
        return {"ok": True, "model": local.model}

    @app.post("/api/models/check")
    async def check_models():
        await get_agent().router.probe()
        return await models()

    @app.get("/api/power")
    async def power():
        return await system_monitor.power()

    @app.post("/api/power/unload")
    async def unload(body: UnloadIn):
        return {"unloaded": await system_monitor.unload(body.models)}

    @app.post("/api/power/clear")
    async def clear():
        return await system_monitor.clear()

    @app.get("/api/events")
    async def events(limit: int = 300):
        return {"events": observability.recent(min(limit, 2000))}

    @app.get("/api/events/stream")
    async def events_stream():
        async def stream():
            q = observability.subscribe()
            try:
                while True:
                    try:
                        rec = await asyncio.wait_for(q.get(), 15)
                        yield f"data: {json.dumps(rec, ensure_ascii=False, default=str)}\n\n"
                    except asyncio.TimeoutError:
                        yield ": keep-alive\n\n"
            finally:
                observability.unsubscribe(q)
        return StreamingResponse(stream(), media_type="text/event-stream", headers={"Cache-Control": "no-cache"})

    @app.get("/api/reminders")
    async def reminders(status: str = "pending"):
        if status not in ("pending", "sent", "all"):
            raise HTTPException(400, "status ต้องเป็น pending / sent / all")
        return {"reminders": get_agent().store.reminders(status=status)}

    @app.delete("/api/reminders/{reminder_id}")
    async def cancel_reminder(reminder_id: int):
        if not get_agent().store.finish_reminder(reminder_id):
            raise HTTPException(404, "ไม่พบตัวเตือนที่ยังไม่ถึงเวลา")
        observability.log("reminder_cancelled", id=reminder_id)
        return {"ok": True}

    @app.post("/api/notes")
    async def add_note(body: NoteIn):
        if not body.text.strip():
            raise HTTPException(400, "ข้อความว่าง")
        return {"id": get_agent().store.add_note(body.text)}

    @app.get("/api/persona")
    async def persona():
        notes = get_agent().store.notes(30)
        return {"name": settings.name, "owner_name": settings.owner_name, "language": settings.language,
                "particle": settings.particle, "timezone": settings.timezone, "system_prompt": system_prompt(notes)}

    @app.get("/api/tools")
    async def tools():
        reg = get_agent().tools
        return {"tools": [{"name": t.name, "description": t.description, "parameters": t.parameters,
                           "action": t.action} for t in reg.tools.values()],
                "allow_actions": settings.allow_actions, "recent_calls": list(reg.recent)}

    @app.post("/api/tools/{name}/run")
    async def run_tool(name: str, body: ToolRunIn):
        agent = get_agent()
        if name not in agent.tools.tools:
            raise HTTPException(404, "ไม่มีเครื่องมือนี้")
        started = time.monotonic()
        ok, out = await agent.tools.call(name, body.arguments, ToolContext(store=agent.store, session_id="control-center",
                                                                          allow_actions=settings.allow_actions))
        observability.log("tool_test", level="info" if ok else "warning", name=name, arguments=body.arguments,
                          result=out[:200])
        return {"ok": ok, "result": out, "seconds": round(time.monotonic() - started, 3)}

    @app.get("/api/config")
    async def config():
        agent = get_agent()
        now = datetime.now(tz())
        nxt = None
        if settings.briefing_time:
            hh, mm = (int(x) for x in settings.briefing_time.split(":"))
            nxt = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
            if nxt <= now:
                nxt += timedelta(days=1)
        return {"name": settings.name, "owner_name": settings.owner_name, "language": settings.language,
                "timezone": settings.timezone, "default_model": settings.default_model,
                "local_model": agent.router.catalog.local.model, "briefing_time": settings.briefing_time,
                "next_briefing": nxt.timestamp() if nxt else None, "allow_actions": settings.allow_actions,
                "checklist_enabled": settings.checklist_enabled, "notify_mac": settings.notify_mac,
                "host": settings.host, "port": settings.port, "api_token_set": bool(settings.api_token),
                "keys": {k: _mask(settings.key(k)) for k in _KEYS}, "data_dir": str(settings.data_dir)}
