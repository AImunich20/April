import asyncio
import time

from fastapi.testclient import TestClient

from april.agent.loop import Agent
from april.config import settings
from april.llm.anthropic_provider import to_anthropic
from april.llm.catalog import ModelEntry
from april.llm.ollama import to_ollama
from april.llm.openai_compat import to_openai
from april.llm.router import Router, adapt_images
from april.llm.types import image_media_type
from april.server import create_app
from april.tools.registry import ToolContext, registry
from april.vision import hub
from conftest import FakeProvider, catalog, reply

JPEG = "/9j/4AAQSkZJRgABAQ"
PNG = "iVBORw0KGgoAAAANSUhEUg"


def fresh_hub(store=None, script=()):
    hub.reset()
    local = FakeProvider(list(script))
    agent = Agent(store, Router(catalog(), providers={"fake_local": local, "fake_cloud": FakeProvider([])}))
    hub.attach(agent)
    return agent, local


def frame(**kw):
    return {"jpeg": JPEG, "width": 1024, "height": 576, "people": 1, "faces": 1, "animals": [], "objects": [],
            "scene": ["office"], "motion": 0.0, **kw}


# ---------------------------------------------------------------- providers / router
def test_media_type_from_base64_header():
    assert image_media_type(JPEG) == "image/jpeg"
    assert image_media_type(PNG) == "image/png"


def test_tool_images_reach_every_provider():
    msgs = [{"role": "user", "content": "เห็นอะไร"},
            {"role": "assistant", "content": "", "tool_calls": [{"id": "c1", "name": "look", "arguments": {}}]},
            {"role": "tool", "tool_call_id": "c1", "name": "look", "content": "ภาพ", "images": [PNG], "camera": True}]
    _, claude = to_anthropic(msgs, "m")
    result = claude[-1]["content"][0]
    assert result["type"] == "tool_result"
    assert result["content"][1]["source"]["media_type"] == "image/png"
    oa = to_openai(msgs)
    assert [m["role"] for m in oa] == ["user", "assistant", "tool", "user"]
    assert oa[-1]["content"][1]["image_url"]["url"].startswith("data:image/png;base64,")
    ol = to_ollama(msgs)
    assert [m["role"] for m in ol] == ["user", "assistant", "tool", "user"] and ol[-1]["images"] == [PNG]


def test_router_drops_images_for_blind_models_and_private_camera(monkeypatch):
    msgs = [{"role": "user", "content": "ดู", "images": [JPEG]},
            {"role": "tool", "content": "ภาพ", "images": [JPEG], "camera": True}]
    blind = ModelEntry(id="b", provider="x", model="m", vision=False)
    out = adapt_images(blind, msgs)
    assert not any("images" in m for m in out) and "มองภาพไม่ได้" in out[0]["content"]
    assert msgs[0]["images"] == [JPEG]               # ไม่แก้ของเดิม
    cloud = ModelEntry(id="c", provider="x", model="m")
    local = ModelEntry(id="l", provider="x", model="m", local=True)
    monkeypatch.setattr(settings, "vision_cloud", False)
    out = adapt_images(cloud, msgs)
    assert out[0]["images"] == [JPEG]                 # รูปที่ผู้ใช้ส่งเองยังไปได้
    assert "images" not in out[1] and "ไม่ได้ส่งออกนอกเครื่อง" in out[1]["content"]
    assert adapt_images(local, msgs)[1]["images"] == [JPEG]


# ---------------------------------------------------------------- look ผ่าน agent loop
async def test_look_sends_frame_to_model_but_not_to_history(store):
    agent, local = fresh_hub(store, [reply(calls=[("look", {})]), reply("เห็นบอสถือแก้วกาแฟครับ")])
    hub.update(frame(objects=[{"label": "cup", "confidence": 0.91}]))
    evs = [e async for e in agent.run("ผมถืออะไรอยู่")]
    result = next(e for e in evs if e["type"] == "tool_result")
    assert result["ok"] and result["images"] == 1 and "cup (91%)" in result["preview"]
    tool_msg = local.calls[1]["messages"][-1]
    assert tool_msg["images"] == [JPEG] and tool_msg["camera"] is True
    saved = store.messages(evs[0]["session_id"])
    assert all("images" not in m for m in saved)
    assert "ไม่ได้เก็บไว้" in next(m for m in saved if m["role"] == "tool")["content"]


async def test_look_without_camera_says_so(store, monkeypatch):
    fresh_hub(store)

    async def no_frame(timeout=8.0):
        hub.demand("look")
        return None
    monkeypatch.setattr(hub, "need_frame", no_frame)
    ok, out = await registry.call("look", {}, ToolContext(store=store))
    assert not ok and "กล้องไม่ส่งภาพ" in out
    assert hub.wanted() == "look"                     # ขอให้แอปเปิดกล้องแล้ว


async def test_need_frame_waits_for_app(store):
    fresh_hub(store)

    async def app_sends():
        await asyncio.sleep(1.0)
        hub.update(frame())
    asyncio.get_running_loop().create_task(app_sends())
    got = await hub.need_frame(timeout=3)
    assert got and got["jpeg"] == JPEG


