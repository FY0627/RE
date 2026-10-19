@echo off
chcp 65001 >nul
echo 正在启动日常记账 (Flutter Web)...
set "PATH=%PATH%;D:\DevTools\flutter\bin"
cd /d "%~dp0"
flutter run -d chrome --web-port 8080
pause
