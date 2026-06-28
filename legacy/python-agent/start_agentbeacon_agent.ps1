param(
    [int]$Port = 42180,
    [string]$HostAddress = ""
)

$ErrorActionPreference = "Stop"

$existing = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($existing) {
    exit 0
}

$agentPath = Join-Path $PSScriptRoot "agentbeacon_agent.py"
$python = (Get-Command pythonw.exe -ErrorAction SilentlyContinue).Source
if (-not $python) {
    $python = (Get-Command python.exe -ErrorAction Stop).Source
}

$arguments = @($agentPath, "--port", "$Port")
if ($HostAddress) {
    $arguments += @("--host", $HostAddress)
}

Start-Process `
    -FilePath $python `
    -ArgumentList $arguments `
    -WorkingDirectory $PSScriptRoot `
    -WindowStyle Hidden
