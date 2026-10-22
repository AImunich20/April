# April

**พ่อบ้าน AI ส่วนตัวแบบ JARVIS / FRIDAY** สุภาพ รู้ใจ ทำงานให้เสร็จด้วยเครื่องมือแทนการถามกลับ และคอยเตือนหรือสรุปงานให้เองโดยไม่ต้องรอให้ถาม

- **โมเดลในเครื่อง 1 ตัว** (Ollama · ค่าเริ่มต้น `qwen3.5:4b`) ใช้ได้เสมอแม้ไม่มีเน็ต และเป็นตัวสำรองสุดท้าย
- **โมเดล cloud หลายตัว**: Claude Opus / Sonnet / Haiku, gpt-oss (Ollama Cloud), ChatGPT, Gemini
  ถ้า cloud ล่ม ไม่มีคีย์ หรือเกินโควตา จะสลับไปตัวถัดไปเองในคำขอเดียวกัน
- **ไม่มีระบบปลั๊กอิน** เครื่องมือทั้งหมดอยู่ในแกนของ April

พัฒนาต่อจาก [Envy](../Agent) แต่เขียนแกนใหม่: Envy แตกงานเป็น DAG ของ agent หลายตัว
(planner → decomposer → dispatcher → writer) ส่วน April ใช้ **agent loop วงเดียว** ที่ให้โมเดลวางแผนและเรียกเครื่องมือเอง
(native tool calling ทุก provider) ทำให้โค้ดเล็กกว่ามากและต่อยอดง่าย

## เริ่มใช้

```bash
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -e ".[dev]"
cp .env.example .env          # ใส่ชื่อ, คีย์ cloud (ไม่ใส่ = ใช้โมเดลในเครื่องอย่างเดียว)
ollama pull qwen3.5:4b

.venv/bin/python -m april chat        # คุยในเทอร์มินัล
.venv/bin/python -m april serve       # HTTP API ที่ http://127.0.0.1:8100
.venv/bin/python -m april models      # ดูว่าโมเดลไหนพร้อมใช้
```

## แอป Mac

