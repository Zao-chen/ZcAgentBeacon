param(
    [int]$Port = 42180,
    [string]$InstallDir = "$env:LOCALAPPDATA\AgentBeacon\Companion"
)

$ErrorActionPreference = "Stop"

$sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$startupDir = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupDir "AgentBeacon Companion Agent.lnk"
$startScript = Join-Path $InstallDir "start_agentbeacon_agent.ps1"

if (-not (Get-Command python.exe -ErrorAction SilentlyContinue) -and -not (Get-Command pythonw.exe -ErrorAction SilentlyContinue)) {
    throw "Python 3 was not found. Install Python 3 first, then run this installer again."
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -LiteralPath (Join-Path $sourceDir "agentbeacon_agent.py") -Destination $InstallDir -Force
Copy-Item -LiteralPath (Join-Path $sourceDir "start_agentbeacon_agent.ps1") -Destination $InstallDir -Force

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "powershell.exe"
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$startScript`" -Port $Port"
$shortcut.WorkingDirectory = $InstallDir
$shortcut.WindowStyle = 7
$shortcut.Description = "Starts the local AgentBeacon companion agent for Codex conversation monitoring."
$shortcut.Save()

& powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $startScript -Port $Port
Start-Sleep -Seconds 2

$listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($listener) {
    Write-Host "AgentBeacon Companion installed and listening on port $Port."
    Write-Host "Startup shortcut: $shortcutPath"
} else {
    Write-Warning "Installed, but the agent is not listening on port $Port yet. If Windows Firewall prompts, allow Private networks."
}
