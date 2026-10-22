"""
april/observability.py
------------------------
log ทุกเหตุการณ์ของ April
  - เขียนลงไฟล์ data/logs/april.jsonl (บรรทัดละเหตุการณ์ อ่านย้อนหลังด้วย jq ได้)
  - เก็บล่าสุด 2,000 รายการในหน่วยความจำ + ส่งสดให้ผู้ที่ subscribe (แท็บ Log ของ Control Center: /api/events/stream)
เหตุการณ์ = {ts, type, level (info/warning/error), trace_id, data}
"""

import asyncio
import collections
import json
import sys
import time

from april.config import settings

_buffer: collections.deque = collections.deque(maxlen=2000)
_subscribers: set[asyncio.Queue] = set()


def log(event: str, *, level: str = "info", trace_id: str = "-", **fields) -> None:
    rec = {"ts": round(time.time(), 3), "type": event, "level": level, "trace_id": trace_id, "data": fields}
    _buffer.append(rec)
    for q in list(_subscribers):
        try:
            q.put_nowait(rec)
        except asyncio.QueueFull:
            pass
    line = json.dumps(rec, ensure_ascii=False, default=str)
    try:
        path = settings.data_dir / "logs" / "april.jsonl"
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        print(line, file=sys.stderr)


def recent(limit: int = 300) -> list[dict]:
    """ล่าสุดก่อน"""
    return list(_buffer)[-limit:][::-1]


def subscribe() -> asyncio.Queue:
    q: asyncio.Queue = asyncio.Queue(maxsize=500)
    _subscribers.add(q)
    return q


def unsubscribe(q: asyncio.Queue) -> None:
    _subscribers.discard(q)
