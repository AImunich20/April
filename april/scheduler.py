"""
april/scheduler.py
--------------------
งานเชิงรุกของพ่อบ้าน (รันเบื้องหลังตลอดที่เซิร์ฟเวอร์เปิด)
  - ตัวเตือนถึงเวลา -> แจ้งขึ้นจอ Mac + เก็บใน announcements (หน้าแอป/CLI ดึงไปแสดง)
  - สรุปประจำวันตามเวลา APRIL_BRIEFING_TIME (เช่น 07:30) วันละครั้ง
ตัวเตือนที่ถึงเวลาตอนเซิร์ฟเวอร์ปิดอยู่ จะถูกแจ้งทันทีที่เปิดใหม่ (ไม่หายเงียบ)
"""

import asyncio
from datetime import datetime

from april.agent.loop import Agent
from april.config import settings
from april.observability import log
from april.tools.builtin import mac_notify, thai_datetime, tz

TICK_SECONDS = 20


class Scheduler:
    def __init__(self, agent: Agent):
        self.agent = agent
        self.store = agent.store
        self._task: asyncio.Task | None = None
        self._briefed_on: str | None = None

    def start(self) -> None:
        self._task = asyncio.create_task(self._loop())

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass

    async def _loop(self) -> None:
        while True:
            try:
                await self.tick()
            except Exception as exc:  # noqa: BLE001 — งานเบื้องหลังห้ามตาย
                log("scheduler_error", error=f"{type(exc).__name__}: {exc}")
            await asyncio.sleep(TICK_SECONDS)

    async def tick(self, now: datetime | None = None) -> None:
        now = now or datetime.now(tz())
        for r in self.store.due_reminders(now.timestamp()):
            late = now.timestamp() - r["due_at"] > 120
            when = thai_datetime(datetime.fromtimestamp(r["due_at"], tz()))
            text = r["text"] + (f" (กำหนดเดิม {when})" if late else "")
            self.store.finish_reminder(r["id"])
            self.store.announce("reminder", "เตือนความจำ", text)
            log("reminder_fired", id=r["id"], late=late)
            await mac_notify(f"{settings.name} · เตือนความจำ", text)

        if settings.briefing_time and self._briefed_on != now.date().isoformat():
            hh, mm = (int(x) for x in settings.briefing_time.split(":"))
            if (now.hour, now.minute) >= (hh, mm):
                self._briefed_on = now.date().isoformat()
                if not self.store.messages(f"briefing-{now:%Y%m%d}"):   # เปิดเซิร์ฟเวอร์ใหม่ในวันเดียวกัน = ไม่ซ้ำ
                    log("briefing_start")
                    await self.agent.briefing()
