from __future__ import annotations

import json
import sys
import time


for raw_bytes in sys.stdin.buffer:
    if raw_bytes.startswith((b"\xff\xfe", b"\xfe\xff")):
        raw_line = raw_bytes.decode("utf-16")
    else:
        raw_line = raw_bytes.decode("utf-8-sig")
    request = json.loads(raw_line)
    command = request.get("cmd")
    if command == "delay":
        time.sleep(float(request.get("seconds", 0)))
    if command == "error":
        print(
            json.dumps(
                {
                    "id": request.get("id"),
                    "ok": False,
                    "error": "expected helper failure",
                    "traceback": "expected traceback",
                    "logs": ["expected diagnostic log"],
                },
                separators=(",", ":"),
            ),
            flush=True,
        )
        continue
    response = {
        "id": request.get("id"),
        "ok": True,
        "result": {"command": command, "value": request.get("value")},
        "logs": [],
    }
    print(json.dumps(response, separators=(",", ":")), flush=True)
    if command == "exit":
        break
