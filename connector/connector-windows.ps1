#Requires -RunAsAdministrator
<#
.SYNOPSIS
    wg0 Connector for Windows

.DESCRIPTION
    Enrolls a Windows node with the wg0 Brain and maintains WireGuard connectivity.
    Requires WireGuard for Windows to be installed first.

.EXAMPLE
    # Client node (default)
    .\connector-windows.ps1 enroll -Token "eyJhbG..." -BrainUrl "https://brain.example.com"

    # Host node
    .\connector-windows.ps1 enroll -Token "eyJhbG..." -BrainUrl "https://brain.example.com" -Role host

    # Remove this node from the Brain and wipe all local WireGuard config
    .\connector-windows.ps1 unenroll -BrainUrl "https://brain.example.com"

.NOTES
    Download WireGuard for Windows: https://www.wireguard.com/install/
    Run this script from an elevated (Administrator) PowerShell prompt.
    If execution policy blocks it: Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#>

[CmdletBinding()]
param(
    [Parameter(Position=0, Mandatory=$true)]
    [ValidateSet("enroll","unenroll")]
    [string]$Command,

    [Parameter()]
    [string]$Token,

    [Parameter(Mandatory=$true)]
    [string]$BrainUrl,

    [Parameter()]
    [string]$NodeName = $env:COMPUTERNAME,

    [Parameter()]
    [ValidateSet("client","host")]
    [string]$Role = "client"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Constants ─────────────────────────────────────────────────────────────────
$WG_DIR         = "C:\Program Files\WireGuard"
$WG_EXE         = "$WG_DIR\wireguard.exe"
$WG_CLI         = "$WG_DIR\wg.exe"
$WG_IFACE       = "wg0"
$DATA_DIR       = "C:\ProgramData\WireGuard\wg0"
$CONFIG_FILE    = "C:\ProgramData\WireGuard\${WG_IFACE}.conf"
$PRIV_KEY_FILE  = "$DATA_DIR\private.key"
$PUB_KEY_FILE   = "$DATA_DIR\public.key"
$NODE_ID_FILE   = "$DATA_DIR\node_id.txt"
$HB_SCRIPT      = "$DATA_DIR\heartbeat.ps1"
$HB_TASK_NAME   = "Wg0Heartbeat"
$HEARTBEAT_SEC  = 30

# ── Helpers ───────────────────────────────────────────────────────────────────
function Log([string]$msg) {
    $ts = (Get-Date -Format "HH:mm:ssZ" -AsUTC)
    Write-Host "[wg0 $ts] $msg"
}

function Die([string]$msg) {
    Write-Error "[wg0 ERROR] $msg"
    exit 1
}

function Warn([string]$msg) {
    Write-Warning "[wg0] $msg"
}

# ── Strip trailing slash ──────────────────────────────────────────────────────
$BrainUrl = $BrainUrl.TrimEnd('/')

# ── WireGuard presence check ──────────────────────────────────────────────────
if (-not (Test-Path $WG_EXE)) {
    Die "WireGuard for Windows not found at '$WG_EXE'.`nDownload and install from: https://www.wireguard.com/install/"
}
if (-not (Test-Path $WG_CLI)) {
    Die "wg.exe not found at '$WG_CLI'. Reinstall WireGuard for Windows."
}

# ── UNENROLL ──────────────────────────────────────────────────────────────────
if ($Command -eq "unenroll") {
    Log "Starting unenroll from Brain at $BrainUrl ..."

    if (-not (Test-Path $NODE_ID_FILE)) {
        Die "No node_id found at $NODE_ID_FILE. This system does not appear to be enrolled."
    }
    $nodeId = Get-Content $NODE_ID_FILE -Raw | ForEach-Object { $_.Trim() }
    Log "Node ID: $nodeId"

    Log "Notifying Brain to remove node..."
    try {
        Invoke-RestMethod -Uri "$BrainUrl/api/v1/nodes/$nodeId/self" `
            -Method Delete -TimeoutSec 10 | Out-Null
        Log "Brain confirmed node removal."
    } catch {
        Warn "Brain request failed (unreachable?). Continuing local cleanup."
    }

    # Stop + remove WireGuard tunnel service
    $svcName = "WireGuardTunnel`$$WG_IFACE"
    if (Get-Service $svcName -ErrorAction SilentlyContinue) {
        Log "Uninstalling WireGuard tunnel service..."
        & $WG_EXE /uninstalltunnel $WG_IFACE 2>$null | Out-Null
    }

    # Remove scheduled task
    if (Get-ScheduledTask -TaskName $HB_TASK_NAME -ErrorAction SilentlyContinue) {
        Log "Removing heartbeat scheduled task..."
        Unregister-ScheduledTask -TaskName $HB_TASK_NAME -Confirm:$false
    }

    # Remove config and keys
    if (Test-Path $CONFIG_FILE)   { Remove-Item $CONFIG_FILE -Force }
    if (Test-Path $DATA_DIR)      { Remove-Item $DATA_DIR -Recurse -Force }

    Log "Unenroll complete. This node has been removed from wg0."
    exit 0
}

# ── ENROLL ────────────────────────────────────────────────────────────────────
if (-not $Token) {
    Die "Token is required for enroll. Usage: .\connector-windows.ps1 enroll -Token <TOKEN> -BrainUrl <URL>"
}

Log "wg0 Windows Connector"
Log "  Node: $NodeName | Role: $Role | Brain: $BrainUrl"

# ── Directory setup ───────────────────────────────────────────────────────────
if (-not (Test-Path $DATA_DIR)) {
    New-Item -ItemType Directory -Path $DATA_DIR -Force | Out-Null
}

# Secure the directory (SYSTEM + Administrators only)
$acl = Get-Acl $DATA_DIR
$acl.SetAccessRuleProtection($true, $false)
foreach ($identity in @("SYSTEM","Administrators")) {
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $identity, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
    )
    $acl.AddAccessRule($rule)
}
Set-Acl $DATA_DIR $acl

# ── Key generation ────────────────────────────────────────────────────────────
if (-not (Test-Path $PRIV_KEY_FILE)) {
    Log "Generating WireGuard keypair..."
    $privKey = & $WG_CLI genkey
    $pubKey  = ($privKey | & $WG_CLI pubkey)
    Set-Content -Path $PRIV_KEY_FILE -Value $privKey -Encoding ASCII -NoNewline
    Set-Content -Path $PUB_KEY_FILE  -Value $pubKey  -Encoding ASCII -NoNewline
    # Restrict key file permissions
    $keyAcl = Get-Acl $PRIV_KEY_FILE
    $keyAcl.SetAccessRuleProtection($true, $false)
    $keyRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "SYSTEM", "FullControl", "None", "None", "Allow"
    )
    $keyAcl.AddAccessRule($keyRule)
    Set-Acl $PRIV_KEY_FILE $keyAcl
}
$PRIV_KEY = Get-Content $PRIV_KEY_FILE -Raw | ForEach-Object { $_.Trim() }
$PUB_KEY  = Get-Content $PUB_KEY_FILE  -Raw | ForEach-Object { $_.Trim() }
Log "Public key: $PUB_KEY"

