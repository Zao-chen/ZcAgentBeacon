param(
  [int]$Port = 42180,
  [string]$InstallDir = "$env:LOCALAPPDATA\ZcAgentBeacon\Companion",
  [string]$ExeName = "zc-agentbeacon-companion.exe"
)

$ErrorActionPreference = "Stop"

$sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = Join-Path $sourceDir $ExeName
if (-not (Test-Path -LiteralPath $source)) {
  throw "Missing $ExeName next to installer."
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$target = Join-Path $InstallDir $ExeName
Copy-Item -LiteralPath $source -Destination $target -Force

$startupDir = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupDir "ZcAgentBeacon Companion.lnk"
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $target
$shortcut.Arguments = "--port $Port"
$shortcut.WorkingDirectory = $InstallDir
$shortcut.WindowStyle = 7
$shortcut.Description = "Starts ZcAgentBeacon Companion for Codex conversation monitoring."
$shortcut.Save()

Start-Process -FilePath $target -ArgumentList @("--port", "$Port") -WindowStyle Hidden
Start-Sleep -Seconds 2

Write-Host "ZcAgentBeacon Companion installed to $target"
Write-Host "Startup shortcut: $shortcutPath"
Write-Host "Status URL: http://<this-machine>:$Port/status"
