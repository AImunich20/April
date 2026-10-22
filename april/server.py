"""
april/server.py
-----------------
HTTP API ของ April (FastAPI) — ค่าเริ่มต้นเปิดเฉพาะในเครื่อง http://127.0.0.1:8100

  GET    /health                      สถานะ + Ollama
  GET    /models                      แค็ตตาล็อกโมเดล (พร้อมใช้ไหม, ผลการเรียกล่าสุด)
  POST   /chat                        {message, session_id?, model?, images?} -> SSE (event ตาม agent/loop.py)
  POST   /chat/sync                   เหมือน /chat แต่รอคำตอบเต็มแล้วคืน JSON
  GET    /sessions · GET/DELETE /sessions/{id}
  GET    /notes · DELETE /notes/{id}  ความจำเรื่องเจ้านาย
  GET    /reminders
  GET    /announcements?unread=true   สิ่งที่ April แจ้งเอง · POST /announcements/read
  POST   /briefing                    สรุปประจำวันตอนนี้เลย

ตั้ง APRIL_API_TOKEN = ทุกคำขอต้องมี Authorization: Bearer <token> (จำเป็นถ้าเปิด host อื่นนอกจาก 127.0.0.1)
"""

import hmac
import json
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from april import __version__
from april.agent.loop import Agent
from april.config import settings
from april.llm.ollama import OllamaProvider
from april.memory.store import Store
from april.scheduler import Scheduler


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=50_000)
    session_id: str | None = None
    model: str | None = None
    images: list[str] | None = None       # base64 (jpeg/png)


def require_token(authorization: str = Header("")) -> None:
    if settings.api_token and not hmac.compare_digest(authorization, f"Bearer {settings.api_token}"):
        raise HTTPException(401, "ต้องมี token (Authorization: Bearer ...)")


def create_app(agent: Agent | None = None, run_scheduler: bool = True) -> FastAPI:
    state: dict = {}

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        state["agent"] = agent or Agent(Store(settings.db_path))
        if run_scheduler:
            state["scheduler"] = Scheduler(state["agent"])
            state["scheduler"].start()
        yield
        if "scheduler" in state:
            await state["scheduler"].stop()

    app = FastAPI(title="April", version=__version__, lifespan=lifespan, dependencies=[Depends(require_token)])

    def get_agent() -> Agent:
        return state["agent"]

    def check_model(model: str | None) -> None:
        if model and model != "auto" and get_agent().router.catalog.get(model) is None:
            raise HTTPException(400, f"ไม่รู้จักโมเดล '{model}' (ดู GET /models)")

    @app.get("/health")
    async def health():
        return {"ok": True, "name": settings.name, "version": __version__, "ollama": await OllamaProvider().health()}

    @app.get("/models")
    async def models():
        return {"default": settings.default_model, "models": get_agent().router.describe()}

    @app.post("/chat")
    async def chat(req: ChatRequest):
        check_model(req.model)

        async def stream():
            async for event in get_agent().run(req.message, session_id=req.session_id, model=req.model,
                                               images=req.images):
                yield f"event: {event['type']}\ndata: {json.dumps(event, ensure_ascii=False, default=str)}\n\n"
        return StreamingResponse(stream(), media_type="text/event-stream",
                                 headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})

    @app.post("/chat/sync")
    async def chat_sync(req: ChatRequest):
        check_model(req.model)
        return await get_agent().ask(req.message, session_id=req.session_id, model=req.model, images=req.images)

    @app.get("/sessions")
    async def sessions():
        return get_agent().store.sessions()

    @app.get("/sessions/{session_id}")
    async def session(session_id: str):
        msgs = get_agent().store.messages(session_id)
        if not msgs:
            raise HTTPException(404, "ไม่พบ session นี้")
        # ไม่ส่ง native (thinking signature ฯลฯ) ออกไป — แสดงผลใช้ text/content พอ
        return [{k: v for k, v in m.items() if k != "native"} for m in msgs]

    @app.delete("/sessions/{session_id}")
    async def delete_session(session_id: str):
        get_agent().store.delete_session(session_id)
        return {"ok": True}

    @app.get("/notes")
    async def notes():
        return get_agent().store.notes(500)

    @app.delete("/notes/{note_id}")
    async def delete_note(note_id: int):
        if not get_agent().store.delete_note(note_id):
            raise HTTPException(404, "ไม่พบความจำนี้")
        return {"ok": True}

    @app.get("/reminders")
    async def reminders(include_done: bool = False):
        return get_agent().store.reminders(include_done)

    @app.get("/announcements")
    async def announcements(unread: bool = False):
        return get_agent().store.announcements(unread_only=unread)

    @app.post("/announcements/read")
    async def mark_read(ids: list[int] | None = None):
        get_agent().store.mark_read(ids)
        return {"ok": True}

    @app.post("/briefing")
    async def briefing():
        return {"text": await get_agent().briefing()}

    return app


app = create_app()
