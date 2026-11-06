"""
april/vision.py
-----------------
การมองเห็นของ April — ตาคือกล้องของ Mac ผ่านแอป (Apple/Sources/Vision.swift)

แบ่งงานเป็นชั้น (งานเบาและถี่อยู่บนเครื่อง งานคิดส่งให้ LLM เฉพาะตอนจำเป็น):
  1) แอป Mac: เปิดกล้อง ตรวจการเคลื่อนไหว (เทียบเฟรม) และตรวจ คน/ใบหน้า/สัตว์/ฉาก ด้วย Apple Vision
     + โมเดล Core ML ที่ใส่เพิ่มเอง (เช่น YOLO) ทุก ~0.2 วินาที — ไม่มีอะไรออกนอกเครื่อง
  2) แอปส่งมาที่นี่:  POST /api/vision/frame  ทุก ~1 วิ: สิ่งที่ตรวจเจอ + ภาพ JPEG ล่าสุด
                      POST /api/vision/event  เหตุการณ์: คนมา/ไป, ขยับตอนไม่มีคน, สัตว์, วัตถุใหม่
  3) LLM ทำงานเฉพาะเมื่อ:  เจ้านายถาม (เครื่องมือ look) · มีสิ่งที่สั่งให้เฝ้าดู + ภาพขยับ (watch_for)
                         · เหตุการณ์ที่ควรแจ้ง -> สรุป 1 ประโยค -> ประกาศ + แจ้งเตือน + ให้แอปพูด
  4) ความเป็นส่วนตัว: ภาพอยู่ใน RAM เท่านั้น (ไม่เขียนดิสก์ ไม่เก็บในประวัติแชท ไม่มี API ให้ดึงภาพออกไป)
     งานเบื้องหลังใช้ APRIL_VISION_MODEL (ค่าเริ่มต้นโมเดลในเครื่อง) · APRIL_VISION_CLOUD=false = ภาพไม่ไป cloud เลย

แอปโหมด "เปิดเมื่อต้องใช้" รอที่ GET /api/vision/demand (long-poll) แล้วเปิดกล้องเมื่อ look ต้องการภาพ
หรือมีสิ่งที่ต้องเฝ้าดู · แอปโหมด "เปิดตลอด" ส่งภาพมาตลอดและเหตุการณ์ทำงานเต็มที่
"""

import asyncio
import collections
import re
import time
from dataclasses import asdict, dataclass, field

from april.config import settings
from april.observability import log

FRESH_SECONDS = 2.0          # ภาพใหม่พอที่จะตอบว่า "ตอนนี้" ได้
DEMAND_SECONDS = 15.0        # ขอให้แอปเปิดกล้องค้างไว้นานเท่านี้หลังมีคนต้องการภาพ
ALIVE_SECONDS = 4.0          # ไม่มีภาพใหม่นานกว่านี้ = กล้องปิด
FORCED_CHECK_SECONDS = 60.0  # มีสิ่งที่เฝ้าดูแต่ภาพไม่ขยับ — ยังตรวจอย่างน้อยทุกเท่านี้
MOTION_TRIGGER = 0.02        # สัดส่วนพื้นที่ภาพที่เปลี่ยน ถือว่า "ขยับ" (ใช้ตัดสินว่าควรถามโมเดลไหม)
REPEAT_COOLDOWN = 60.0       # สิ่งที่เฝ้าดูแบบซ้ำ แจ้งซ้ำได้หลังกี่วินาที

_TH = {"person": "คน", "face": "ใบหน้า", "cat": "แมว", "dog": "สุนัข"}
_EVENT_TEXT = {
    "person_arrived": "มีคนมาอยู่หน้ากล้อง",
    "person_left": "คนหน้ากล้องออกไปแล้ว",
    "motion": "มีการเคลื่อนไหวตอนที่ไม่มีคนอยู่หน้ากล้อง",
    "animal_appeared": "เห็นสัตว์: {label}",
    "object_appeared": "เห็นวัตถุ: {label}",
}
_ANALYZE = {"motion", "animal_appeared"}          # เหตุการณ์ที่ให้ LLM ดูภาพแล้วแจ้งเจ้านาย
_WATCH_LINE = re.compile(r"#?\s*(\d+)\s*[:：.)-]\s*(YES|NO|ใช่|ไม่ใช่|ไม่)\b\s*[-–—:]?\s*(.*)", re.I)


