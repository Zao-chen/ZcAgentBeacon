param(
    [int]$Port = 42180,
    [string]$InstallDir = "$env:LOCALAPPDATA\AgentBeacon\Companion",
    [switch]$KeepFiles
)

$ErrorActionPreference = "Stop"

$startupDir = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupDir "AgentBeacon Companion Agent.lnk"

Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue

$processes = Get-CimInstance Win32_Process |
    Where-Object {
        $_.CommandLine -and
        $_.CommandLine -like "*agentbeacon_agent.py*" -and
        ($_.CommandLine -like "*--port $Port*" -or $_.CommandLine -like "*--port`"$Port`"*" -or $_.CommandLine -like "*--port*$Port*")
    }

foreach ($process in $processes) {
    Invoke-CimMethod -InputObject $process -MethodName Terminate | Out-Null
}

if (-not $KeepFiles) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "AgentBeacon Companion uninstalled."
