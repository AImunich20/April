"""
april/system_monitor.py
-------------------------
ข้อมูล RAM ของเครื่อง + โมเดลที่ค้างอยู่ใน Ollama สำหรับแท็บ RAM ของ Control Center (ย่อจาก /api/power ของ Envy)
ปลดโมเดลออกจาก RAM = POST /api/generate {model, keep_alive: 0} ของ Ollama — ข้อมูล/ความจำไม่หาย คำถามถัดไปโหลดใหม่เอง
"""

import asyncio
import os
import re
import subprocess

import httpx

from april.config import settings


def _run(*cmd: str) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def memory() -> dict:
    """RAM ทั้งเครื่อง (macOS: sysctl + vm_stat) — ว่าง = free + inactive + speculative (macOS คืนให้แอปอื่นได้ทันที)"""
    try:
        total = int(_run("sysctl", "-n", "hw.memsize").strip())
        vm = _run("vm_stat")
        page = int(re.search(r"page size of (\d+)", vm).group(1))

        def pages(label: str) -> int:
            m = re.search(rf"{label}:\s+(\d+)", vm)
            return int(m.group(1)) if m else 0
        free = (pages("Pages free") + pages("Pages inactive") + pages("Pages speculative")) * page
    except (ValueError, AttributeError):
        return {}
    free_pct = free / total * 100
    pressure = "ต่ำ" if free_pct >= 25 else "ปานกลาง" if free_pct >= 10 else "สูง"
    return {"total": total, "used": total - free, "free_percent": round(free_pct, 1), "pressure": pressure}


def processes() -> list[dict]:
    """process ของ April (เซิร์ฟเวอร์นี้) และ Ollama — rss เป็นไบต์"""
    out = []
    me = os.getpid()
    for line in _run("ps", "-axo", "pid=,rss=,comm=").splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3 or not parts[0].isdigit():
            continue
        pid, rss, comm = int(parts[0]), int(parts[1]) * 1024, parts[2]
        if pid == me:
            out.append({"name": "April (เซิร์ฟเวอร์)", "pid": pid, "rss": rss})
        elif "ollama" in comm.lower():
            out.append({"name": "Ollama", "pid": pid, "rss": rss})
    return out


async def loaded_models() -> list[dict]:
    try:
        async with httpx.AsyncClient(base_url=settings.ollama_url, timeout=3.0) as client:
            data = (await client.get("/api/ps")).json()
    except (httpx.HTTPError, ValueError):
        return []
    return [{"name": m.get("name"), "size": m.get("size"), "size_vram": m.get("size_vram"),
             "expires_at": m.get("expires_at"), "embedding": "embed" in (m.get("name") or "")}
            for m in data.get("models", [])]


async def unload(names: list[str]) -> list[str]:
    done = []
    async with httpx.AsyncClient(base_url=settings.ollama_url, timeout=15.0) as client:
        for name in names:
            try:
                r = await client.post("/api/generate", json={"model": name, "keep_alive": 0})
                if r.status_code < 400:
                    done.append(name)
            except httpx.HTTPError:
                pass
    return done


async def power() -> dict:
    models = await loaded_models()
    mem, procs = await asyncio.to_thread(memory), await asyncio.to_thread(processes)
    return {"memory": mem, "models": models, "models_bytes": sum(m.get("size") or 0 for m in models),
            "processes": procs}


async def clear(busy: set[str] = frozenset()) -> dict:
    """ปลดทุกโมเดลที่ไม่ได้กำลังตอบ"""
    before = await asyncio.to_thread(memory)
    models = await loaded_models()
    targets = [m["name"] for m in models if m["name"] not in busy]
    unloaded = await unload(targets)
    await asyncio.sleep(0.5)
    return {"unloaded": unloaded, "skipped": [m["name"] for m in models if m["name"] in busy],
            "bytes": sum(m.get("size") or 0 for m in models if m["name"] in unloaded),
            "before": before, "after": await asyncio.to_thread(memory)}
