"""
april/agent/numbers.py
------------------------
ตรวจว่าคำตอบใช้ตัวเลขตรงกับผลของเครื่องมือ calculate (agent/loop.py -> Agent._check_numbers)
"""

import re

_RESULT = re.compile(r"=\s*(-?[\d,]+(?:\.\d+)?)\s*$")
_NUMBER = re.compile(r"-?\d[\d,]*(?:\.\d+)?")


def _value(text: str) -> float | None:
    try:
        return float(text.replace(",", ""))
    except ValueError:
        return None


def last_result(messages: list[dict]) -> str | None:
    """ผลของ calculate ครั้งล่าสุดในรอบนี้ (เช่น "67,500") — ไม่มี/ล้ม = None"""
    for m in reversed(messages):
        if m.get("role") == "tool" and m.get("name") == "calculate" and not m.get("is_error"):
            match = _RESULT.search(str(m.get("content") or ""))
            return match.group(1) if match else None
    return None


def mentions(answer: str, expected: str) -> bool:
    """คำตอบมีตัวเลขนี้ไหม (67,500 = 67500 = 67500.0)"""
    want = _value(expected)
    if want is None:
        return True
    return any(v is not None and abs(v - want) < 1e-9 * max(1.0, abs(want)) for v in map(_value, _NUMBER.findall(answer)))


def fix_instruction(expected: str) -> str:
    return (f"(ระบบ) คำตอบก่อนหน้าใช้ตัวเลขไม่ตรงกับผลการคำนวณ ผลที่ถูกต้องคือ {expected} "
            f"เขียนคำตอบใหม่ทั้งหมดโดยใส่ตัวเลข {expected} เป็นตัวเลขตรงๆ (ห้ามเขียนเป็นคำอ่าน) ไม่ต้องพูดถึงการแก้ไขนี้")