def owner() -> str:
    return settings.owner_name or "บอส"


@dataclass
class Watch:
    id: int
    target: str
    until: float
    repeat: bool = False
    created: float = field(default_factory=time.time)
    hits: int = 0
    last_hit: float = 0.0
    last_detail: str = ""


class VisionHub:
    def __init__(self):
        self.agent = None                         # ตั้งโดย server (attach) — ใช้ router + store
        self.frame: dict | None = None            # {"jpeg", "at", "width", "height"} — RAM เท่านั้น
        self.state: dict = {}                     # ผลตรวจจับล่าสุดจากแอป
        self.events: collections.deque = collections.deque(maxlen=200)
        self.watches: list[Watch] = []
        self._next_id = 1
        self._next_event = 1
        self._demand_until = 0.0
        self._demand_reason = ""
        self._say: list[str] = []
        self._checking = False
        self._last_check = 0.0
        self._motion_since_check = 0.0
        self._last_alert: dict[str, float] = {}
        self._tasks: set[asyncio.Task] = set()

    def attach(self, agent) -> None:
        self.agent = agent

    def reset(self) -> None:
        self.__init__()

    # ------------------------------------------------------------------ สถานะ
    @property
    def online(self) -> bool:
        return bool(self.frame) and time.time() - self.frame["at"] < ALIVE_SECONDS

    def frame_age(self) -> float | None:
        return round(time.time() - self.frame["at"], 1) if self.frame else None

    def _spawn(self, coro) -> None:
        task = asyncio.create_task(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    def _active_watches(self) -> list[Watch]:
        now = time.time()
        expired = [w for w in self.watches if w.until <= now]
        for w in expired:
            log("vision_watch_expired", id=w.id, target=w.target)
        self.watches = [w for w in self.watches if w.until > now]
        return self.watches

    def wanted(self) -> str:
        """เหตุผลที่ต้องการให้กล้องเปิดตอนนี้ ("" = ไม่ต้อง)"""
        if self._active_watches():
            return "watch"
        if time.time() < self._demand_until:
            return self._demand_reason or "look"
        return ""

    # ------------------------------------------------------------------ จากแอป
    def update(self, payload: dict) -> dict:
        """POST /api/vision/frame — ผลตรวจจับ (+ ภาพ) ล่าสุด · คืนสิ่งที่แอปต้องทำ (พูด / เปิดกล้องค้างไว้)"""
        now = time.time()
        if payload.get("jpeg"):
            self.frame = {"jpeg": payload["jpeg"], "at": now, "width": payload.get("width"),
                          "height": payload.get("height")}
        self.state = {k: v for k, v in payload.items() if k != "jpeg"} | {"at": now}
        self._motion_since_check = max(self._motion_since_check, float(payload.get("motion") or 0))
        if self._watch_due(now):
            self._spawn(self.check_watches())
        return self._reply()

    def stopped(self) -> None:
        """แอปปิดกล้อง — ลบภาพทิ้งทันที"""
        self.frame = None
        self.state = {}

    def _reply(self) -> dict:
        say, self._say = self._say, []
        return {"say": say, "keep_on": bool(self.wanted()), "watching": len(self.watches)}

    async def event(self, payload: dict) -> dict:
        """POST /api/vision/event — บันทึก แล้วตัดสินว่าจะแจ้งเจ้านายไหม"""
        kind = str(payload.get("kind") or "unknown")
        label = str(payload.get("label") or "")
        th = _TH.get(label.lower(), label)
        ev = {"id": self._next_event, "kind": kind, "label": label, "at": time.time(),
              "text": _EVENT_TEXT.get(kind, kind).format(label=th), "note": ""}
        if payload.get("away_seconds") is not None:
            ev["away_seconds"] = round(float(payload["away_seconds"]))
        self._next_event += 1
        self.events.appendleft(ev)
        log("vision_event", kind=kind, label=label or None, away=ev.get("away_seconds"))
        if payload.get("jpeg"):
            self.frame = {"jpeg": payload["jpeg"], "at": time.time(), "width": payload.get("width"),
                          "height": payload.get("height")}
        if self.watches and not self._checking:
            self._motion_since_check = 1.0            # เหตุการณ์ = ตรวจสิ่งที่เฝ้าดูทันที
            self._spawn(self.check_watches())
        if settings.vision_alerts:
            if kind == "person_arrived":
                self._welcome(ev)
            elif kind in _ANALYZE and self._cool(kind) and self.frame:
                self._spawn(self.analyze(ev))
        return self._reply()

    def _cool(self, kind: str) -> bool:
        now = time.time()
        if now - self._last_alert.get(kind, 0) < settings.vision_alert_cooldown:
            return False
        self._last_alert[kind] = now
        return True

    def _welcome(self, ev: dict) -> None:
        away = ev.get("away_seconds")
        if away is None or away < settings.vision_welcome_after or self.agent is None:
            return
        since = time.time() - away
        missed = [a for a in self.agent.store.announcements(limit=20) if a["created"] >= since and not a["read"]]
        text = f"ยินดีต้อนรับกลับ{settings.particle}{owner()}"
        if missed:
            text += f" ระหว่างที่ไม่อยู่มีเรื่องแจ้ง {len(missed)} เรื่อง ล่าสุดคือ {missed[0]['text'][:120]}"
        ev["note"] = text
        self._say.append(text)
        log("vision_welcome", away=away, missed=len(missed))

    # ------------------------------------------------------------------ ภาพสำหรับ look
    async def need_frame(self, timeout: float = 8.0) -> dict | None:
        """ภาพล่าสุดที่ใหม่พอ — ถ้าไม่มี ขอให้แอปเปิดกล้องแล้วรอภาพใหม่ (None = กล้องไม่ตอบ)"""
        asked = time.time()
        if self.frame and asked - self.frame["at"] < FRESH_SECONDS:
            return self.frame
        self.demand("look")
        deadline = asked + timeout
        while time.time() < deadline:
            # ภาพแรกหลังเปิดกล้องมักมืด (กล้องยังปรับแสง) — รอภาพที่มาหลังขออย่างน้อย 0.8 วิ
            if self.frame and self.frame["at"] > asked + (0.8 if not self.online else 0):
                return self.frame
            await asyncio.sleep(0.1)
        return None

    def demand(self, reason: str, seconds: float = DEMAND_SECONDS) -> None:
        self._demand_until = max(self._demand_until, time.time() + seconds)
        self._demand_reason = reason

    async def wait_demand(self, wait: float) -> dict:
        """GET /api/vision/demand — long-poll ของแอปโหมด "เปิดเมื่อต้องใช้" """
        deadline = time.time() + max(0.0, min(wait, 60.0))
        while True:
            reason = self.wanted()
            if reason or time.time() >= deadline:
                return {"want": bool(reason), "reason": reason,
                        "seconds": max(0.0, round(self._demand_until - time.time(), 1))}
            await asyncio.sleep(0.25)

    def summary(self) -> str:
        """ผลตรวจจับล่าสุดเป็นข้อความ (ให้โมเดลอ่าน — โมเดลที่มองภาพไม่ได้ก็ยังรู้ว่ามีอะไร)"""
        s = self.state
        if not s:
            return "ยังไม่มีผลตรวจจับ"
        parts = []
        for key in ("people", "faces"):
            if s.get(key):
                parts.append(f"{_TH['person' if key == 'people' else 'face']} {s[key]}")
        for a in s.get("animals") or []:
            parts.append(_TH.get(str(a).lower(), str(a)))
        objects = [o for o in s.get("objects") or [] if isinstance(o, dict)]
        if objects:
            parts.append("วัตถุ: " + ", ".join(f"{o.get('label')} ({round(float(o.get('confidence') or 0) * 100)}%)"
                                               for o in objects[:12]))
        lines = ["ตรวจจับบนเครื่อง: " + (" · ".join(parts) if parts else "ไม่พบคน/สัตว์/วัตถุที่รู้จัก")]
        scene = [str(x) for x in s.get("scene") or []][:8]
        if scene:
            lines.append("ฉาก (Apple Vision): " + ", ".join(scene))
        motion = float(s.get("motion") or 0)
        lines.append(f"การเคลื่อนไหว: {'มาก' if motion > 0.15 else 'บ้าง' if motion > MOTION_TRIGGER else 'นิ่ง'} "
                     f"({round(motion * 100)}% ของภาพ)")
        return "\n".join(lines)

    # ------------------------------------------------------------------ เฝ้าดู
    def add_watch(self, target: str, minutes: float = 60, repeat: bool = False) -> Watch:
        minutes = max(1.0, min(float(minutes), 24 * 60))
        w = Watch(self._next_id, target.strip(), time.time() + minutes * 60, repeat)
        self._next_id += 1
        self.watches.append(w)
        self._last_check = 0.0                      # ตรวจรอบแรกทันทีที่ได้ภาพ
        self._motion_since_check = 1.0
        log("vision_watch_added", id=w.id, target=w.target, minutes=minutes, repeat=repeat)
        return w

    def remove_watch(self, watch_id: int) -> bool:
        before = len(self.watches)
        self.watches = [w for w in self.watches if w.id != watch_id]
        return len(self.watches) < before

    def _watch_due(self, now: float) -> bool:
        if self._checking or not self.frame or not self._active_watches():
            return False
        elapsed = now - self._last_check
        if elapsed < settings.vision_watch_interval:
            return False
        return self._motion_since_check >= MOTION_TRIGGER or elapsed >= FORCED_CHECK_SECONDS

    async def _ask(self, prompt: str) -> str | None:
        """ถามโมเดลเบื้องหลัง (APRIL_VISION_MODEL) พร้อมภาพล่าสุด — ไม่มีเครื่องมือ ไม่เก็บประวัติ"""
        if self.agent is None or not self.frame:
            return None
        router = self.agent.router
        model = settings.vision_model or "local"
        if router.catalog.get(model) is None:
            model = "local"
        msg = {"role": "user", "content": prompt, "images": [self.frame["jpeg"]], "camera": True}
        res = await router.generate([msg], [], model=model)
        if not res.ok:
            log("vision_llm_failed", level="warning", model=res.model, error=res.error)
            return None
        return res.text.strip()

    async def check_watches(self) -> list[dict]:
        """ถามโมเดลว่าเห็นสิ่งที่เฝ้าดูหรือยัง -> เจอ = แจ้งเจ้านาย (ครั้งเดียว หรือซ้ำถ้า repeat)"""
        watches = list(self._active_watches())
        if self._checking or not watches or not self.frame:
            return []
        self._checking = True
        self._last_check = time.time()
        self._motion_since_check = 0.0
        hits: list[dict] = []
        try:
            items = "\n".join(f"#{w.id}: {w.target}" for w in watches)
            prompt = (f"(ระบบ) คุณคือ {settings.name} กำลังเฝ้ากล้องของ Mac ให้{owner()} ดูภาพนี้แล้วตอบทีละบรรทัด "
                      "สำหรับทุกข้อ ในรูปแบบ `#<เลข>: YES - <เห็นอะไร สั้นๆ ภาษาไทย>` หรือ `#<เลข>: NO` "
                      "ตอบ YES เฉพาะเมื่อเห็นชัดในภาพจริงๆ ห้ามเดา\n\n"
                      f"{self.summary()}\n\nสิ่งที่ต้องดู:\n{items}")
            answer = await self._ask(prompt)
            if not answer:
                return []
            found = {int(m.group(1)): m.group(3).strip() for m in map(_WATCH_LINE.match, answer.splitlines())
                     if m and m.group(2).upper() in ("YES", "ใช่")}
            now = time.time()
            for w in watches:
                if w.id not in found or (w.repeat and now - w.last_hit < REPEAT_COOLDOWN):
                    continue
                w.hits += 1
                w.last_hit = now
                w.last_detail = found[w.id]
                text = f"เห็นแล้ว{settings.particle}{owner()} — {w.target}" + (f": {found[w.id]}" if found[w.id] else "")
                hits.append({"id": w.id, "target": w.target, "detail": found[w.id]})
                self._alert("watch_hit", "สิ่งที่สั่งให้เฝ้าดู", text, label=w.target)
                if not w.repeat:
                    self.remove_watch(w.id)
            log("vision_watch_check", watches=len(watches), hits=len(hits))
            return hits
        finally:
            self._checking = False

    # ------------------------------------------------------------------ วิเคราะห์เหตุการณ์
    async def analyze(self, ev: dict) -> str | None:
        prompt = (f"(ระบบ) คุณคือ {settings.name} กำลังเฝ้ากล้องของ Mac ให้{owner()} ระบบตรวจพบ: {ev['text']}\n"
                  f"{self.summary()}\n\nดูภาพแล้วบอก{owner()} 1 ประโยคสั้นๆ แบบภาษาพูดว่าเห็นอะไร "
                  f"ลงท้ายด้วย \"{settings.particle}\" · ถ้าไม่มีอะไรน่าสนใจจริง (แค่แสงเปลี่ยน เงา กล้องสั่น ภาพว่าง) "
                  "ให้ตอบคำเดียวว่า NONE")
        answer = await self._ask(prompt)
        if not answer or answer.strip().strip(".").upper() == "NONE" or "NONE" in answer[:8].upper():
            ev["note"] = "(ไม่มีอะไรน่าสนใจ)"
            return None
        ev["note"] = answer
        self._alert(ev["kind"], "การมองเห็น", answer, label=ev.get("label") or "")
        return answer

    def _alert(self, kind: str, title: str, text: str, label: str = "") -> None:
        """แจ้งเจ้านาย: ประกาศ (แท็บภาพรวม) + แจ้งเตือนขึ้นจอ + ให้แอปพูด"""
        from april.tools.builtin import mac_notify

        if self.agent is not None:
            self.agent.store.announce("vision", title, text)
        self._say.append(text)
        if kind == "watch_hit":
            self.events.appendleft({"id": self._next_event, "kind": kind, "label": label, "at": time.time(),
                                    "text": f"เจอสิ่งที่เฝ้าดู: {label}", "note": text})
            self._next_event += 1
        log("vision_alert", kind=kind, text=text[:160])
        self._spawn(mac_notify(f"{settings.name} · {title}", text))

    # ------------------------------------------------------------------ ศูนย์ควบคุม
    def describe(self) -> dict:
        s = {k: v for k, v in self.state.items() if k != "at"}
        return {"online": self.online, "frame_age": self.frame_age(), "wanted": self.wanted(), "state": s,
                "summary": self.summary() if self.state else "",
                "events": list(self.events)[:50],
                "watches": [asdict(w) | {"minutes_left": max(0, round((w.until - time.time()) / 60))}
                            for w in self._active_watches()],
                "settings": {"model": settings.vision_model, "cloud": settings.vision_cloud,
                             "alerts": settings.vision_alerts, "watch_interval": settings.vision_watch_interval,
                             "alert_cooldown": settings.vision_alert_cooldown,
                             "welcome_after": settings.vision_welcome_after}}


hub = VisionHub()
