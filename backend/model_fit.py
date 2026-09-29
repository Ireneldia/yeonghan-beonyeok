"""Jan의 공개 Apple Silicon 계산식으로 메모리 적합도를 추정한다.

계산식·임계값 출처: Jan (Copyright 2025 Menlo Research, Apache-2.0).
https://github.com/janhq/jan/blob/616ca7210d1350d68a56536d57fd0f23691684a7/web-app/src/lib/modelCompatibility.ts
공개 계산식을 독립 구현하며, 같은 모델·컨텍스트의 Ollama 보고값이 있으면 보정한다.
"""
import json
import math
import platform
import re
import subprocess
from functools import lru_cache

GIB = 1024 ** 3
CONTEXT_LENGTH = 8192
SOURCE = "https://github.com/janhq/jan/blob/616ca7210d1350d68a56536d57fd0f23691684a7/web-app/src/lib/modelCompatibility.ts"


def size_bytes(value):
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return int(value) if math.isfinite(value) and value > 0 else None
    if not isinstance(value, str):
        return None
    match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*(B|[KMGT]i?B)?\s*", value, re.I)
    if not match:
        return None
    unit = (match[2] or "B").upper()
    exponent = {"B": 0, "K": 1, "M": 2, "G": 3, "T": 4}[unit[0]]
    return size_bytes(float(match[1]) * (1024 if "I" in unit else 1000) ** exponent)


@lru_cache(maxsize=1)
def hardware() -> dict:
    result = {"name": platform.machine(), "total_bytes": None, "budget_bytes": None,
              "reserve_bytes": None, "unified": False, "metal_recommended_bytes": None,
              "context_length": CONTEXT_LENGTH, "source_url": SOURCE}
    if platform.system() != "Darwin":
        return result
    try:
        total = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], timeout=3, text=True).strip())
        name = subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], timeout=3, text=True).strip()
        result.update(name=name, total_bytes=total, unified=platform.machine() in ("arm64", "aarch64"))
    except (OSError, ValueError, subprocess.TimeoutExpired, subprocess.CalledProcessError):
        return result
    if result["unified"]:
        reserve = int(2.5 * GIB + total * 0.1)
        result.update(reserve_bytes=reserve, budget_bytes=max(0, total - reserve))
        # macOS 기본 JXA의 Metal 브리지. 별도 패키지나 컴파일러를 설치하지 않는다.
        script = ('ObjC.import("Metal"); var d=$.MTLCreateSystemDefaultDevice(); '
                  'JSON.stringify({budget:Number(d.recommendedMaxWorkingSetSize)})')
        try:
            output = subprocess.check_output(["/usr/bin/osascript", "-l", "JavaScript", "-e", script],
                                             timeout=3, text=True, stderr=subprocess.DEVNULL)
            result["metal_recommended_bytes"] = size_bytes(json.loads(output).get("budget"))
        except (OSError, ValueError, subprocess.TimeoutExpired, subprocess.CalledProcessError):
            pass
    return result


def assess(weights, machine: dict, *, digest: str = "", running=(),
           context_length: int = CONTEXT_LENGTH) -> dict:
    weights = size_bytes(weights)
    budget = machine.get("budget_bytes")
    context_length = context_length if context_length > 0 else CONTEXT_LENGTH
    result = {"level": "unknown", "label": "정보 부족", "required_bytes": None,
              "budget_bytes": budget, "basis": "estimate", "context_length": context_length,
              "note": "모델 크기 또는 Apple Silicon 메모리 정보를 확인할 수 없습니다"}
    if not weights or budget is None or not machine.get("unified"):
        return result
    # Jan: 가중치 + 컨텍스트 4096토큰당 가중치의 10%를 KV 여유로 잡는 휴리스틱.
    required = weights + (weights * context_length + 40959) // 40960
    note = "Jan 기준 추정 · 파일 크기와 문맥 길이 반영"
    loaded = next((m for m in running if digest and m.get("digest") == digest
                   and m.get("context_length") == context_length and size_bytes(m.get("size"))), None)
    if loaded:
        # size_vram은 size의 일부다. 통합 메모리이므로 두 수치를 더하지 않는다.
        required = int(loaded["size"])
        result["basis"] = "loaded"
        note = "Ollama 보고 할당량 · 같은 모델과 문맥 길이 확인"
    level = "red" if required > budget else "green" if required <= budget * 0.85 else "yellow"
    if loaded and loaded.get("size_vram", 0) < required and level == "green":
        level = "yellow"
        note += " · GPU 일부 적재 또는 CPU 사용"
    metal = machine.get("metal_recommended_bytes")
    if metal and required > metal:
        note += " · Metal 권장 작업량 초과 예상"
    result.update(level=level, label={"green": "쾌적 예상", "yellow": "여유 적음", "red": "메모리 부족 예상"}[level],
                  required_bytes=required, note=note)
    return result


def annotate(rows: list[dict], machine: dict, installed=(), running=(), families=False) -> list[dict]:
    by_name = {m["name"]: m for m in installed}
    output = []
    for row in rows:
        local = by_name.get(row["id"]) or by_name.get(row["id"] + ":latest", {})
        fit = assess(None if families else local.get("size", row.get("size")), machine,
                     digest=local.get("digest", ""), running=running)
        if families:
            fit.update(label="버전별 확인", note="모델 크기·양자화 버전을 선택하면 메모리 적합도를 표시합니다")
        output.append({**row, "fit": fit})
    return output
