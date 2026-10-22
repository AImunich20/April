"""
april/agent/checklist.py
--------------------------
คิดก่อนตอบ ตรวจก่อนส่ง (ย่อจาก Envy agents/checklist.py) — เปิดด้วย APRIL_CHECKLIST_ENABLED=true

1. extract: คำขอที่มีเงื่อนไขชัด (จำนวน งบ รูปแบบ ภาษา สิ่งที่ห้าม) หรือโจทย์ -> เช็กลิสต์สั้นๆ ที่ตรวจได้
2. เช็กลิสต์แนบท้ายคำขอ (โมเดลทำตามเงื่อนไขครบขึ้นเมื่อเห็นเป็นข้อๆ)
3. review: ตรวจคำตอบทีละข้อโดยให้ "นับ/แทนค่าจริง" ก่อนตัดสิน -> ข้อที่ไม่ผ่าน
4. ไม่ผ่าน -> ตอบใหม่ 1 ครั้ง โดยบอกว่าผู้ตรวจอาจผิดได้ ให้ยืนยันคำตอบเดิมถ้าถูกอยู่แล้ว
บทเรียนจาก Envy: ผู้ตรวจที่ตัดสินทันทีโดยไม่ลงมือแทนค่า ปล่อยคำตอบผิดผ่าน, คำตอบที่แก้ตามผู้ตรวจทุกครั้งแย่ลงได้
"""

import json
import re

_CONSTRAINT = re.compile(
    r"(?<![A-Za-z])\d+(?![A-Za-z])|ไม่เกิน|อย่างน้อย|อย่างละ|ห้าม|ต้อง(มี|เป็น|ได้|ไม่)|เท่านั้น|พอดี|ภาษา(อังกฤษ|ไทย|จีน|ญี่ปุ่น)|"
    r"ตาราง|บรรทัด|ประโยค|ย่อหน้า|กี่|เท่าไหร่|เท่าไร|แต่ละ|"
    r"\b(at (least|most)|no more than|exactly|must|only|without|table|in english|how (many|much))\b",
    re.IGNORECASE)
MAX_ITEMS = 5


def wanted(text: str) -> bool:
    text = (text or "").strip()
    return len(text) >= 15 and bool(_CONSTRAINT.search(text))


def _json(raw: str) -> dict:
    match = re.search(r"\{.*\}", raw or "", re.DOTALL)
    try:
        data = json.loads(match.group(0)) if match else {}
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def parse_checks(raw: str) -> list[str]:
    items = _json(raw).get("checks")
    out: list[str] = []
    for item in items if isinstance(items, list) else []:
        text = re.sub(r"\s+", " ", str(item)).strip(" -•*")
        if 4 <= len(text) <= 200 and text.lower() not in (o.lower() for o in out):
            out.append(text)
    return out[:MAX_ITEMS]


def parse_review(raw: str, checks: list[str]) -> list[dict]:
    """-> ข้อที่ไม่ผ่าน [{check, problem}] (อ่านไม่ออก = ถือว่าผ่าน: ไม่ตอบใหม่เพราะผู้ตรวจพัง)"""
    results = _json(raw).get("results")
    failed = []
    for check, result in zip(checks, results if isinstance(results, list) else []):
        if isinstance(result, dict) and result.get("ok") is False:
            failed.append({"check": check, "problem": re.sub(r"\s+", " ", str(result.get("problem") or ""))[:240]})
    return failed


def extract_prompt(question: str) -> str:
    return (
        f"เขียนเช็กลิสต์ไม่เกิน {MAX_ITEMS} ข้อ สำหรับตรวจว่าคำตอบทำตามคำขอครบและถูก มีได้ 2 แบบเท่านั้น:\n"
        "1. เงื่อนไขที่ผู้ใช้เขียนกำหนดไว้เอง: จำนวน ขีดจำกัด รูปแบบ ภาษา สิ่งที่ห้าม ส่วนที่ต้องมีครบ\n"
        "2. ถ้าเป็นโจทย์: สิ่งที่โจทย์ถามหา และความสัมพันธ์ที่คำตอบต้องทำให้เป็นจริงเมื่อแทนค่ากลับ (สมการสั้นๆ)\n"
        "ห้ามคิดคำตอบเอง ห้ามแต่งเงื่อนไขที่ผู้ใช้ไม่ได้ขอ คำขอที่ไม่มีเงื่อนไขให้ checks ว่าง\n\n"
        'ตัวอย่าง: "ขอชื่อแมว 3 ชื่อ เป็นภาษาอังกฤษ" -> {"checks": ["มีชื่อ 3 ชื่อพอดี", "ทุกชื่อเป็นภาษาอังกฤษ"]}\n'
        f'คำขอ: "{question}"\nตอบเป็น JSON อย่างเดียว: {{"checks": [...]}}'
    )


def prompt_block(checks: list[str]) -> str:
    return "\n\n[เงื่อนไขที่คำตอบต้องผ่าน — ห้ามพูดถึงรายการนี้ในคำตอบ]\n" + "\n".join(f"- {c}" for c in checks)


def review_prompt(question: str, answer: str, checks: list[str]) -> str:
    listed = "\n".join(f"{i + 1}. {c}" for i, c in enumerate(checks))
    return (
        f"คำขอ: {question}\n\nคำตอบที่ต้องตรวจ:\n\"\"\"\n{answer[:6000]}\n\"\"\"\n\nเช็กลิสต์:\n{listed}\n\n"
        "ตรวจทีละข้อ: work = นับจริง/บวกจริง/แทนค่ากลับแบบสั้นๆ (เช่น \"10 + 110 = 120 ≠ 110\") แล้วจึงตัดสิน "
        "ok: false เฉพาะเมื่อ work แสดงว่าผิดจริง พร้อม problem บอกว่าผิดตรงไหน\n"
        f'ตอบ JSON อย่างเดียว: {{"results": [{{"work": "...", "ok": true, "problem": ""}}]}} ครบ {len(checks)} ข้อ'
    )


def retry_instruction(failed: list[dict]) -> str:
    fixes = "\n".join(f"- {f['check']}" + (f" — {f['problem']}" if f["problem"] else "") for f in failed)
    return ("(ระบบ) ผู้ตรวจสงสัยว่าคำตอบก่อนหน้ายังไม่ผ่านเงื่อนไขต่อไปนี้:\n" + fixes +
            "\nตรวจเองอีกครั้งอย่างรอบคอบ ถ้าผิดจริงให้แก้ ถ้าถูกอยู่แล้วให้ยืนยันคำตอบเดิม "
            "แล้วเขียนคำตอบฉบับสมบูรณ์ใหม่ทั้งหมด (ไม่พูดถึงผู้ตรวจ)")
