# wg0-status.ps1 — wg0 tunnel status CLI for Windows
# Run from an elevated PowerShell prompt (Administrator)
#
# Usage:
#   wg0-status.ps1 [status|peers|logs|version]
#   wg0-status.ps1 status --json

param(
    [Parameter(Position=0)] [string]$Command = "status",
    [switch]$Json
)

$ErrorActionPreference = "SilentlyContinue"

$WG_DIR      = "C:\Program Files\WireGuard"
$WG_CLI      = "$WG_DIR\wg.exe"
$DATA_DIR    = "C:\ProgramData\WireGuard\wg0"
$NODE_ID_FILE = "$DATA_DIR\node_id.txt"
$WG_CONF     = "C:\ProgramData\WireGuard\wg0.conf"
$HB_SCRIPT   = "$DATA_DIR\heartbeat.ps1"
$HB_TASK     = "Wg0Heartbeat"
$WG_SVC      = "WireGuardTunnelwg0"
$LOG_PATH    = "$env:ProgramData\wg0-heartbeat.log"

function Fmt-Bytes($b) {
    if     ($b -ge 1GB) { "{0:N1} GiB" -f ($b / 1GB) }
    elseif ($b -ge 1MB) { "{0:N1} MiB" -f ($b / 1MB) }
    elseif ($b -ge 1KB) { "{0:N1} KiB" -f ($b / 1KB) }
    elseif ($b -gt 0)   { "$b B" }
    else                { "—" }
}

function Get-NodeId {
    if (Test-Path $NODE_ID_FILE) { (Get-Content $NODE_ID_FILE -Raw).Trim() }
    else { "not enrolled" }
}

function Get-OverlayIp {
    if (Test-Path $WG_CONF) {
        $line = Get-Content $WG_CONF | Where-Object { $_ -match '^Address\s*=' } | Select-Object -First 1
        if ($line) { ($line -split '=')[1].Trim() } else { "—" }
    } else { "—" }
}

function Get-WgStatus {
    $svc = Get-Service -Name $WG_SVC -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") { "running" } else { "down" }
}

function Get-HbStatus {
    $task = Get-ScheduledTask -TaskName $HB_TASK -ErrorAction SilentlyContinue
    if ($task) {
        $info = $task | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
        if ($info -and $info.LastTaskResult -eq 0) { "running" } else { "registered" }
    } else { "not installed" }
}

function Get-Peers {
    $peers = @()
    if (-not (Test-Path $WG_CLI)) { return $peers }
    $raw = & $WG_CLI show wg0 2>$null
    if (-not $raw) { return $peers }

    $cur = $null
    foreach ($line in $raw) {
        if ($line -match '^peer:\s*(.+)') {
            if ($cur) { $peers += $cur }
            $cur = @{ key=$Matches[1]; ep="—"; allowed=""; tx=0; rx=0; hs="never" }
        } elseif ($cur -and $line -match 'endpoint:\s*(.+)')       { $cur.ep = $Matches[1].Trim() }
          elseif ($cur -and $line -match 'allowed ips:\s*(.+)')    { $cur.allowed = $Matches[1].Trim() }
          elseif ($cur -and $line -match 'transfer:\s*(.+)')       {
              $tf = $Matches[1].Trim()
              if ($tf -match '([\d.]+)\s+(\w+) received,\s*([\d.]+)\s+(\w+) sent') {
                  $cur.rx = "$($Matches[1]) $($Matches[2])"
                  $cur.tx = "$($Matches[3]) $($Matches[4])"
              }
          }
          elseif ($cur -and $line -match 'latest handshake:\s*(.+)') { $cur.hs = $Matches[1].Trim() }
    }
    if ($cur) { $peers += $cur }
    return $peers
}

# ── Commands ──────────────────────────────────────────────────────────────────

