from datetime import datetime, timedelta

from april.agent.loop import Agent
from april.config import settings
from april.llm.router import Router
from april.tools.builtin import tz
from conftest import FakeProvider, catalog, reply


def make_agent(store, local_script, cloud_script=None, cloud_ready=False):
    local = FakeProvider(local_script)
    cloud = FakeProvider(cloud_script or [])
    router = Router(catalog(cloud_ready), providers={"fake_local": local, "fake_cloud": cloud})
    return Agent(store, router), local, cloud


async def events(agent, text, **kw):
    return [e async for e in agent.run(text, **kw)]


async def test_plain_answer_is_streamed_and_saved(store):
    agent, local, _ = make_agent(store, [reply("สวัสดีครับบอส")])
    evs = await events(agent, "สวัสดี")
    assert [e["type"] for e in evs] == ["session", "token", "model", "done"]
    assert evs[-1]["text"] == "สวัสดีครับบอส"
    saved = store.messages(evs[0]["session_id"])
    assert [m["role"] for m in saved] == ["user", "assistant"]
    assert saved[0]["text"] == "สวัสดี" and "[บริบท: ตอนนี้" in saved[0]["content"]


async def test_tool_loop_runs_tools_then_answers(store):
    agent, local, _ = make_agent(store, [
        reply(calls=[("calculate", {"expression": "1500*12"}), ("remember", {"fact": "บอสชอบกาแฟดำ"})]),
        reply("ปีละ 18,000 บาทครับ"),
    ])
    evs = await events(agent, "เดือนละ 1500 ปีละเท่าไหร่ แล้วจำไว้ว่าผมชอบกาแฟดำ")
    results = [e for e in evs if e["type"] == "tool_result"]
    assert [r["ok"] for r in results] == [True, True]
    assert "18,000" in results[0]["preview"]
    assert store.notes()[0]["text"] == "บอสชอบกาแฟดำ"
    # รอบที่สองโมเดลเห็นผลเครื่องมือ
    second = local.calls[1]["messages"]
    assert [m["role"] for m in second[-3:]] == ["assistant", "tool", "tool"]
    assert evs[-1]["text"] == "ปีละ 18,000 บาทครับ"
    roles = [m["role"] for m in store.messages(evs[0]["session_id"])]
    assert roles == ["user", "assistant", "tool", "tool", "assistant"]


async def test_tool_error_goes_back_to_model(store):
    agent, local, _ = make_agent(store, [reply(calls=[("calculate", {})]), reply("ขอโทษครับ")])
    evs = await events(agent, "คิดเลขให้หน่อย")
    result = next(e for e in evs if e["type"] == "tool_result")
    assert not result["ok"] and "expression" in result["preview"]
    assert local.calls[1]["messages"][-1]["is_error"] is True


async def test_cloud_failure_falls_back_to_local(store):
    agent, local, cloud = make_agent(store, [reply("ตอบจากในเครื่อง")], [reply(error="HTTP 500 boom")],
                                     cloud_ready=True)
    evs = await events(agent, "ถามหน่อย")
    assert any(e["type"] == "fallback" and e["from"] == "cloud" and e["to"] == "local" for e in evs)
    assert evs[-1]["text"] == "ตอบจากในเครื่อง" and evs[-1]["model"] == "local"


async def test_sticky_cloud_error_is_skipped_next_time(store):
    agent, local, cloud = make_agent(store, [reply("1"), reply("2")], [reply(error="HTTP 401 API key ไม่ถูกต้อง")],
                                     cloud_ready=True)
    await events(agent, "หนึ่ง")
    await events(agent, "สอง")
    assert len(cloud.calls) == 1 and len(local.calls) == 2


async def test_history_is_sent_on_next_turn(store):
    agent, local, _ = make_agent(store, [reply("ครับ"), reply("ชื่อต้นครับ")])
    first = await events(agent, "ผมชื่อต้น")
    await events(agent, "ผมชื่ออะไร", session_id=first[0]["session_id"])
    msgs = local.calls[1]["messages"]
    assert msgs[0]["role"] == "system"
    assert [m.get("text") for m in msgs if m["role"] == "user"] == ["ผมชื่อต้น", "ผมชื่ออะไร"]


async def test_step_limit_forces_summary(store, monkeypatch):
    monkeypatch.setattr(settings, "max_steps", 2)
    loop_call = reply(calls=[("current_datetime", {})])
    agent, local, _ = make_agent(store, [loop_call, reply(calls=[("current_datetime", {})]),
                                         reply("สรุปครับ", calls=[("current_datetime", {})])])
    evs = await events(agent, "วนไปเรื่อยๆ")
    assert evs[-1]["text"] == "สรุปครับ"
    assert "ครบจำนวนรอบ" in local.calls[2]["messages"][-1]["content"]
    saved = store.messages(evs[0]["session_id"])
    assert "tool_calls" not in saved[-1]   # tool call ที่ไม่ได้รันไม่ถูกเก็บ


async def test_actions_can_be_disabled(store, monkeypatch):
    monkeypatch.setattr(settings, "allow_actions", False)
    agent, local, _ = make_agent(store, [reply(calls=[("open_app", {"name": "Safari"})]), reply("ปิดอยู่ครับ")])
    evs = await events(agent, "เปิด Safari")
    assert "open_app" not in local.calls[0]["tools"]
    result = next(e for e in evs if e["type"] == "tool_result")
    assert not result["ok"] and "ALLOW_ACTIONS" in result["preview"]


async def test_checklist_revises_failed_answer(store, monkeypatch):
    monkeypatch.setattr(settings, "checklist_enabled", True)
    agent, local, _ = make_agent(store, [
        reply('{"checks": ["มีชื่อ 3 ชื่อพอดี"]}'),
        reply("Tom, Max"),
        reply('{"results": [{"work": "นับได้ 2", "ok": false, "problem": "มีแค่ 2 ชื่อ"}]}'),
        reply("Tom, Max, Leo"),
    ])
    evs = await events(agent, "ขอชื่อแมว 3 ชื่อ เป็นภาษาอังกฤษ")
    assert any(e["type"] == "revision" for e in evs)
    assert evs[-1]["text"] == "Tom, Max, Leo"
    saved = store.messages(evs[0]["session_id"])
    assert saved[-1] == {"role": "assistant", "content": "Tom, Max, Leo"}
    assert "มีชื่อ 3 ชื่อพอดี" in local.calls[1]["messages"][-1]["content"]


async def test_reminder_tool_and_scheduler(store):
    from april.scheduler import Scheduler

    soon = (datetime.now(tz()) + timedelta(minutes=5)).isoformat(timespec="minutes")
    agent, _, _ = make_agent(store, [reply(calls=[("set_reminder", {"text": "โทรหาแม่", "at": soon})]),
                                     reply("ตั้งแล้วครับ")])
    await events(agent, "อีก 5 นาทีเตือนโทรหาแม่")
    assert store.reminders()[0]["text"] == "โทรหาแม่"
    await Scheduler(agent).tick(datetime.now(tz()) + timedelta(minutes=6))
    assert store.reminders() == []
    assert store.announcements()[0]["text"] == "โทรหาแม่"


async def test_voice_mode_asks_for_spoken_answer(store):
    agent, local, _ = make_agent(store, [reply("แปดโมงครับ")])
    await events(agent, "กี่โมงแล้ว", voice=True)
    assert "คุยด้วยเสียง" in local.calls[0]["messages"][-1]["content"]
