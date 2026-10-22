"""
april/memory/store.py
-----------------------
ที่เก็บถาวรของ April (SQLite ไฟล์เดียว: data/april.db)
  sessions / messages   บทสนทนา (ข้อความรูปแบบกลางของ llm/types.py เก็บเป็น JSON)
  notes                 ความจำระยะยาวเรื่องเจ้านาย (ความชอบ คนรอบตัว สิ่งที่สั่งไว้)
  reminders             ตัวเตือนที่ตั้งไว้ (scheduler.py ตรวจและแจ้งเมื่อถึงเวลา)
  announcements         ข้อความที่ April แจ้งเองโดยไม่มีคนถาม (เตือน, สรุปประจำวัน)

ค้นความจำด้วยคำที่ตรงกัน (LIKE) แทน FTS5 — FTS5 ตัดคำไทยไม่ได้ (ไทยไม่มีช่องว่างระหว่างคำ)
"""

import json
import sqlite3
import threading
import time
import uuid
from pathlib import Path

_SCHEMA = """
CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, title TEXT, created REAL, updated REAL);
CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY, session_id TEXT, data TEXT, created REAL);
CREATE INDEX IF NOT EXISTS messages_session ON messages(session_id, id);
CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, text TEXT, created REAL);
CREATE TABLE IF NOT EXISTS reminders (id INTEGER PRIMARY KEY, text TEXT, due_at REAL, created REAL,
                                      done INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS announcements (id INTEGER PRIMARY KEY, kind TEXT, title TEXT, text TEXT, created REAL,
                                          read INTEGER DEFAULT 0);
"""


class Store:
    def __init__(self, path: Path | str):
        if str(path) != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(str(path), check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        self._lock = threading.Lock()
        with self._lock:
            self._db.executescript(_SCHEMA)

    def _q(self, sql: str, args: tuple = ()) -> list[sqlite3.Row]:
        with self._lock:
            cur = self._db.execute(sql, args)
            rows = cur.fetchall()
            self._db.commit()
            return rows

    def _insert(self, sql: str, args: tuple) -> int:
        with self._lock:
            cur = self._db.execute(sql, args)
            self._db.commit()
            return cur.lastrowid

    # ------------------------------------------------------------------ sessions
    def ensure_session(self, session_id: str | None, title: str = "") -> str:
        if session_id and self._q("SELECT 1 FROM sessions WHERE id = ?", (session_id,)):
            return session_id
        sid = session_id or uuid.uuid4().hex[:12]
        now = time.time()
        self._q("INSERT INTO sessions VALUES (?, ?, ?, ?)", (sid, title[:80], now, now))
        return sid

    def sessions(self, limit: int = 50) -> list[dict]:
        rows = self._q("SELECT * FROM sessions ORDER BY updated DESC LIMIT ?", (limit,))
        return [dict(r) for r in rows]

    def delete_session(self, session_id: str) -> None:
        self._q("DELETE FROM messages WHERE session_id = ?", (session_id,))
        self._q("DELETE FROM sessions WHERE id = ?", (session_id,))

    def add_messages(self, session_id: str, messages: list[dict]) -> None:
        now = time.time()
        with self._lock:
            self._db.executemany("INSERT INTO messages (session_id, data, created) VALUES (?, ?, ?)",
                                 [(session_id, json.dumps(m, ensure_ascii=False), now) for m in messages])
            self._db.execute("UPDATE sessions SET updated = ? WHERE id = ?", (now, session_id))
            self._db.commit()

    def messages(self, session_id: str, limit: int | None = None) -> list[dict]:
        if limit:
            rows = self._q("SELECT data FROM (SELECT id, data FROM messages WHERE session_id = ? ORDER BY id DESC "
                           "LIMIT ?) ORDER BY id", (session_id, limit))
        else:
            rows = self._q("SELECT data FROM messages WHERE session_id = ? ORDER BY id", (session_id,))
        return [json.loads(r["data"]) for r in rows]

    def history(self, session_id: str, limit: int) -> list[dict]:
        """ข้อความล่าสุดสำหรับส่งให้โมเดล — เริ่มที่ข้อความ user เสมอ (ไม่ตัดกลางคู่ เรียกเครื่องมือ/ผลเครื่องมือ)"""
        msgs = self.messages(session_id, limit)
        start = next((i for i, m in enumerate(msgs) if m.get("role") == "user"), len(msgs))
        return msgs[start:]

    # ------------------------------------------------------------------ notes
    def add_note(self, text: str) -> int:
        return self._insert("INSERT INTO notes (text, created) VALUES (?, ?)", (text.strip(), time.time()))

    def notes(self, limit: int = 50) -> list[dict]:
        return [dict(r) for r in self._q("SELECT * FROM notes ORDER BY id DESC LIMIT ?", (limit,))]

    def search_notes(self, query: str, limit: int = 8) -> list[dict]:
        terms = [t for t in query.lower().split() if len(t) >= 2] or [query.lower().strip()]
        scored = []
        for note in self.notes(500):
            text = note["text"].lower()
            score = sum(t in text for t in terms)
            if score:
                scored.append((score, note["id"], note))
        return [n for _, _, n in sorted(scored, key=lambda x: (-x[0], -x[1]))[:limit]]

    def delete_note(self, note_id: int) -> bool:
        found = bool(self._q("SELECT 1 FROM notes WHERE id = ?", (note_id,)))
        self._q("DELETE FROM notes WHERE id = ?", (note_id,))
        return found

    # ------------------------------------------------------------------ reminders
    def add_reminder(self, text: str, due_at: float) -> int:
        return self._insert("INSERT INTO reminders (text, due_at, created) VALUES (?, ?, ?)",
                            (text.strip(), due_at, time.time()))

    def reminders(self, include_done: bool = False) -> list[dict]:
        sql = "SELECT * FROM reminders" + ("" if include_done else " WHERE done = 0") + " ORDER BY due_at"
        return [dict(r) for r in self._q(sql)]

    def due_reminders(self, now: float | None = None) -> list[dict]:
        return [dict(r) for r in self._q("SELECT * FROM reminders WHERE done = 0 AND due_at <= ? ORDER BY due_at",
                                         (now or time.time(),))]

    def finish_reminder(self, reminder_id: int) -> bool:
        found = bool(self._q("SELECT 1 FROM reminders WHERE id = ? AND done = 0", (reminder_id,)))
        self._q("UPDATE reminders SET done = 1 WHERE id = ?", (reminder_id,))
        return found

    # ------------------------------------------------------------------ announcements
    def announce(self, kind: str, title: str, text: str) -> int:
        return self._insert("INSERT INTO announcements (kind, title, text, created) VALUES (?, ?, ?, ?)",
                            (kind, title, text, time.time()))

    def announcements(self, unread_only: bool = False, limit: int = 50) -> list[dict]:
        sql = "SELECT * FROM announcements" + (" WHERE read = 0" if unread_only else "") + " ORDER BY id DESC LIMIT ?"
        return [dict(r) for r in self._q(sql, (limit,))]

    def mark_read(self, ids: list[int] | None = None) -> None:
        if ids is None:
            self._q("UPDATE announcements SET read = 1")
        else:
            self._q(f"UPDATE announcements SET read = 1 WHERE id IN ({','.join('?' * len(ids))})", tuple(ids))
