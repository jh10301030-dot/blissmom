"""바탕화면 바로가기 생성 + 매일 자동 실행 등록 (Windows / macOS).

★ 반드시 사용자의 실제 PC(윈도우 또는 맥)에서 직접 실행해야 합니다. ★
(클라우드/서버 환경에는 바탕화면이나 작업 스케줄러가 없습니다.)

사용법:
    python setup_shortcut.py

- Windows: 바탕화면에 .lnk 바로가기 생성 + 작업 스케줄러에 매일 실행 등록
  (콘솔 창이 안 뜨도록 pythonw.exe 사용, 절전이면 깨워서 실행 WakeToRun,
   놓친 실행은 컴퓨터를 켰을 때 곧바로 실행 StartWhenAvailable)
- macOS: 바탕화면에 더블클릭 앱(.app) 생성 + launchd 에 매일 실행 등록
  (launchd는 절전 중 놓친 StartCalendarInterval 작업을 깨어난 뒤 자동 실행한다)
"""
from __future__ import annotations

import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from common import ConfigError, load_config, project_dir


def windows_setup(hour: int, minute: int, task_name: str, app_name: str) -> None:
    proj = project_dir()
    python_exe = Path(sys.executable)
    pythonw = python_exe.with_name("pythonw.exe")
    exe_for_shortcut = pythonw if pythonw.exists() else python_exe
    launch_py = proj / "launch.py"
    desktop = Path.home() / "Desktop"
    lnk_path = desktop / f"{app_name}.lnk"

    ps_script = f"""
$ErrorActionPreference = "Stop"

# 1) 바탕화면 바로가기 생성
$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut("{lnk_path}")
$Shortcut.TargetPath = "{exe_for_shortcut}"
$Shortcut.Arguments = '"{launch_py}"'
$Shortcut.WorkingDirectory = "{proj}"
$Shortcut.IconLocation = "{exe_for_shortcut}"
$Shortcut.Save()
Write-Output "바로가기 생성됨: {lnk_path}"

# 2) 작업 스케줄러 등록 (매일 {hour:02d}:{minute:02d}, 절전이면 깨워서 실행, 놓치면 켰을 때 실행)
$Action = New-ScheduledTaskAction -Execute "{exe_for_shortcut}" -Argument '"{launch_py}"' -WorkingDirectory "{proj}"
$Trigger = New-ScheduledTaskTrigger -Daily -At {hour:02d}:{minute:02d}
$Settings = New-ScheduledTaskSettingsSet -WakeToRun -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Hours 1)
Unregister-ScheduledTask -TaskName "{task_name}" -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName "{task_name}" -Action $Action -Trigger $Trigger -Settings $Settings -Description "인스타그램 대시보드 매일 자동 갱신" | Out-Null
Write-Output "작업 스케줄러 등록됨: {task_name} (매일 {hour:02d}:{minute:02d})"
"""
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".ps1", delete=False, encoding="utf-8-sig"
    ) as f:
        f.write(ps_script)
        ps1_path = f.name

    try:
        result = subprocess.run(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ps1_path],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        print(result.stdout)
        if result.returncode != 0:
            print(result.stderr, file=sys.stderr)
            raise RuntimeError("PowerShell 스크립트 실행 실패 (관리자 권한이 필요할 수 있습니다)")
    finally:
        Path(ps1_path).unlink(missing_ok=True)


def macos_setup(hour: int, minute: int, task_name: str, app_name: str) -> None:
    proj = project_dir()
    python3 = shutil.which("python3") or sys.executable
    launch_py = proj / "launch.py"
    desktop = Path.home() / "Desktop"
    app_path = desktop / f"{app_name}.app"
    plist_path = Path.home() / "Library" / "LaunchAgents" / f"{task_name}.plist"

    if shutil.which("osacompile"):
        script_content = (
            f'do shell script "cd ' + str(proj).replace('"', '\\"') +
            f' && \'{python3}\' launch.py > /dev/null 2>&1 &"'
        )
        with tempfile.NamedTemporaryFile(mode="w", suffix=".applescript", delete=False, encoding="utf-8") as f:
            f.write(script_content)
            applescript_path = f.name
        try:
            if app_path.exists():
                shutil.rmtree(app_path)
            subprocess.run(
                ["osacompile", "-o", str(app_path), applescript_path], check=True
            )
            print(f"바탕화면 앱 생성됨(콘솔 안 뜸): {app_path}")
        finally:
            Path(applescript_path).unlink(missing_ok=True)
    else:
        command_path = desktop / f"{app_name}.command"
        content = f'#!/bin/bash\ncd "{proj}"\n"{python3}" launch.py\n'
        command_path.write_text(content, encoding="utf-8")
        command_path.chmod(0o755)
        print(
            f"osacompile 이 없어 .command 파일로 생성됨(더블클릭 시 터미널이 잠깐 보입니다): {command_path}"
        )

    plist_path.parent.mkdir(parents=True, exist_ok=True)
    plist_content = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{task_name}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{python3}</string>
    <string>{launch_py}</string>
  </array>
  <key>WorkingDirectory</key><string>{proj}</string>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>{hour}</integer>
    <key>Minute</key><integer>{minute}</integer>
  </dict>
  <key>StandardOutPath</key><string>{proj}/logs/launchd_stdout.log</string>
  <key>StandardErrorPath</key><string>{proj}/logs/launchd_stderr.log</string>
</dict>
</plist>
"""
    plist_path.write_text(plist_content, encoding="utf-8")
    subprocess.run(["launchctl", "unload", str(plist_path)], capture_output=True)
    subprocess.run(["launchctl", "load", "-w", str(plist_path)], check=True)
    print(f"launchd 등록됨: {plist_path} (매일 {hour:02d}:{minute:02d})")
    print("※ launchd는 절전/종료 중 놓친 실행을 컴퓨터가 켜졌을 때 자동으로 대신 실행합니다.")


def main() -> int:
    try:
        cfg = load_config()  # access_token 없으면 여기서 바로 에러로 안내
    except ConfigError as e:
        print(f"설정 오류: {e}")
        return 1
    hour = int(cfg.get("daily_record_hour", 9))
    minute = 10  # 기준 시각 직후로 잡아, 그 시각이 지난 뒤 official 기록이 바로 써지게 함
    task_name = "BlissmomInstaDashboard"
    app_name = "인스타대시보드"

    system = platform.system()
    if system == "Windows":
        windows_setup(hour, minute, task_name, app_name)
    elif system == "Darwin":
        macos_setup(hour, minute, task_name, app_name)
    else:
        print(f"지원하지 않는 OS입니다: {system} (Windows/macOS 에서 실행해주세요)")
        return 1

    print("\n설정 완료! 바탕화면 아이콘을 더블클릭하면 즉시 실행되고,")
    print(f"매일 {hour:02d}:{minute:02d} 경에도 자동으로 실행됩니다.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
