"""
april/tools/builtin.py
------------------------
เครื่องมือในตัวของพ่อบ้าน April
  ข้อมูล       current_datetime, calculate, web_search, read_webpage
  ความจำ       remember, recall, forget
  ตัวเตือน      set_reminder, list_reminders, cancel_reminder
  เครื่อง Mac   system_status, open_app, open_url, notify          (action — ทำงานกับเครื่องจริง)
ไม่มีเครื่องมือรันคำสั่ง shell — ทุกอย่างที่ทำกับเครื่องผ่านคำสั่งที่กำหนดไว้แล้วเท่านั้น
"""

import ast
import asyncio
import ipaddress
import math
import os
import platform
import re
import shutil
import socket
import time
from datetime import datetime, timedelta
from urllib.parse import urljoin, urlparse
from zoneinfo import ZoneInfo

import httpx

from april.config import settings
from april.tools.registry import ToolContext, registry

_TH_DAYS = ["จันทร์", "อังคาร", "พุธ", "พฤหัสบดี", "ศุกร์", "เสาร์", "อาทิตย์"]
_TH_MONTHS = ["มกราคม", "กุมภาพันธ์", "มีนาคม", "เมษายน", "พฤษภาคม", "มิถุนายน", "กรกฎาคม", "สิงหาคม",
              "กันยายน", "ตุลาคม", "พฤศจิกายน", "ธันวาคม"]


def tz() -> ZoneInfo:
    return ZoneInfo(settings.timezone)


def thai_datetime(dt: datetime) -> str:
    return (f"วัน{_TH_DAYS[dt.weekday()]}ที่ {dt.day} {_TH_MONTHS[dt.month - 1]} {dt.year + 543} "
            f"เวลา {dt:%H:%M} น.")


async def _run(*cmd: str, timeout: float = 10.0) -> str:
    proc = await asyncio.create_subprocess_exec(*cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    out, err = await asyncio.wait_for(proc.communicate(), timeout)
    if proc.returncode != 0:
        raise RuntimeError((err or out).decode(errors="replace").strip()[:200] or f"exit {proc.returncode}")
    return out.decode(errors="replace").strip()


def _is_mac() -> bool:
    return platform.system() == "Darwin"


# ====================================================================== ข้อมูล
@registry.tool("current_datetime", "วันที่และเวลาปัจจุบันตามเขตเวลาของเจ้านาย")
async def current_datetime() -> str:
    now = datetime.now(tz())
    return f"{thai_datetime(now)} ({settings.timezone}, ISO {now.isoformat(timespec='minutes')})"


_FUNCS = {k: getattr(math, k) for k in ("sqrt", "log", "log10", "log2", "exp", "sin", "cos", "tan", "asin", "acos",
                                        "atan", "floor", "ceil", "factorial", "radians", "degrees")}
_FUNCS.update(abs=abs, round=round, min=min, max=max)
_CONSTS = {"pi": math.pi, "e": math.e}
_BINOPS = {ast.Add: lambda a, b: a + b, ast.Sub: lambda a, b: a - b, ast.Mult: lambda a, b: a * b,
           ast.Div: lambda a, b: a / b, ast.FloorDiv: lambda a, b: a // b, ast.Mod: lambda a, b: a % b,
           ast.Pow: lambda a, b: a ** b}


def _eval(node):
    """ไล่ AST เอง (ไม่ใช้ eval) และตรวจขนาดก่อนยกกำลัง/factorial — กันนิพจน์อย่าง 9**9**9 ทำเครื่องค้าง"""
    if isinstance(node, ast.Expression):
        return _eval(node.body)
    if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)) and not isinstance(node.value, bool):
        return node.value
    if isinstance(node, ast.Name) and node.id in _CONSTS:
        return _CONSTS[node.id]
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.USub, ast.UAdd)):
        value = _eval(node.operand)
        return -value if isinstance(node.op, ast.USub) else value
    if isinstance(node, ast.BinOp) and type(node.op) in _BINOPS:
        left, right = _eval(node.left), _eval(node.right)
        if isinstance(node.op, ast.Pow) and left not in (0, 1, -1) and (
                abs(right) > 1000 or abs(right) * math.log10(abs(left)) > 400):
            raise ValueError("เลขยกกำลังใหญ่เกินไป")
        return _BINOPS[type(node.op)](left, right)
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in _FUNCS and not node.keywords:
        args = [_eval(a) for a in node.args]
        if node.func.id == "factorial" and args and args[0] > 500:
            raise ValueError("factorial ใหญ่เกินไป")
        return _FUNCS[node.func.id](*args)
    raise ValueError(f"ใช้ไม่ได้ในนิพจน์: {ast.dump(node)[:40]}")


