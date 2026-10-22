"""
april/config.py
-----------------
ค่าตั้งทั้งหมดของ April — อ่านจาก env (ขึ้นต้น APRIL_) และไฟล์ .env ที่รากโปรเจกต์
API key ของผู้ให้บริการใช้ชื่อมาตรฐานของแต่ละเจ้า (ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, OLLAMA_API_KEY)
"""

from pathlib import Path

from pydantic import AliasChoices, Field
from pydantic_settings import BaseSettings, SettingsConfigDict

ROOT = Path(__file__).resolve().parent.parent


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="APRIL_", env_file=ROOT / ".env", extra="ignore")

    # ตัวตน
    name: str = "April"
    owner_name: str = ""                  # ชื่อเจ้านาย (ว่าง = เรียกว่า "บอส")
    timezone: str = "Asia/Bangkok"
    language: str = "ไทย"
    particle: str = "ครับ"                # คำลงท้าย (ครับ / ค่ะ)

    # ที่เก็บข้อมูล / เซิร์ฟเวอร์
    data_dir: Path = ROOT / "data"
    host: str = "127.0.0.1"
    port: int = 8100                      # Envy ใช้ 8000 — รันคู่กันได้
    api_token: str = ""                   # ตั้งไว้ = ทุกคำขอต้องมี Authorization: Bearer <token>

    # โมเดล
    models_file: Path = Path(__file__).resolve().parent / "models.yaml"
    default_model: str = "auto"           # auto = cloud ตัวแรกที่พร้อม แล้วสำรองไปโมเดลในเครื่อง
    ollama_url: str = "http://127.0.0.1:11434"

    # agent loop
    max_steps: int = 8                    # จำนวนรอบเรียกเครื่องมือสูงสุดต่อคำขอ
    history_messages: int = 30            # ข้อความล่าสุดของ session ที่ส่งให้โมเดล
    tool_timeout_seconds: float = 30.0
    checklist_enabled: bool = False       # คิดก่อนตอบ ตรวจก่อนส่ง (agent/checklist.py)
    allow_actions: bool = True            # False = ปิดเครื่องมือที่ทำงานกับเครื่อง (เปิดแอป/เว็บ/แจ้งเตือน)

    # งานเชิงรุก
    briefing_time: str = ""               # "07:30" = สรุปประจำวันทุกเช้า (ว่าง = ปิด)
    notify_mac: bool = True               # แจ้งเตือนขึ้นจอ macOS

    # API key (ชื่อมาตรฐาน ไม่มี prefix)
    anthropic_api_key: str = Field("", validation_alias=AliasChoices("ANTHROPIC_API_KEY", "APRIL_ANTHROPIC_API_KEY"))
    openai_api_key: str = Field("", validation_alias=AliasChoices("OPENAI_API_KEY", "APRIL_OPENAI_API_KEY"))
    gemini_api_key: str = Field("", validation_alias=AliasChoices("GEMINI_API_KEY", "APRIL_GEMINI_API_KEY"))
    ollama_api_key: str = Field("", validation_alias=AliasChoices("OLLAMA_API_KEY", "APRIL_OLLAMA_API_KEY"))

    @property
    def db_path(self) -> Path:
        return self.data_dir / "april.db"

    def key(self, env_name: str) -> str:
        """API key ตามชื่อ env ที่ models.yaml อ้างถึง"""
        return {"ANTHROPIC_API_KEY": self.anthropic_api_key, "OPENAI_API_KEY": self.openai_api_key,
                "GEMINI_API_KEY": self.gemini_api_key, "OLLAMA_API_KEY": self.ollama_api_key}.get(env_name, "")


settings = Settings()
