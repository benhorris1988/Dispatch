@echo off
REM Dispatch CP-SAT scheduling engine on 127.0.0.1:8010 (localhost only).
REM Set engine_url in api\config.php to http://127.0.0.1:8010 to use it.
cd /d "%~dp0"
python -m uvicorn app:app --host 127.0.0.1 --port 8010
