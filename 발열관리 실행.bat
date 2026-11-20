@echo off
rem Firebat F1 (7640HS / H255) thermal manager - double click to run
if not exist "%~dp0MiniPC-Cool.ps1" goto missing
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0MiniPC-Cool.ps1"
exit /b 0

:missing
chcp 65001 >nul
echo.
echo  [미니PC 발열관리] 프로그램 파일(MiniPC-Cool.ps1)을 찾지 못했어요.
echo.
echo  압축 파일(zip) 안에서 바로 실행하면 이렇게 됩니다.
echo  zip 파일을 먼저 "압축 풀기" 한 다음, 풀린 폴더 안에서 다시 실행해 주세요.
echo.
echo  (MiniPC-Cool.ps1 not found. Please extract the zip first, then run this file again.)
echo.
pause
exit /b 1
