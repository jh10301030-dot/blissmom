"""바탕화면 바로가기가 호출하는 진입점.

- 콘솔 창이 뜨지 않게 하려면 바로가기 대상이 python.exe 가 아니라 pythonw.exe 여야 한다
  (setup_shortcut.py 가 자동으로 그렇게 만들어준다).
- fetch -> build 를 같은 프로세스 안에서 함수로 직접 호출한다.
  (subprocess로 띄워 표준출력을 파싱하지 않는다 - 인코딩 문제를 원천 차단)
- 네트워크가 아직 안 붙은 상태(절전에서 막 깨어난 직후 등)를 감안해 fetch 재시도 간격을 둔다.
- fetch 가 실패하더라도 build 는 항상 시도한다 (있는 데이터로라도 화면을 보여준다).
"""
from __future__ import annotations

import sys
import time

import build as build_mod
import fetch as fetch_mod
from common import ConfigError, log

FETCH_RETRY_DELAYS = [0, 30, 120, 300]  # 초 단위: 즉시, 30초, 2분, 5분 후 재시도


def try_fetch() -> bool:
    last_err = None
    for i, delay in enumerate(FETCH_RETRY_DELAYS):
        if delay:
            log(f"fetch 재시도 대기 {delay}초 (네트워크/절전 복귀 대비, {i+1}/{len(FETCH_RETRY_DELAYS)})")
            time.sleep(delay)
        try:
            result = fetch_mod.run()
            if result.get("ok"):
                return True
            last_err = result.get("errors")
        except ConfigError as e:
            log(f"설정 오류로 fetch 중단: {e}")
            return False
        except Exception as e:
            last_err = e
            log(f"fetch 시도 실패: {e}")
    log(f"fetch 최종 실패, 기존 데이터로 대시보드만 갱신합니다: {last_err}")
    return False


def main() -> int:
    log("===== launch.py 시작 =====")
    try_fetch()
    try:
        build_mod.build(open_browser=True)
    except Exception as e:
        log(f"대시보드 생성 실패: {e}")
        return 1
    log("===== launch.py 종료 =====")
    return 0


if __name__ == "__main__":
    sys.exit(main())