function Cmd-Status {
    $nodeId  = Get-NodeId
    $overlay = Get-OverlayIp
    $wgState = Get-WgStatus
    $hbState = Get-HbStatus
    $peers   = Get-Peers

    $lastHb = "—"
    if (Test-Path $LOG_PATH) {
        $age = (Get-Date) - (Get-Item $LOG_PATH).LastWriteTime
        $lastHb = if ($age.TotalSeconds -lt 60) { "{0}s ago" -f [int]$age.TotalSeconds }
                  elseif ($age.TotalMinutes -lt 60) { "{0}m ago" -f [int]$age.TotalMinutes }
                  else { "{0}h ago" -f [int]$age.TotalHours }
    }

    if ($Json) {
        [PSCustomObject]@{
            node_id       = $nodeId
            overlay_ip    = $overlay
            wireguard     = $wgState
            heartbeat     = $hbState
            last_heartbeat= $lastHb
            peer_count    = $peers.Count
            peers         = $peers | ForEach-Object {
                [PSCustomObject]@{
                    public_key  = $_.key
                    endpoint    = $_.ep
                    allowed_ips = $_.allowed
                    tx          = $_.tx
                    rx          = $_.rx
                    handshake   = $_.hs
                }
            }
        } | ConvertTo-Json -Depth 5
        return
    }

    Write-Host ""
    Write-Host "wg0 Status" -ForegroundColor Cyan
    Write-Host ("─" * 44)
    Write-Host ("  {0,-12} {1}" -f "Node ID",   $nodeId)
    Write-Host ("  {0,-12} {1}" -f "Tunnel IP", $overlay)
    $wgColor = if ($wgState -eq "running") { "Green" } else { "Red" }
    Write-Host ("  {0,-12} " -f "WireGuard") -NoNewline
    Write-Host $wgState -ForegroundColor $wgColor
    $hbColor = if ($hbState -eq "running") { "Green" } else { "Yellow" }
    Write-Host ("  {0,-12} " -f "Heartbeat") -NoNewline
    Write-Host "$hbState (every 30s)" -ForegroundColor $hbColor
    Write-Host ("  {0,-12} {1}" -f "Last beat", $lastHb)

    Write-Host ""
    Write-Host ("Peers ({0})" -f $peers.Count) -ForegroundColor Cyan
    Write-Host ("─" * 44)
    if ($peers.Count -eq 0) {
        Write-Host "  No peers yet — heartbeat will sync them within 30s" -ForegroundColor DarkGray
    }
    foreach ($p in $peers) {
        Write-Host ("  {0}…" -f $p.key.Substring(0, [Math]::Min(20, $p.key.Length))) -ForegroundColor White
        Write-Host ("    {0,-10} {1}" -f "Allowed",   $p.allowed)
        Write-Host ("    {0,-10} {1}" -f "Endpoint",  $p.ep)
        Write-Host ("    {0,-10} TX {1,-14} RX {2}" -f "Transfer", $p.tx, $p.rx)
        Write-Host ("    {0,-10} {1}" -f "Handshake", $p.hs)
        Write-Host ""
    }
}

function Cmd-Peers {
    $peers = Get-Peers
    if ($peers.Count -eq 0) { Write-Host "No peers."; return }
    Write-Host ("{0,-22} {1,-22} {2,-20} {3}" -f "PUBLIC KEY", "ALLOWED IPS", "ENDPOINT", "TX / RX")
    foreach ($p in $peers) {
        Write-Host ("{0,-22} {1,-22} {2,-20} {3} / {4}" -f `
            ($p.key.Substring(0, [Math]::Min(20, $p.key.Length)) + "…"),
            $p.allowed.Substring(0, [Math]::Min(20, $p.allowed.Length)),
            $p.ep, $p.tx, $p.rx)
    }
}

function Cmd-Logs {
    if (Test-Path $LOG_PATH) { Get-Content $LOG_PATH -Tail 40 }
    else { Write-Host "No heartbeat log found at $LOG_PATH" }
}

function Cmd-Version {
    Write-Host "wg0 — wg0 status CLI (Windows)"
    Write-Host ("Node ID: {0}" -f (Get-NodeId))
    Write-Host "OS:      Windows"
}

# ── Main ──────────────────────────────────────────────────────────────────────
switch ($Command.ToLower()) {
    "status"  { Cmd-Status }
    "peers"   { Cmd-Peers }
    "logs"    { Cmd-Logs }
    "version" { Cmd-Version }
    default   { Write-Host "Usage: wg0-status.ps1 [status [--json] | peers | logs | version]" }
}
