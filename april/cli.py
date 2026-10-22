"""
april/cli.py
--------------
python -m april chat [--model ID]     คุยในเทอร์มินัล (มีตัวเตือนเบื้องหลังระหว่างคุย)
python -m april ask "ข้อความ"          ถามครั้งเดียว
python -m april serve                 เปิด HTTP API (http://127.0.0.1:8100)
python -m april models                ดูโมเดลที่ตั้งค่าไว้
python -m april briefing              สรุปประจำวันตอนนี้

ในโหมด chat: /new = เริ่มบทสนทนาใหม่ · /model <id> = เปลี่ยนโมเดล · /notes · /reminders · /exit
"""

import argparse
import asyncio
import json
import sys

from april.config import settings

DIM, CYAN, YELLOW, RED, BOLD, RESET = "\033[2m", "\033[36m", "\033[33m", "\033[31m", "\033[1m", "\033[0m"
if not sys.stdout.isatty():
    DIM = CYAN = YELLOW = RED = BOLD = RESET = ""


def _agent():
    from april.agent.loop import Agent
    from april.memory.store import Store

    return Agent(Store(settings.db_path))


async def _print_turn(agent, text: str, session_id: str | None, model: str | None) -> str | None:
    thinking_shown = False
    async for ev in agent.run(text, session_id=session_id, model=model):
        kind = ev["type"]
        if kind == "session":
            session_id = ev["session_id"]
        elif kind == "thinking" and not thinking_shown:
            print(f"{DIM}(กำลังคิด…){RESET}", flush=True)
            thinking_shown = True
        elif kind == "token":
            print(ev["text"], end="", flush=True)
        elif kind == "tool_call":
            args = json.dumps(ev["arguments"], ensure_ascii=False)
            print(f"{DIM}→ {ev['name']}({args[:120]}){RESET}", flush=True)
        elif kind == "tool_result" and not ev["ok"]:
            print(f"{DIM}{RED}  ✗ {ev['preview'][:160]}{RESET}", flush=True)
        elif kind == "fallback":
            print(f"{YELLOW}[{ev['from']} ใช้ไม่ได้ → {ev['to']}] {ev['reason'][:120]}{RESET}", flush=True)
        elif kind == "revision":
            print(f"\n{YELLOW}[ตรวจแล้วยังไม่ผ่านเงื่อนไข — แก้คำตอบ]{RESET}", flush=True)
        elif kind == "error":
            print(f"\n{RED}ผิดพลาด: {ev['message']}{RESET}", flush=True)
        elif kind == "done":
            print(f"\n{DIM}— {ev.get('model')}{RESET}\n", flush=True)
    return session_id


async def chat(model: str | None) -> None:
    from april.scheduler import Scheduler

    agent = _agent()
    scheduler = Scheduler(agent)
    scheduler.start()
    session_id = None
    ready = [m["id"] for m in agent.router.describe() if m["ready"]]
    print(f"{BOLD}{CYAN}{settings.name}{RESET} พร้อมรับใช้ครับ · โมเดล: {model or settings.default_model} "
          f"(พร้อมใช้: {', '.join(ready)}) · /exit เพื่อออก\n")
    loop = asyncio.get_running_loop()
    try:
        while True:
            try:
                line = (await loop.run_in_executor(None, input, f"{BOLD}คุณ ›{RESET} ")).strip()
            except EOFError:
                break
            if not line:
                continue
            if line in ("/exit", "/quit"):
                break
            if line == "/new":
                session_id = None
                print(f"{DIM}เริ่มบทสนทนาใหม่{RESET}")
                continue
            if line.startswith("/model"):
                model = line.split(maxsplit=1)[1] if " " in line else None
                print(f"{DIM}ใช้โมเดล: {model or settings.default_model}{RESET}")
                continue
            if line == "/notes":
                for n in agent.store.notes():
                    print(f"  #{n['id']} {n['text']}")
                continue
            if line == "/reminders":
                for r in agent.store.reminders():
                    print(f"  #{r['id']} {r['text']}")
                continue
            for a in agent.store.announcements(unread_only=True):
                print(f"{YELLOW}🔔 {a['title']}: {a['text']}{RESET}")
            agent.store.mark_read()
            print(f"{BOLD}{CYAN}{settings.name} ›{RESET} ", end="", flush=True)
            session_id = await _print_turn(agent, line, session_id, model)
    finally:
        await scheduler.stop()


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="april", description="April — พ่อบ้าน AI ส่วนตัว")
    sub = parser.add_subparsers(dest="cmd")
    p_chat = sub.add_parser("chat", help="คุยในเทอร์มินัล")
    p_chat.add_argument("--model")
    p_ask = sub.add_parser("ask", help="ถามครั้งเดียว")
    p_ask.add_argument("text")
    p_ask.add_argument("--model")
    sub.add_parser("serve", help="เปิด HTTP API")
    sub.add_parser("models", help="ดูโมเดล")
    sub.add_parser("briefing", help="สรุปประจำวันตอนนี้")
    args = parser.parse_args(argv)

    if args.cmd == "serve":
        import uvicorn

        uvicorn.run("april.server:app", host=settings.host, port=settings.port)
    elif args.cmd == "models":
        from april.llm.router import Router

        for m in Router().describe():
            mark = "✔" if m["ready"] else "–"
            print(f" {mark} {m['id']:<14} {m['label']:<28} {m['provider']}:{m['model'] or '(ยังไม่ได้ตั้ง)'}")
        print(f"\nค่าเริ่มต้น: {settings.default_model}")
    elif args.cmd == "ask":
        asyncio.run(_print_turn(_agent(), args.text, None, args.model))
    elif args.cmd == "briefing":
        print(asyncio.run(_agent().briefing()))
    else:
        try:
            asyncio.run(chat(getattr(args, "model", None)))
        except KeyboardInterrupt:
            print()