async def test_demand_long_poll():
    hub.reset()
    assert (await hub.wait_demand(0))["want"] is False
    hub.add_watch("แมวขึ้นโต๊ะ")
    res = await hub.wait_demand(5)
    assert res == {"want": True, "reason": "watch", "seconds": 0.0}


# ---------------------------------------------------------------- เฝ้าดู
async def test_watch_hit_alerts_once(store):
    agent, local = fresh_hub(store, [reply("#1: YES - แมวสีส้มกำลังเดินบนโต๊ะ\n#2: NO")])
    hub.add_watch("แมวขึ้นโต๊ะ")
    hub.add_watch("มีคนเปิดประตู", repeat=True)
    hub.update(frame(motion=0.1))
    await asyncio.gather(*hub._tasks)
    assert [w.id for w in hub.watches] == [2]          # ครั้งเดียว -> เลิกเฝ้าแล้ว
    prompt = local.calls[0]["messages"][0]
    assert prompt["images"] == [JPEG] and "#1: แมวขึ้นโต๊ะ" in prompt["content"]
    assert local.calls[0]["entry"] == "local"         # งานเบื้องหลังใช้โมเดลในเครื่อง
    said = hub.update(frame())["say"]
    assert len(said) == 1 and "แมวสีส้ม" in said[0]
    assert store.announcements()[0]["kind"] == "vision"


async def test_watch_check_waits_for_motion_and_interval(store):
    fresh_hub(store, [reply("#1: NO"), reply("#1: NO")])
    hub.add_watch("คนยกมือ")
    hub.update(frame(motion=0.0))                     # รอบแรกตรวจทันที
    await asyncio.gather(*hub._tasks)
    hub.update(frame(motion=0.5))                     # ยังไม่ครบช่วงเวลา
    assert not hub._tasks
    hub._last_check = time.time() - settings.vision_watch_interval - 1
    hub.update(frame(motion=0.0))                     # ครบเวลา + มีการขยับ (0.5) สะสมตั้งแต่ตรวจล่าสุด -> ถาม
    await asyncio.gather(*hub._tasks)
    hub._last_check = time.time() - settings.vision_watch_interval - 1
    hub.update(frame(motion=0.0))                     # นิ่งจริง -> ไม่ถาม
    assert not hub._tasks


# ---------------------------------------------------------------- เหตุการณ์
async def test_motion_event_is_analyzed_and_announced(store):
    _, local = fresh_hub(store, [reply("มีแมวเดินผ่านหน้ากล้องครับ")])
    hub.update(frame(people=0, faces=0))
    await hub.event({"kind": "motion"})
    await asyncio.gather(*hub._tasks)
    assert hub.events[0]["note"] == "มีแมวเดินผ่านหน้ากล้องครับ"
    assert hub._reply()["say"] == ["มีแมวเดินผ่านหน้ากล้องครับ"]
    await hub.event({"kind": "motion"})               # ยังไม่พ้น cooldown -> ไม่ถามซ้ำ
    assert len(local.calls) == 1


async def test_boring_motion_is_not_announced(store):
    fresh_hub(store, [reply("NONE")])
    hub.update(frame(people=0))
    await hub.event({"kind": "motion"})
    await asyncio.gather(*hub._tasks)
    assert hub._reply()["say"] == [] and store.announcements() == []


async def test_welcome_back_after_long_absence(store):
    fresh_hub(store)
    store.announce("reminder", "เตือนความจำ", "โทรหาแม่")
    res = await hub.event({"kind": "person_arrived", "away_seconds": 3600})
    assert "ยินดีต้อนรับกลับ" in res["say"][0] and "โทรหาแม่" in res["say"][0]
    res = await hub.event({"kind": "person_arrived", "away_seconds": 30})
    assert res["say"] == []


# ---------------------------------------------------------------- API
def test_vision_api_roundtrip(store):
    registry.recent.clear()
    agent = Agent(store, Router(catalog(), providers={"fake_local": FakeProvider([]), "fake_cloud": FakeProvider([])}))
    hub.reset()
    with TestClient(create_app(agent=agent, run_scheduler=False)) as client:
        r = client.post("/api/vision/frame", json=frame(objects=[{"label": "laptop", "confidence": 0.8}])).json()
        assert r == {"say": [], "keep_on": False, "watching": 0}
        info = client.get("/api/vision").json()
        assert info["online"] and "laptop (80%)" in info["summary"] and "jpeg" not in info["state"]
        assert [m["id"] for m in info["models"]] == ["local"]
        client.post("/api/tools/watch_for/run", json={"arguments": {"target": "แมว"}})
        wid = client.get("/api/vision").json()["watches"][0]["id"]
        assert client.get("/api/vision/demand", params={"wait": 0}).json()["want"] is True
        assert client.delete(f"/api/vision/watches/{wid}").status_code == 200
        client.post("/api/vision/stopped")
        assert client.get("/api/vision").json()["online"] is False
