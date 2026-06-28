param(
  [string]$InstallDir = "$env:LOCALAPPDATA\ZcAgentBeacon\Companion",
  [string]$ExeName = "zc-agentbeacon-companion.exe",
  [switch]$KeepFiles
)

$ErrorActionPreference = "Stop"

$startupDir = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupDir "ZcAgentBeacon Companion.lnk"
Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue

$processes = Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -and $_.CommandLine -like "*$ExeName*" }
foreach ($process in $processes) {
  Invoke-CimMethod -InputObject $process -MethodName Terminate | Out-Null
}

if (-not $KeepFiles) {
  Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "ZcAgentBeacon Companion uninstalled."