def safe_eval(expression: str) -> float:
    return _eval(ast.parse(expression.replace("^", "**").replace(",", ""), mode="eval"))


@registry.tool("calculate", "คำนวณนิพจน์คณิตศาสตร์ให้แม่นยำ (+ - * / ** % sqrt log sin ...) ใช้ทุกครั้งที่ต้องคิดเลข",
               {"type": "object", "properties": {"expression": {"type": "string", "description": "เช่น (1500*12)*0.07"}},
                "required": ["expression"]})
async def calculate(expression: str) -> str:
    value = safe_eval(expression)
    if isinstance(value, float) and value.is_integer() and abs(value) < 1e15:
        value = int(value)
    return f"{expression} = {value:,}" if isinstance(value, int) else f"{expression} = {value:,.6g}"


@registry.tool("web_search", "ค้นเว็บหาข้อมูลล่าสุด ข่าว ราคา หรือสิ่งที่ไม่แน่ใจ (DuckDuckGo)",
               {"type": "object", "properties": {"query": {"type": "string"},
                                                 "max_results": {"type": "integer", "description": "1-10 (ค่าเริ่มต้น 5)"}},
                "required": ["query"]})
async def web_search(query: str, max_results: int = 5) -> list[dict]:
    from ddgs import DDGS

    n = max(1, min(int(max_results), 10))
    results = await asyncio.to_thread(lambda: list(DDGS().text(query, max_results=n)))
    return [{"title": r.get("title"), "url": r.get("href"), "snippet": r.get("body")} for r in results]


def _public_host(url: str) -> None:
    """กัน SSRF: ห้ามเปิดที่อยู่ในเครื่อง/วง LAN (ลิงก์ในหน้าเว็บที่ไม่น่าไว้ใจอาจชี้มาที่ระบบในบ้าน)"""
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise ValueError("เปิดได้เฉพาะลิงก์ http/https")
    for info in socket.getaddrinfo(parsed.hostname, parsed.port or (443 if parsed.scheme == "https" else 80)):
        ip = ipaddress.ip_address(info[4][0])
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved or ip.is_multicast:
            raise ValueError("ไม่เปิดที่อยู่ภายในเครื่องหรือวง LAN")


