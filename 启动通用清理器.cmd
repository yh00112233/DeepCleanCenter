@echo off
cd /d "%~dp0"
if exist "%~dp0dist\DeepCleanCenter.exe" (
  start "" "%~dp0dist\DeepCleanCenter.exe"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Clean_PC_Selectively.ps1"
)
