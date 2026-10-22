import asyncio

from fastapi.testclient import TestClient

from april.agent.loop import Agent
from april.llm.router import Router
from april.server import create_app
from april.tools.registry import registry
from conftest import FakeProvider, catalog, reply


def make_client(store, script):
    registry.recent.clear()     # ทะเบียนเครื่องมือเป็นตัวกลางของทั้งโปรแกรม — ล้างประวัติจากเทสก่อนหน้า
    local = FakeProvider(script)
    agent = Agent(store, Router(catalog(), providers={"fake_local": local, "fake_cloud": FakeProvider([])}))
    return TestClient(create_app(agent=agent, run_scheduler=False)), agent


def test_runs_are_recorded_with_tools_and_model(store):
    client, _ = make_client(store, [reply(calls=[("calculate", {"expression": "2*21"})]), reply("42 ครับ")])
    with client:
        done = client.post("/chat/sync", json={"message": "2 คูณ 21"}).json()
        assert done["text"] == "42 ครับ"
        run = client.get("/api/runs").json()["runs"][0]
        assert run["status"] == "done" and run["model"] == "local" and run["tools"] == ["calculate"]
        assert run["answer"] == "42 ครับ" and run["duration_seconds"] is not None
        ov = client.get("/api/overview").json()
        assert ov["runs_24h"]["done"]["count"] == 1 and ov["llm_calls"] == 2 and ov["tool_calls"] == 1
        types = [e["type"] for e in client.get("/api/events").json()["events"]]
        assert {"request_start", "tool_call", "llm_call", "request_done"} <= set(types)


def test_failed_run_is_marked_failed(store):
    client, _ = make_client(store, [reply(error="HTTP 500 boom")])
    with client:
        client.post("/chat/sync", json={"message": "ถามหน่อย"})
        run = client.get("/api/runs").json()["runs"][0]
        assert run["status"] == "failed" and "boom" in run["error"]


def test_cancel_running_request(store):
    class Slow(FakeProvider):
        async def generate(self, entry, messages, tools, on_event=None):
            await asyncio.sleep(30)

    agent = Agent(store, Router(catalog(), providers={"fake_local": Slow([]), "fake_cloud": Slow([])}))

    async def scenario():
        events = []
        gen = agent.run("งานช้า")
        events.append(await gen.__anext__())                  # session
        run_id = events[0]["run_id"]
        await asyncio.sleep(0.05)
        assert agent.cancel(run_id)
        async for ev in gen:
            events.append(ev)
        return run_id, events

    run_id, events = asyncio.run(scenario())
    assert events[-1]["type"] == "done"
    assert any(e["type"] == "error" and e["message"] == "หยุดแล้ว" for e in events)
    assert store.runs()[0]["status"] == "cancelled"
    assert not agent.cancel(run_id)


def test_tools_reminders_notes_persona(store):
    client, _ = make_client(store, [])
    with client:
        tools = client.get("/api/tools").json()
        names = {t["name"] for t in tools["tools"]}
        assert {"calculate", "set_reminder", "open_app"} <= names
        r = client.post("/api/tools/calculate/run", json={"arguments": {"expression": "6*7"}}).json()
        assert r["ok"] and "42" in r["result"]
        assert client.get("/api/tools").json()["recent_calls"][0]["name"] == "calculate"

        client.post("/api/tools/set_reminder/run", json={"arguments": {"text": "ดื่มน้ำ", "in_minutes": 30}})
        pending = client.get("/api/reminders").json()["reminders"]
        assert pending[0]["text"] == "ดื่มน้ำ"
        assert client.delete(f"/api/reminders/{pending[0]['id']}").status_code == 200
        assert client.get("/api/reminders").json()["reminders"] == []
        assert client.get("/api/reminders?status=sent").json()["reminders"][0]["text"] == "ดื่มน้ำ"

        client.post("/api/notes", json={"text": "บอสแพ้กุ้ง"})
        assert "บอสแพ้กุ้ง" in client.get("/api/persona").json()["system_prompt"]
        cfg = client.get("/api/config").json()
        assert cfg["keys"]["ANTHROPIC_API_KEY"] == "" and cfg["local_model"] == "tiny"
