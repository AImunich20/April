"""
april/tools/vision.py
-----------------------
เครื่องมือการมองเห็น (ตาของ April = กล้อง Mac ผ่านแอป — ดู april/vision.py)
  look            มองตอนนี้: ภาพจริงจากกล้อง + สิ่งที่ตรวจเจอบนเครื่อง (คน ใบหน้า สัตว์ วัตถุ การเคลื่อนไหว)
  vision_events   เหตุการณ์ที่กล้องเห็นย้อนหลัง (ใครมา/ไป อะไรขยับ)
  watch_for       สั่งให้เฝ้าดูแล้วบอกเมื่อเห็นสิ่งที่กำหนด · list_watches · stop_watching
"""

import time
from datetime import datetime

from april.tools.builtin import thai_datetime, tz
from april.tools.registry import ToolOutput, registry
from april.vision import hub

_NO_CAMERA = ("ERROR: กล้องไม่ส่งภาพมา — การมองเห็นอาจปิดอยู่ หรือแอป April ไม่ได้เปิด/ยังไม่ได้รับสิทธิ์กล้อง "
              "(เปิดได้ที่ศูนย์ควบคุม › แท็บการมองเห็น) บอกเจ้านายตามนี้ ห้ามเดาว่าเห็นอะไร")


@registry.tool("look", "มองผ่านกล้องของ Mac ตอนนี้ (ตาของ April) ได้ภาพจริง + สิ่งที่ตรวจเจอบนเครื่อง "
               "(คน ใบหน้า สัตว์ วัตถุ การเคลื่อนไหว) ใช้ทุกครั้งที่ถูกถามถึงสิ่งที่อยู่หน้ากล้อง ถือของอะไร "
               "แต่งตัวยังไง ห้องเป็นยังไง หรือ \"ดูนี่หน่อย\" — ห้ามเดาโดยไม่มอง",
               {"type": "object", "properties": {
                   "focus": {"type": "string", "description": "อยากดูอะไรเป็นพิเศษ (ไม่บังคับ) เช่น ของในมือ"}}})
async def look(focus: str = "") -> ToolOutput | str:
    frame = await hub.need_frame()
    if frame is None:
        return _NO_CAMERA
    age = max(0.0, time.time() - frame["at"])
    size = f" ({frame['width']}×{frame['height']})" if frame.get("width") else ""
    text = (f"ภาพจากกล้อง Mac เมื่อ {age:.1f} วินาทีที่แล้ว{size} แนบมาด้วย\n{hub.summary()}"
            + (f"\nสิ่งที่ต้องดูเป็นพิเศษ: {focus}" if focus else "")
            + "\n(ตอบจากสิ่งที่เห็นในภาพจริง ผลตรวจจับเป็นแค่ตัวช่วย อาจพลาดได้)")
    return ToolOutput(text, [frame["jpeg"]], camera=True)


@registry.tool("vision_events", "เหตุการณ์ที่กล้องเห็นย้อนหลัง (คนมา/ไป ขยับตอนไม่มีคน สัตว์ วัตถุ สิ่งที่เฝ้าดู) "
               "ใช้เมื่อถูกถามว่าเมื่อกี้มีใครมา มีอะไรเกิดขึ้นระหว่างที่ไม่อยู่ หรือถามถึงสิ่งที่ April เพิ่งแจ้ง",
               {"type": "object", "properties": {"minutes": {"type": "integer", "description": "ย้อนกี่นาที (ค่าเริ่มต้น 60)"}}})
async def vision_events(minutes: int = 60) -> list[dict] | str:
    since = time.time() - max(1, minutes) * 60
    found = [{"when": thai_datetime(datetime.fromtimestamp(e["at"], tz())), "what": e["text"],
              **({"April_said": e["note"]} if e.get("note") else {}),
              **({"away_minutes": round(e["away_seconds"] / 60)} if e.get("away_seconds") else {})}
             for e in hub.events if e["at"] >= since]
    if found:
        return found
    return ("ไม่มีเหตุการณ์ในช่วงนี้" + ("" if hub.online else
            " (กล้องไม่ได้เปิดเฝ้าดูอยู่ — เหตุการณ์บันทึกได้เฉพาะโหมดเปิดตลอดหรือขณะเฝ้าดู)"))


@registry.tool("watch_for", "สั่งให้ April เฝ้ากล้องแล้วบอกเจ้านาย (พูด + แจ้งเตือน) เมื่อเห็นสิ่งที่กำหนด "
               "เช่น \"บอกเมื่อแมวขึ้นโต๊ะ\" \"ถ้ามีคนเข้ามาให้บอก\" \"บอกเมื่อผมยกมือ\" — "
               "กล้องจะเปิดค้างระหว่างเฝ้าดู · ค่าเริ่มต้นแจ้งครั้งเดียวแล้วเลิก (repeat=true = แจ้งทุกครั้งที่เห็น)",
               {"type": "object", "properties": {
                   "target": {"type": "string", "description": "สิ่งที่ต้องดู อธิบายเป็นประโยคชัดๆ"},
                   "minutes": {"type": "number", "description": "เฝ้านานกี่นาที (ค่าเริ่มต้น 60 สูงสุด 1440)"},
                   "repeat": {"type": "boolean"}},
                "required": ["target"]})
async def watch_for(target: str, minutes: float = 60, repeat: bool = False) -> str:
    w = hub.add_watch(target, minutes, repeat)
    hub.demand("watch")
    note = "" if hub.online else " (กล้องจะเปิดเองถ้าการมองเห็นอยู่ในโหมดเปิดเมื่อต้องใช้หรือเปิดตลอด)"
    left = round((w.until - time.time()) / 60)
    return f"เริ่มเฝ้าดู #{w.id}: {w.target} — นาน {left} นาที{', แจ้งทุกครั้งที่เห็น' if repeat else ''}{note}"


@registry.tool("list_watches", "รายการสิ่งที่กำลังเฝ้าดูผ่านกล้อง")
async def list_watches() -> list[dict] | str:
    return [{"id": w["id"], "target": w["target"], "minutes_left": w["minutes_left"], "repeat": w["repeat"],
             "hits": w["hits"]} for w in hub.describe()["watches"]] or "ไม่ได้เฝ้าดูอะไรอยู่"


@registry.tool("stop_watching", "เลิกเฝ้าดู (ใช้ id จาก list_watches หรือ watch_for)",
               {"type": "object", "properties": {"id": {"type": "integer"}}, "required": ["id"]})
async def stop_watching(id: int) -> str:  # noqa: A002 — ชื่อ argument ที่โมเดลเห็น
    return "เลิกเฝ้าดูแล้ว" if hub.remove_watch(id) else "ERROR: ไม่พบสิ่งที่เฝ้าดู id นี้"