# ── Detect public endpoint ────────────────────────────────────────────────────
$endpoint = ""
try {
    $publicIp = (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 5).Trim()
    if ($publicIp -match '^\d+\.\d+\.\d+\.\d+$') {
        $endpoint = "${publicIp}:51820"
    }
} catch { <# endpoint detection is best-effort #> }

# ── Enrollment ────────────────────────────────────────────────────────────────
if (-not (Test-Path $NODE_ID_FILE)) {
    Log "Enrolling node '$NodeName' with Brain at $BrainUrl ..."

    $body = @{
        token             = $Token
        public_key        = $PUB_KEY
        node_name         = $NodeName
        os_type           = "windows"
        role              = $Role
        advertised_routes = @()
        endpoint          = $endpoint
    } | ConvertTo-Json

    try {
        $resp = Invoke-RestMethod -Uri "$BrainUrl/api/v1/enroll/register" `
            -Method Post -ContentType "application/json" -Body $body -TimeoutSec 30
    } catch {
        Die "Enrollment failed: $_`nCheck TOKEN and BRAIN_URL."
    }

    $nodeId      = $resp.node_id
    $overlayIp   = $resp.overlay_ip
    $wgConfig    = $resp.wg_config
    $networkType = if ($resp.network_type) { $resp.network_type } else { "overlay" }

    # ── Windows config post-processing ───────────────────────────────────────
    #
    # WireGuard for Windows tunnel service does not support PostUp/PreDown.
    # Strip those lines. Also strip Linux-specific ip-route commands.
    #
    $wgConfig = ($wgConfig -split "`n" | Where-Object {
        $_ -notmatch '^PostUp' -and $_ -notmatch '^PreDown'
    }) -join "`n"

    # Substitute private key placeholder
    $wgConfig = $wgConfig -replace "# PrivateKey = <CONNECTOR_FILLS_THIS_IN>", "PrivateKey = $PRIV_KEY"

    # Write config
    $configDir = Split-Path $CONFIG_FILE
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }
    Set-Content -Path $CONFIG_FILE -Value $wgConfig -Encoding UTF8

    Set-Content -Path $NODE_ID_FILE -Value $nodeId -Encoding ASCII -NoNewline

    Log "Enrolled! Assigned IP: $overlayIp | Node ID: $nodeId | Network type: $networkType"
}