ดาวน์โหลด `April-<รุ่น>.dmg` จาก [Releases](https://github.com/AImunich20/April/releases) แล้วลากไปไว้ที่ Applications
เปิดครั้งแรก แอปจะติดตั้งทุกอย่างเอง (Python, package, Ollama และโมเดลในเครื่อง) ลงใน `~/Library/Application Support/April`
โดยไม่ต้องใช้ Homebrew หรือรหัสผ่านเครื่อง

- **หน้าแชท**: เลือกโมเดลได้, เห็นว่า April ใช้เครื่องมืออะไร, ประกาศจาก April (ตัวเตือน/สรุปประจำวัน) ขึ้นแถบด้านบน
- **คุยด้วยเสียง** (⇧⌘A): หน้าต่าง HUD แบบ JARVIS พอร์ตจาก Envy — พูดจบแล้วเงียบ = ส่ง, April อ่านคำตอบออกเสียงไทย,
  คุยต่อเนื่องได้, คำบรรยายสด, พูดแทรกได้
- **เรียกด้วยเสียง "April"** (เปิดในตั้งค่าเสียง): ฟังตลอดเวลาแบบถอดเสียง **บนเครื่องเท่านั้น** ได้ยินคำว่า "April / เอพริล"
  แล้วเปิดหน้าคุยด้วยเสียงและเริ่มฟังคำสั่งทันที — เครื่องที่ถอดเสียงไทยบนเครื่องไม่ได้จะไม่เปิดให้ใช้ (ไม่ส่งเสียงในห้องออกนอกเครื่อง)
- **ไอคอนบน menu bar**: ปิดหน้าต่างแล้ว April ยังอยู่ · ⌘Q ปิดแอปแต่ April ทำงานต่อเบื้องหลัง · ⌥⌘Q หยุดทั้งหมด
- **ตั้งค่า** (⌘,): ชื่อเจ้านาย, คีย์ cloud, เวลาสรุปประจำวัน, ดู/ลบความจำ
- **อัปเดตเอง** จาก GitHub Releases

```bash
./Apple/build.sh            # build -> Apple/build/April.app
./Apple/build.sh --dmg      # + Apple/dist/April-<รุ่น>.dmg / .zip
./Apple/release.sh patch    # ออกรุ่นใหม่ขึ้น GitHub Releases (แอปที่ติดตั้งแล้วจะเห็นอัปเดต)
```

## April ทำอะไรได้

| หมวด | เครื่องมือ |
|---|---|
| ข้อมูล | `current_datetime` · `calculate` (คิดเลขแม่นยำ) · `web_search` · `read_webpage` |
| ความจำ | `remember` · `recall` · `forget` ความจำเรื่องเจ้านายถูกใส่ใน system prompt ทุกบทสนทนา |
| ตัวเตือน | `set_reminder` · `list_reminders` · `cancel_reminder` |
| เครื่อง Mac | `system_status` (แบต CPU RAM ดิสก์) · `open_app` · `open_url` · `notify` |

**งานเชิงรุก** (`april/scheduler.py`): ตัวเตือนที่ถึงเวลาจะแจ้งขึ้นจอ Mac และเก็บไว้ใน `/announcements`
ตั้ง `APRIL_BRIEFING_TIME=07:30` แล้ว April จะสรุปประจำวันให้ทุกเช้า

**คิดก่อนตอบ ตรวจก่อนส่ง** (`APRIL_CHECKLIST_ENABLED=true`): ย่อมาจาก Envy 2.3.1 แตกคำขอที่มีเงื่อนไขเป็นเช็กลิสต์
ตรวจคำตอบทีละข้อ แล้วแก้ 1 ครั้งถ้าไม่ผ่าน

## โครงสร้าง

```
april/
├── agent/
│   ├── loop.py          agent loop: โมเดล → เครื่องมือ (ขนาน) → โมเดล … → คำตอบ (stream เป็น event)
│   ├── prompts.py       บุคลิกพ่อบ้าน (system prompt คงที่ เพื่อให้ prompt cache ทำงาน)
│   └── checklist.py     คิดก่อนตอบ ตรวจก่อนส่ง
├── llm/
│   ├── catalog.py       อ่าน models.yaml (local 1 + cloud หลายตัว)
│   ├── router.py        เลือกโมเดล + สำรองอัตโนมัติ + พักตัวที่คีย์ผิด/เกินโควตา
│   ├── ollama.py        Ollama ในเครื่อง + Ollama Cloud
│   ├── anthropic_provider.py   Claude (SDK ทางการ, adaptive thinking, server-side fallback)
│   └── openai_compat.py ChatGPT / Gemini / เจ้าอื่นที่ใช้ API แบบ OpenAI
├── tools/               ทะเบียนเครื่องมือ + เครื่องมือในตัว
├── memory/store.py      SQLite: แชท ความจำ ตัวเตือน ประกาศ
├── scheduler.py         งานเชิงรุก
├── server.py            FastAPI (SSE)
├── cli.py               python -m april …
└── models.yaml          แค็ตตาล็อกโมเดล
```

## HTTP API

| | |
|---|---|
| `POST /chat` | `{message, session_id?, model?, images?}` → SSE: `session` `model` `thinking` `token` `tool_call` `tool_result` `fallback` `revision` `error` `done` |
| `POST /chat/sync` | เหมือนกันแต่คืน JSON ตอนจบ |
| `GET /models` · `GET /health` | สถานะโมเดล / Ollama |
| `GET /sessions` · `GET/DELETE /sessions/{id}` | ประวัติแชท |
| `GET /notes` · `DELETE /notes/{id}` | ความจำ |
| `GET /reminders` · `GET /announcements?unread=true` · `POST /briefing` | งานเชิงรุก |

เปิดให้เครื่องอื่นเข้าได้ (`APRIL_HOST=0.0.0.0`) ต้องตั้ง `APRIL_API_TOKEN` ด้วย

## ความปลอดภัย

- ไม่มีเครื่องมือรันคำสั่ง shell — ทุกอย่างที่ทำกับเครื่องผ่านคำสั่งที่กำหนดไว้แล้ว (`open -a`, `open <url>`, `osascript` แบบส่ง argv)
- `read_webpage` ไม่เปิดที่อยู่ในเครื่องหรือวง LAN (กัน SSRF) และตรวจปลายทางทุกครั้งที่ redirect
- `calculate` ประเมินผลเองจาก AST ไม่ใช้ `eval` และกันตัวเลขยกกำลังหรือ factorial ที่ใหญ่จนเครื่องค้าง
- ปิดเครื่องมือที่สั่งงานเครื่องทั้งหมดได้ด้วย `APRIL_ALLOW_ACTIONS=false`
- argument ทุกตัวจากโมเดลถูกตรวจกับ schema ก่อนรันเสมอ

## ทดสอบ

```bash
.venv/bin/python -m pytest -q        # ใช้โมเดลจำลอง ไม่ต้องมี Ollama หรือคีย์
```

## แผนต่อไป

- ต่อกับปฏิทินและอีเมล เพื่อให้สรุปประจำวันครบขึ้น
- สั่งงานบ้านอัจฉริยะ (HomeKit / Home Assistant)
