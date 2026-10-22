"""
april/observability.py
------------------------
log แบบ JSON บรรทัดละเหตุการณ์ -> data/logs/april.jsonl (อ่านย้อนหลังด้วย jq ได้)
"""

import json
import sys
import time

from april.config import settings


def log(event: str, **fields) -> None:
    line = json.dumps({"t": round(time.time(), 3), "event": event, **fields}, ensure_ascii=False, default=str)
    try:
        path = settings.data_dir / "logs" / "april.jsonl"
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        print(line, file=sys.stderr)
