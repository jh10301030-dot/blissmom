"""여러 스크립트(fetch.py, build.py, launch.py)가 공유하는 공통 유틸리티.

표준 라이브러리 + requests 만 사용한다.
"""
from __future__ import annotations

import csv
import json
import os
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

import requests

# ---------------------------------------------------------------------------
# 경로
# ---------------------------------------------------------------------------

def project_dir() -> Path:
    return Path(__file__).resolve().parent


def data_dir() -> Path:
    d = project_dir() / "data"
    d.mkdir(parents=True, exist_ok=True)
    return d


def thumbs_dir() -> Path:
    d = project_dir() / "thumbs"
    d.mkdir(parents=True, exist_ok=True)
    return d


def logs_dir() -> Path:
    d = project_dir() / "logs"
    d.mkdir(parents=True, exist_ok=True)
    return d


def reports_dir() -> Path:
    d = project_dir() / "reports"
    d.mkdir(parents=True, exist_ok=True)
    return d


# ---------------------------------------------------------------------------
# 원자적 파일 쓰기 (쓰는 도중 빈 화면/깨진 파일 방지)
# ---------------------------------------------------------------------------

def atomic_write_text(path: Path, content: str, encoding: str = "utf-8") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(
        dir=str(path.parent), prefix=path.name + ".", suffix=".tmp"
    )
    try:
        with os.fdopen(fd, "w", encoding=encoding, newline="") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def atomic_write_bytes(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(
        dir=str(path.parent), prefix=path.name + ".", suffix=".tmp"
    )
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def load_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_json_atomic(path: Path, obj: Any) -> None:
    atomic_write_text(path, json.dumps(obj, ensure_ascii=False, indent=2))


# ---------------------------------------------------------------------------
# 설정
# ---------------------------------------------------------------------------

DEFAULT_CONFIG = {
    "access_token": "",
    "ig_user_id": "",
    "api_version": "v21.0",
    "daily_record_hour": 9,
    "media_fetch_limit": 100,
    "recent_days_for_media_insights": 21,
}

PLACEHOLDER_MARKERS = ("<", ">", "여기에", "paste", "PASTE")


class ConfigError(RuntimeError):
    pass


def config_path() -> Path:
    return project_dir() / "config.json"


def load_config() -> dict:
    p = config_path()
    if not p.exists():
        raise ConfigError(
            f"설정 파일이 없습니다: {p}\n"
            f"config.example.json 을 config.json 으로 복사한 뒤 "
            f"access_token 값을 채워주세요."
        )
    with open(p, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    merged = dict(DEFAULT_CONFIG)
    merged.update(cfg)
    token = merged.get("access_token", "")
    if not token or any(m in token for m in PLACEHOLDER_MARKERS):
        raise ConfigError(
            "config.json 의 access_token 이 비어있거나 예시값 그대로입니다. "
            "인스타그램 액세스 토큰을 입력해주세요."
        )
    return merged


def save_config(cfg: dict) -> None:
    save_json_atomic(config_path(), cfg)


# ---------------------------------------------------------------------------
# 로그
# ---------------------------------------------------------------------------

def log(msg: str) -> None:
    line = f"[{datetime.now().isoformat(timespec='seconds')}] {msg}"
    try:
        print(line)
    except Exception:
        pass
    try:
        log_file = logs_dir() / "run.log"
        with open(log_file, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


# ---------------------------------------------------------------------------
# API 호출 (재시도 + 지수 백오프)
# ---------------------------------------------------------------------------

class ApiError(RuntimeError):
    def __init__(self, message: str, status_code: Optional[int] = None, body: Any = None):
        super().__init__(message)
        self.status_code = status_code
        self.body = body


GRAPH_BASE = "https://graph.facebook.com"


def api_get(
    session: requests.Session,
    path: str,
    params: dict,
    api_version: str,
    max_retries: int = 4,
    backoff_base: float = 2.0,
    timeout: int = 30,
) -> dict:
    """GET {GRAPH_BASE}/{api_version}/{path}.

    - 5xx / 네트워크 오류 -> 재시도 (2,4,8,16초)
    - 4xx (요청 자체가 잘못됨, 예: 지원 안 하는 지표) -> 즉시 ApiError, 재시도 안 함
      (호출부에서 지표 세트를 낮춰 재시도하도록)
    """
    url = f"{GRAPH_BASE}/{api_version}/{path.lstrip('/')}"
    last_exc: Optional[Exception] = None
    for attempt in range(max_retries + 1):
        try:
            resp = session.get(url, params=params, timeout=timeout)
        except requests.exceptions.RequestException as e:
            last_exc = e
            if attempt < max_retries:
                time.sleep(backoff_base * (2 ** attempt))
                continue
            raise ApiError(f"네트워크 오류: {e}") from e

        if resp.status_code == 200:
            return resp.json()

        try:
            body = resp.json()
        except ValueError:
            body = {"error": {"message": resp.text[:500]}}

        if resp.status_code >= 500:
            last_exc = ApiError(
                f"서버 오류 {resp.status_code}: {body}", resp.status_code, body
            )
            if attempt < max_retries:
                time.sleep(backoff_base * (2 ** attempt))
                continue
            raise last_exc

        # 4xx: 즉시 반환 가능한 예외 (재시도 무의미, 호출부가 판단)
        raise ApiError(
            f"요청 오류 {resp.status_code}: {body}", resp.status_code, body
        )

    if last_exc:
        raise last_exc
    raise ApiError("알 수 없는 오류로 요청 실패")


# ---------------------------------------------------------------------------
# CSV (append-only 장기 기록 파일용)
# ---------------------------------------------------------------------------

def read_csv_rows(path: Path) -> list:
    if not path.exists():
        return []
    with open(path, "r", encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def write_csv_rows_atomic(path: Path, fieldnames: list, rows: list) -> None:
    import io

    buf = io.StringIO(newline="")
    writer = csv.DictWriter(buf, fieldnames=fieldnames, extrasaction="ignore")
    writer.writeheader()
    for row in rows:
        writer.writerow({k: row.get(k, "") for k in fieldnames})
    atomic_write_text(path, buf.getvalue())


def upsert_csv_rows(path: Path, fieldnames: list, key_field: str, new_rows: dict) -> None:
    """key_field 값을 기준으로 병합. 기존 행은 절대 삭제하지 않는다.

    new_rows: {key: {field: value, ...}} - 있는 필드만 덮어씀(병합), 없던 키는 새 행으로 추가.
    """
    existing = read_csv_rows(path)
    by_key = {r[key_field]: dict(r) for r in existing}
    for key, fields in new_rows.items():
        row = by_key.get(key, {key_field: key})
        row.update(fields)
        by_key[key] = row
    all_rows = sorted(by_key.values(), key=lambda r: r[key_field])
    write_csv_rows_atomic(path, fieldnames, all_rows)


def api_get_full_url(
    session: requests.Session, url: str, max_retries: int = 4, backoff_base: float = 2.0
) -> dict:
    """페이지네이션 next 링크처럼 access_token 이 이미 포함된 전체 URL을 호출."""
    last_exc: Optional[Exception] = None
    for attempt in range(max_retries + 1):
        try:
            resp = session.get(url, timeout=30)
        except requests.exceptions.RequestException as e:
            last_exc = e
            if attempt < max_retries:
                time.sleep(backoff_base * (2 ** attempt))
                continue
            raise ApiError(f"네트워크 오류: {e}") from e
        if resp.status_code == 200:
            return resp.json()
        try:
            body = resp.json()
        except ValueError:
            body = {"error": {"message": resp.text[:500]}}
        if resp.status_code >= 500 and attempt < max_retries:
            time.sleep(backoff_base * (2 ** attempt))
            continue
        raise ApiError(f"요청 오류 {resp.status_code}: {body}", resp.status_code, body)
    if last_exc:
        raise last_exc
    raise ApiError("알 수 없는 오류로 요청 실패")


def download_file(session: requests.Session, url: str, dest: Path, max_retries: int = 4) -> bool:
    last_exc: Optional[Exception] = None
    for attempt in range(max_retries + 1):
        try:
            resp = session.get(url, timeout=30)
            if resp.status_code == 200 and resp.content:
                atomic_write_bytes(dest, resp.content)
                return True
            last_exc = ApiError(f"다운로드 실패 {resp.status_code}: {url}")
        except requests.exceptions.RequestException as e:
            last_exc = e
        if attempt < max_retries:
            time.sleep(2.0 * (2 ** attempt))
    log(f"썸네일 다운로드 실패: {dest.name} ({last_exc})")
    return False
