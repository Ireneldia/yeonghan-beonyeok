"""Claude Code 구독 로그인으로 모델 목록을 읽고 격리된 번역 요청을 실행한다."""
from __future__ import annotations

import asyncio
import json
import os
import re
import shutil
import subprocess
import tempfile

CLAUDE = shutil.which("claude") or os.path.expanduser("~/.local/bin/claude")
LOGIN_ERROR = "터미널에서 claude auth login으로 Claude 구독 계정에 로그인하세요"
REQUEST_ERROR = "Claude Code 요청 실패. 로그인·이용 한도·선택 모델을 확인하세요"


def _env() -> dict:
    excluded = {"OPENAI_API_KEY", "CODEX_API_KEY", "CLAUDECODE", "CLAUDE_CODE_OAUTH_TOKEN",
                "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"}
    return {key: value for key, value in os.environ.items()
            if not key.startswith("ANTHROPIC_") and key not in excluded}


def _flags() -> list[str]:
    return ["-p", "--safe-mode", "--no-session-persistence", "--tools", "",
            "--setting-sources", "", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
            "--disable-slash-commands"]


def auth_status() -> bool:
    try:
        with tempfile.TemporaryDirectory(prefix="yh-claude-auth-") as directory:
            result = subprocess.run([CLAUDE, "--safe-mode", "--setting-sources", "", "auth", "status", "--json"], capture_output=True,
                                    text=True, timeout=10, cwd=directory, env=_env())
        status = json.loads(result.stdout)
        # 저장된 Console API 키도 authMethod=claude.ai일 수 있어 apiKeySource까지 확인한다.
        return (result.returncode == 0 and isinstance(status, dict) and status.get("loggedIn") is True
                and status.get("authMethod") == "claude.ai" and status.get("apiProvider") == "firstParty"
                and not status.get("apiKeySource"))
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
        return False


async def _models(timeout: float = 20) -> list[dict]:
    with tempfile.TemporaryDirectory(prefix="yh-claude-models-") as directory:
        process = await asyncio.create_subprocess_exec(
            CLAUDE, *_flags(), "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            cwd=directory, env=_env(), stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL, limit=1024 * 1024)

        async def read():
            message = {"type": "control_request", "request_id": "catalog",
                       "request": {"subtype": "initialize", "hooks": {}}}
            process.stdin.write((json.dumps(message) + "\n").encode())
            await process.stdin.drain()
            while line := await process.stdout.readline():
                try:
                    message = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(message, dict) or message.get("type") != "control_response":
                    continue
                reply = message.get("response")
                if not isinstance(reply, dict):
                    raise RuntimeError("Claude Code 모델 목록 형식을 확인할 수 없습니다")
                if reply.get("request_id") != "catalog":
                    continue
                if reply.get("subtype") == "error":
                    raise RuntimeError("Claude Code 모델 목록을 가져오지 못했습니다")
                body = reply.get("response")
                rows = body.get("models") if isinstance(body, dict) else None
                if not isinstance(rows, list):
                    raise RuntimeError("Claude Code 모델 목록 형식을 확인할 수 없습니다")
                models = []
                for row in rows:
                    if not isinstance(row, dict) or not isinstance(row.get("value"), str) or not row["value"]:
                        continue
                    levels = row.get("supportedEffortLevels") or []
                    if not isinstance(levels, list):
                        raise RuntimeError("Claude Code 추론 강도 목록 형식을 확인할 수 없습니다")
                    models.append({"id": row["value"], "name": row.get("displayName") or row["value"],
                                   "efforts": [{"id": level, "name": level} for level in levels
                                               if isinstance(level, str) and level], "fast": False})
                return models
            raise RuntimeError("Claude Code 모델 목록 연결이 종료되었습니다")

        try:
            return await asyncio.wait_for(read(), timeout=timeout)
        finally:
            if process.returncode is None:
                try:
                    process.terminate()
                except ProcessLookupError:
                    pass
                try:
                    await asyncio.wait_for(process.wait(), timeout=3)
                except asyncio.TimeoutError:
                    process.kill()
                    await process.wait()


def models() -> list[dict]:
    try:
        return asyncio.run(_models())
    except OSError:
        raise RuntimeError("Claude Code CLI가 없습니다. Claude Code를 설치하세요") from None
    except asyncio.TimeoutError:
        raise RuntimeError("Claude Code 모델 목록 응답 시간이 초과되었습니다") from None


def ask(prompt: str, system: str, model: str, effort: str = "", schema: dict | None = None,
        timeout: int = 180) -> str:
    if not isinstance(model, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:\[\]-]{0,199}", model):
        raise ValueError("올바른 Claude 모델을 선택하세요")
    if not isinstance(effort, str) or effort and not re.fullmatch(r"[a-z][a-z0-9_-]{0,31}", effort):
        raise ValueError("올바른 추론 강도를 선택하세요")
    if not auth_status():
        raise RuntimeError(LOGIN_ERROR)
    command = [CLAUDE, *_flags(), "--model", model, "--system-prompt", system, "--output-format", "json"]
    if effort:
        command += ["--effort", effort]
    if schema is not None:
        command += ["--json-schema", json.dumps(schema, ensure_ascii=False)]
    try:
        with tempfile.TemporaryDirectory(prefix="yh-claude-") as directory:
            result = subprocess.run(command, input=prompt, capture_output=True, text=True,
                                    timeout=timeout, cwd=directory, env=_env())
    except OSError:
        raise RuntimeError("Claude Code CLI를 실행할 수 없습니다. 설치 상태를 확인하세요") from None
    except subprocess.TimeoutExpired:
        raise RuntimeError("Claude Code 응답 시간이 초과되었습니다. 다시 시도하세요") from None
    if result.returncode:
        raise RuntimeError(REQUEST_ERROR)
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise RuntimeError("Claude Code 응답 형식을 확인할 수 없습니다") from None
    if not isinstance(payload, dict) or payload.get("is_error"):
        raise RuntimeError(REQUEST_ERROR)
    if payload.get("structured_output") is not None:
        return json.dumps(payload["structured_output"], ensure_ascii=False)
    answer = payload.get("result")
    if not isinstance(answer, str) or not answer.strip():
        raise RuntimeError("Claude Code 응답이 비어 있습니다")
    return answer.strip()
