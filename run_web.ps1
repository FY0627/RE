$env:Path = "$env:Path;D:\DevTools\flutter\bin"
Set-Location -Path $PSScriptRoot
Write-Host "正在启动日常记账 (Flutter Web)..." -ForegroundColor Cyan
flutter run -d chrome --web-port 8080