$nodeId = Get-Content $NODE_ID_FILE -Raw | ForEach-Object { $_.Trim() }

# ── Install / verify WireGuard tunnel service ─────────────────────────────────
$svcName = "WireGuardTunnel`$$WG_IFACE"
if (-not (Get-Service $svcName -ErrorAction SilentlyContinue)) {
    Log "Installing WireGuard tunnel service for interface $WG_IFACE ..."
    & $WG_EXE /installtunnel $CONFIG_FILE
    Start-Sleep -Seconds 2
}

if (Get-Service $svcName -ErrorAction SilentlyContinue) {
    $svc = Get-Service $svcName
    if ($svc.Status -ne "Running") {
        Start-Service $svcName
    }
    Log "WireGuard tunnel service is running."
} else {
    Warn "Tunnel service not found after install — check WireGuard event log."
}

# ── Heartbeat script ──────────────────────────────────────────────────────────
$hbContent = @"
# Auto-generated by wg0 connector (Windows). Do not edit manually.
`$nodeId = (Get-Content '$NODE_ID_FILE' -Raw).Trim()
`$endpoint = ''
try {
    `$ip = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 5).Trim()
    if (`$ip -match '^\d+\.\d+\.\d+\.\d+$') { `$endpoint = "`${ip}:51820" }
} catch {}

# Collect TX/RX bytes from WireGuard transfer stats
`$txBytes = 0; `$rxBytes = 0
try {
    `$wgOut = & '$WG_CLI' show '$WG_IFACE' transfer 2>`$null
    foreach (`$line in `$wgOut) {
        `$parts = `$line -split '\s+'
        if (`$parts.Count -ge 3) { `$rxBytes += [long]`$parts[1]; `$txBytes += [long]`$parts[2] }
    }
} catch {}

`$body = @{ endpoint = `$endpoint; tx_bytes = `$txBytes; rx_bytes = `$rxBytes } | ConvertTo-Json
try {
    `$resp = Invoke-RestMethod -Uri '$BrainUrl/api/v1/nodes/`$nodeId/heartbeat' ``
        -Method Post -ContentType 'application/json' -Body `$body -TimeoutSec 10

    # Apply peer updates via wg set (live sync without tunnel restart)
    foreach (`$peer in `$resp.peers) {
        `$args = @('$WG_IFACE', 'peer', `$peer.public_key,
                   'allowed-ips', `$peer.allowed_ips,
                   'persistent-keepalive', '25')
        if (`$peer.endpoint) { `$args += @('endpoint', `$peer.endpoint) }
        & '$WG_CLI' set @args 2>`$null
    }
} catch { exit 0 }
"@
Set-Content -Path $HB_SCRIPT -Value $hbContent -Encoding UTF8

# ── Install heartbeat — Windows Scheduled Task ────────────────────────────────
Log "Installing heartbeat scheduled task (every ${HEARTBEAT_SEC}s)..."

# Remove old task if present
if (Get-ScheduledTask -TaskName $HB_TASK_NAME -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $HB_TASK_NAME -Confirm:$false
}

$action  = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$HB_SCRIPT`""

# Repeat every N seconds indefinitely using a repetition trigger
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(10)
$trigger.RepetitionInterval = [TimeSpan]::FromSeconds($HEARTBEAT_SEC)
$trigger.RepetitionDuration = [TimeSpan]::MaxValue

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable

$principal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

Register-ScheduledTask `
    -TaskName $HB_TASK_NAME `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Force | Out-Null

Log "Heartbeat scheduled task installed (every ${HEARTBEAT_SEC}s, runs as SYSTEM)."

Log ""
Log "wg0 connector setup complete."
Log "  WireGuard interface: $WG_IFACE"
Log "  Node ID:             $nodeId"
Log "  Config:              $CONFIG_FILE"
Log "  Keys:                $DATA_DIR\"
Log ""
Log "Manage tunnel: WireGuard app or 'sc start/stop WireGuardTunnel`$$WG_IFACE'"
Log "View heartbeat: Task Scheduler → $HB_TASK_NAME"
Log ""
Log "To unenroll this node later:"
Log "  .\connector-windows.ps1 unenroll -BrainUrl $BrainUrl"