@registry.tool("read_webpage", "อ่านเนื้อหาหลักของหน้าเว็บจากลิงก์ (ใช้ต่อจาก web_search เมื่อต้องการรายละเอียด)",
               {"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]})
async def read_webpage(url: str) -> str:
    import trafilatura

    async with httpx.AsyncClient(timeout=20.0, headers={"User-Agent": "Mozilla/5.0 April"}) as client:
        for _ in range(4):   # ตาม redirect เองเพื่อตรวจปลายทางทุกครั้ง
            await asyncio.to_thread(_public_host, url)
            r = await client.get(url)
            if r.is_redirect and r.headers.get("location"):
                url = urljoin(url, r.headers["location"])
                continue
            r.raise_for_status()
            break
        else:
            raise ValueError("redirect มากเกินไป")
    html = r.text[:2_000_000]
    text = await asyncio.to_thread(trafilatura.extract, html, url=url) or ""
    if not text:
        return "หน้านี้ไม่มีเนื้อหาที่อ่านได้ (อาจต้องใช้ JavaScript)"
    return text[:6000] + ("\n…(ตัดส่วนที่เหลือ)" if len(text) > 6000 else "")


# ====================================================================== ความจำ
@registry.tool("remember", "จดสิ่งที่ควรจำเรื่องเจ้านายไว้ถาวร (ความชอบ คนรอบตัว นัด ข้อมูลส่วนตัวที่เจ้านายบอก)",
               {"type": "object", "properties": {"fact": {"type": "string", "description": "ประโยคสั้นที่อ่านเข้าใจได้ในภายหลัง"}},
                "required": ["fact"]})
async def remember(fact: str, ctx: ToolContext) -> str:
    note_id = ctx.store.add_note(fact)
    return f"จดแล้ว (#{note_id})"


@registry.tool("recall", "ค้นความจำเรื่องเจ้านายที่จดไว้",
               {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]})
async def recall(query: str, ctx: ToolContext) -> list[dict] | str:
    found = ctx.store.search_notes(query)
    return [{"id": n["id"], "fact": n["text"]} for n in found] or "ไม่พบในความจำ"


@registry.tool("forget", "ลบความจำที่จดไว้ (ใช้ id จาก recall)",
               {"type": "object", "properties": {"id": {"type": "integer"}}, "required": ["id"]})
async def forget(id: int, ctx: ToolContext) -> str:  # noqa: A002 — ชื่อ argument ที่โมเดลเห็น
    return "ลบแล้ว" if ctx.store.delete_note(id) else "ERROR: ไม่พบความจำ id นี้"


# ====================================================================== ตัวเตือน
def parse_when(at: str | None, in_minutes: float | None, now: datetime | None = None) -> datetime:
    now = now or datetime.now(tz())
    if in_minutes is not None:
        if in_minutes <= 0:
            raise ValueError("in_minutes ต้องมากกว่า 0")
        return now + timedelta(minutes=in_minutes)
    if not at:
        raise ValueError("ต้องระบุ at หรือ in_minutes")
    when = datetime.fromisoformat(at.strip().replace(" ", "T"))
    if when.tzinfo is None:
        when = when.replace(tzinfo=tz())
    if when <= now:
        raise ValueError(f"เวลา {when:%Y-%m-%d %H:%M} ผ่านไปแล้ว (ตอนนี้ {now:%Y-%m-%d %H:%M})")
    return when


@registry.tool("set_reminder", "ตั้งเตือนเจ้านาย เมื่อถึงเวลา April จะแจ้งขึ้นจอเอง ระบุ at (เวลาแบบ ISO ตามเขตเวลาเจ้านาย "
               "เช่น 2026-10-22T18:30) หรือ in_minutes อย่างใดอย่างหนึ่ง",
               {"type": "object", "properties": {"text": {"type": "string", "description": "เตือนเรื่องอะไร"},
                                                 "at": {"type": "string"}, "in_minutes": {"type": "number"}},
                "required": ["text"]})
async def set_reminder(text: str, ctx: ToolContext, at: str | None = None, in_minutes: float | None = None) -> str:
    when = parse_when(at, in_minutes)
    rid = ctx.store.add_reminder(text, when.timestamp())
    return f"ตั้งเตือน #{rid} แล้ว: {text} — {thai_datetime(when)}"


@registry.tool("list_reminders", "รายการตัวเตือนที่ยังไม่ถึงเวลา")
async def list_reminders(ctx: ToolContext) -> list[dict] | str:
    items = ctx.store.reminders()
    return [{"id": r["id"], "text": r["text"], "when": thai_datetime(datetime.fromtimestamp(r["due_at"], tz()))}
            for r in items] or "ไม่มีตัวเตือนค้างอยู่"


@registry.tool("cancel_reminder", "ยกเลิกตัวเตือน (ใช้ id จาก list_reminders)",
               {"type": "object", "properties": {"id": {"type": "integer"}}, "required": ["id"]})
async def cancel_reminder(id: int, ctx: ToolContext) -> str:  # noqa: A002
    return "ยกเลิกแล้ว" if ctx.store.finish_reminder(id) else "ERROR: ไม่พบตัวเตือน id นี้ (หรือแจ้งไปแล้ว)"


# ====================================================================== เครื่อง Mac
async def system_info() -> dict:
    info: dict = {"cpu_cores": os.cpu_count()}
    load = os.getloadavg()
    info["cpu_load_1m_percent"] = round(load[0] / (os.cpu_count() or 1) * 100)
    disk = shutil.disk_usage("/")
    info["disk_free_gb"] = round(disk.free / 1e9, 1)
    info["disk_used_percent"] = round(disk.used / disk.total * 100)
    if not _is_mac():
        return info
    try:
        batt = await _run("pmset", "-g", "batt")
        pct = re.search(r"(\d+)%", batt)
        info["battery_percent"] = int(pct.group(1)) if pct else None
        info["power"] = "สายชาร์จ" if "AC Power" in batt else "แบตเตอรี่"
        state = re.search(r"\d+%;\s*([^;]+);", batt)
        if state:
            info["battery_state"] = state.group(1).strip()
        remaining = re.search(r"(\d+:\d+) remaining", batt)
        # ไม่มีตัวเลขนี้ (macOS ยังประเมินไม่เสร็จ) ต้องบอกโมเดลตรงๆ ไม่งั้นโมเดลเดาเวลาเอง
        info["battery_time_remaining"] = remaining.group(1) if remaining else "ยังไม่ทราบ (macOS กำลังประเมิน)"
    except (RuntimeError, OSError, asyncio.TimeoutError):
        pass
    try:
        total = int(await _run("sysctl", "-n", "hw.memsize"))
        vm = await _run("vm_stat")
        page = int(re.search(r"page size of (\d+)", vm).group(1))
        free = sum(int(re.search(rf"{k}:\s+(\d+)", vm).group(1)) for k in ("Pages free", "Pages inactive",
                                                                           "Pages speculative"))
        info["memory_total_gb"] = round(total / 1e9, 1)
        info["memory_used_percent"] = round((1 - free * page / total) * 100)
        boot = int(re.search(r"sec = (\d+)", await _run("sysctl", "-n", "kern.boottime")).group(1))
        info["uptime_hours"] = round((time.time() - boot) / 3600, 1)
    except (RuntimeError, OSError, AttributeError, ValueError, asyncio.TimeoutError):
        pass
    return info


@registry.tool("system_status", "สถานะเครื่อง Mac ของเจ้านาย: แบตเตอรี่ CPU หน่วยความจำ พื้นที่ดิสก์ เวลาที่เปิดเครื่อง")
async def system_status() -> dict:
    return await system_info()


_APP_NAME = re.compile(r"^[\w .&'+()-]{1,60}$")


@registry.tool("open_app", "เปิดแอปบน Mac ตามชื่อ (เช่น Safari, Music, Calendar, Visual Studio Code)",
               {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}, action=True)
async def open_app(name: str) -> str:
    if not _is_mac():
        return "ERROR: ใช้ได้เฉพาะบน macOS"
    if not _APP_NAME.match(name) or name.startswith("-"):
        return "ERROR: ชื่อแอปไม่ถูกต้อง"
    await _run("open", "-a", name)
    return f"เปิด {name} แล้ว"


@registry.tool("open_url", "เปิดลิงก์เว็บในเบราว์เซอร์ของเจ้านาย",
               {"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]}, action=True)
async def open_url(url: str) -> str:
    if urlparse(url).scheme not in ("http", "https"):
        return "ERROR: เปิดได้เฉพาะลิงก์ http/https"
    if not _is_mac():
        return "ERROR: ใช้ได้เฉพาะบน macOS"
    await _run("open", url)
    return f"เปิด {url} แล้ว"


async def mac_notify(title: str, message: str) -> None:
    """แจ้งเตือนขึ้นจอ macOS — ส่งข้อความผ่าน argv (ไม่ต่อสตริงเข้า AppleScript จึงไม่โดน injection)"""
    if not (_is_mac() and settings.notify_mac):
        return
    await _run("osascript", "-e", "on run argv", "-e",
               "display notification (item 2 of argv) with title (item 1 of argv) sound name \"Glass\"",
               "-e", "end run", title[:120], message[:400])


@registry.tool("notify", "แจ้งเตือนขึ้นจอ Mac ทันที",
               {"type": "object", "properties": {"title": {"type": "string"}, "message": {"type": "string"}},
                "required": ["title", "message"]}, action=True)
async def notify(title: str, message: str) -> str:
    if not _is_mac():
        return "ERROR: ใช้ได้เฉพาะบน macOS"
    await mac_notify(title, message)
    return "แจ้งเตือนแล้ว"
