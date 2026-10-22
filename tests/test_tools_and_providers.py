from datetime import datetime

import pytest

from april.llm.anthropic_provider import to_anthropic
from april.llm.catalog import load_catalog
from april.llm.ollama import to_ollama
from april.llm.openai_compat import to_openai
from april.tools.builtin import parse_when, safe_eval, tz, _public_host
from april.tools.registry import ToolContext, registry

CONVO = [
    {"role": "system", "content": "sys"},
    {"role": "user", "content": "q"},
    {"role": "assistant", "content": "", "tool_calls": [{"id": "a1", "name": "calculate", "arguments": {"expression": "1+1"}},
                                                         {"id": "a2", "name": "current_datetime", "arguments": {}}]},
    {"role": "tool", "tool_call_id": "a1", "name": "calculate", "content": "2"},
    {"role": "tool", "tool_call_id": "a2", "name": "current_datetime", "content": "now", "is_error": True},
    {"role": "assistant", "content": "ok"},
]


def test_anthropic_conversion_groups_tool_results():
    system, msgs = to_anthropic(CONVO, "claude-opus-5-5")
    assert system == "sys"
    assert [m["role"] for m in msgs] == ["user", "assistant", "user", "assistant"]
    assert [b["type"] for b in msgs[1]["content"]] == ["tool_use", "tool_use"]
    results = msgs[2]["content"]
    assert [r["tool_use_id"] for r in results] == ["a1", "a2"] and results[1]["is_error"] is True


def test_anthropic_replays_native_content_only_for_same_model():
    native = [{"type": "thinking", "thinking": "t", "signature": "sig", "extra": 1}, {"type": "text", "text": "ok"}]
    convo = [{"role": "user", "content": "q"},
             {"role": "assistant", "content": "ok",
              "native": {"provider": "anthropic", "model": "claude-opus-5-5", "content": native}}]
    _, same = to_anthropic(convo, "claude-opus-5-5")
    assert same[1]["content"][0] == {"type": "thinking", "thinking": "t", "signature": "sig"}
    _, other = to_anthropic(convo, "claude-sonnet-5-5")
    assert other[1]["content"] == [{"type": "text", "text": "ok"}]


def test_openai_and_ollama_conversion():
    oa = to_openai(CONVO)
    assert oa[2]["tool_calls"][0]["function"]["arguments"] == '{"expression": "1+1"}'
    assert oa[3] == {"role": "tool", "tool_call_id": "a1", "content": "2"}
    ol = to_ollama(CONVO)
    assert ol[2]["tool_calls"][0]["function"]["arguments"] == {"expression": "1+1"}
    assert ol[3]["tool_name"] == "calculate"


def test_catalog_has_one_local_and_auto_falls_back_to_local():
    cat = load_catalog()
    assert cat.local.local and cat.local.provider == "ollama"
    assert len(cat.cloud) >= 3 and all(not m.local for m in cat.cloud)
    assert [m.id for m in cat.chain("auto")] == ["local"]          # ไม่มีคีย์ cloud
    with pytest.raises(KeyError):
        cat.chain("nope")


@pytest.mark.parametrize("expr,expected", [("1500*12", 18000), ("2^10", 1024), ("sqrt(16)+1", 5), ("1,000/4", 250)])
def test_calculate(expr, expected):
    assert safe_eval(expr) == expected


@pytest.mark.parametrize("expr", ["__import__('os')", "open('x')", "(1).__class__", "9**9**9", "[1,2]", "factorial(10**6)", "2**(10*1000)"])
def test_calculate_rejects_unsafe(expr):
    with pytest.raises((ValueError, SyntaxError)):
        safe_eval(expr)


async def test_registry_validates_and_coerces(store):
    ctx = ToolContext(store=store)
    ok, out = await registry.call("calculate", {"expression": 5}, ctx)
    assert not ok and "string" in out
    ok, out = await registry.call("forget", {"id": "3"}, ctx)          # "3" -> 3
    assert not ok and "ไม่พบ" in out
    ok, out = await registry.call("nope", {}, ctx)
    assert not ok
    ok, out = await registry.call("calculate", {"expression": "1+1", "junk": 1}, ctx)
    assert not ok and "junk" in out


def test_parse_when():
    now = datetime(2026, 10, 22, 9, 0, tzinfo=tz())
    assert parse_when("2026-10-22T18:30", None, now).hour == 18
    assert parse_when(None, 30, now).minute == 30
    with pytest.raises(ValueError):
        parse_when("2026-10-21T08:00", None, now)
    with pytest.raises(ValueError):
        parse_when(None, None, now)


@pytest.mark.parametrize("url", ["http://127.0.0.1:8100/", "http://192.168.1.1/", "file:///etc/passwd",
                                 "http://localhost/"])
def test_read_webpage_blocks_local_addresses(url):
    with pytest.raises(ValueError):
        _public_host(url)


async def test_open_url_rejects_non_http(store):
    ok, out = await registry.call("open_url", {"url": "file:///etc/passwd"}, ToolContext(store=store))
    assert not ok and out.startswith("ERROR")
