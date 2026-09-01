# status-light.ps1 - drive a physical status light from Claude Code hooks.
#
#   red    = waiting for confirmation
#   yellow = running
#   green  = finished, ready for a new task
#
# On a state CHANGE the bulb flashes the new colour a few times, so the change
# is noticeable when other lights are on. A repeat of the current state does
# nothing at all (see the cache note below).
#
# Backend: TP-Link Kasa KL125 ("office 1") over the legacy autokey-XOR
# protocol on TCP 9999. No dependencies, no cloud, no credentials.
#
# Note this is the LEGACY protocol. Newer Kasa/Tapo devices speak KLAP over
# port 80 and require TP-Link cloud credentials; they will not work here.
#
# To swap hardware, replace Send-Kasa and the two payload builders.
#
# Usage: status-light.ps1 <red|yellow|green|off>

param(
    [Parameter(Mandatory)]
    [ValidateSet('red', 'yellow', 'green', 'off')]
    [string]$State
)

# ---- configuration -------------------------------------------------------
$BulbIp     = '192.168.0.103'
$BulbPort   = 9999
$Brightness = 60          # 1-100. Lower this if the room feels flooded.
$ConnectMs  = 1000        # give up quietly if the bulb is slow or offline

$FlashCount = 3           # pulses on a state change. 0 disables flashing.
$FlashMs    = 130         # on/off duration per phase, milliseconds

# Hue/saturation per state. Set green to @{ hue = 0; sat = 0 } for warm white
# if you would rather the light stay usable as a room light when idle.
$Colors = @{
    red    = @{ hue = 0;   sat = 100 }
    yellow = @{ hue = 60;  sat = 100 }
    green  = @{ hue = 120; sat = 100 }
}

$CacheFile = Join-Path $env:TEMP 'claude-status-light.state'
# --------------------------------------------------------------------------

function ConvertTo-KasaFrame {
    param([string]$Payload)
    # TP-Link autokey XOR cipher, initial key 171, 4-byte big-endian length prefix
    $bytes = [Text.Encoding]::UTF8.GetBytes($Payload)
    $frame = New-Object byte[] ($bytes.Length + 4)
    $len = [BitConverter]::GetBytes([int]$bytes.Length)
    [Array]::Reverse($len)
    [Array]::Copy($len, 0, $frame, 0, 4)
    $key = 171
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $key = $key -bxor $bytes[$i]
        $frame[$i + 4] = $key
    }
    return $frame
}

function Invoke-KasaSequence {
    # Sends every payload over ONE connection, reading each reply before moving
    # on. Reading matters: closing the socket straight after a write races the
    # device and the last command gets dropped.
    param([string[]]$Payloads, [int[]]$DelaysMs)

    $client = New-Object Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($BulbIp, $BulbPort, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($ConnectMs)) { return $false }
        $client.EndConnect($ar)
        $stream = $client.GetStream()
        $stream.ReadTimeout = 2000

        for ($p = 0; $p -lt $Payloads.Count; $p++) {
            $frame = ConvertTo-KasaFrame -Payload $Payloads[$p]
            $stream.Write($frame, 0, $frame.Length)
            $stream.Flush()

            # drain the reply so the command is known to have landed
            $hdr = New-Object byte[] 4
            $got = 0
            while ($got -lt 4) {
                $n = $stream.Read($hdr, $got, 4 - $got)
                if ($n -le 0) { return $false }
                $got += $n
            }
            [Array]::Reverse($hdr)
            $rlen = [BitConverter]::ToInt32($hdr, 0)
            if ($rlen -gt 0 -and $rlen -lt 65536) {
                $rbuf = New-Object byte[] $rlen
                $got = 0
                while ($got -lt $rlen) {
                    $n = $stream.Read($rbuf, $got, $rlen - $got)
                    if ($n -le 0) { break }
                    $got += $n
                }
            }

            if ($null -ne $DelaysMs -and $p -lt $DelaysMs.Count -and $DelaysMs[$p] -gt 0) {
                Start-Sleep -Milliseconds $DelaysMs[$p]
            }
        }
        return $true
    }
    finally {
        $client.Close()
    }
}

function Get-ColorPayload {
    param([string]$State)
    $c = $Colors[$State]
    '{"smartlife.iot.smartbulb.lightingservice":{"transition_light_state":{' +
    '"ignore_default":1,"on_off":1,"mode":"normal",' +
    '"hue":' + $c.hue + ',"saturation":' + $c.sat + ',' +
    '"brightness":' + $Brightness + ',"color_temp":0,"transition_period":0}}}'
}

function Get-OffPayload {
    '{"smartlife.iot.smartbulb.lightingservice":{"transition_light_state":{"ignore_default":1,"on_off":0,"transition_period":0}}}'
}

try {
    # Skip everything when the light already shows this state. PreToolUse and
    # PostToolUse fire constantly, so without this the bulb would take a TCP
    # connection per tool call -- and would flash on every one of them.
    if (Test-Path $CacheFile) {
        $last = (Get-Content $CacheFile -Raw -ErrorAction SilentlyContinue)
        if ($null -ne $last -and $last.Trim() -eq $State) { exit 0 }
    }

    # Build the whole sequence up front: settle on the new colour, then pulse it.
    $payloads = New-Object System.Collections.Generic.List[string]
    $delays = New-Object System.Collections.Generic.List[int]

    if ($State -eq 'off') {
        $payloads.Add((Get-OffPayload)); $delays.Add(0)
    }
    else {
        $color = Get-ColorPayload -State $State
        $off = Get-OffPayload
        $payloads.Add($color); $delays.Add($FlashMs)
        for ($i = 0; $i -lt $FlashCount; $i++) {
            $payloads.Add($off);   $delays.Add($FlashMs)
            $payloads.Add($color); $delays.Add($(if ($i -lt ($FlashCount - 1)) { $FlashMs } else { 0 }))
        }
    }

    # Claim the state BEFORE the ~1s flash. PreToolUse and PostToolUse both ask
    # for yellow milliseconds apart; without this the second call would still
    # see a stale cache and flash on top of the first.
    $prev = $null
    if (Test-Path $CacheFile) {
        $prev = (Get-Content $CacheFile -Raw -ErrorAction SilentlyContinue)
    }
    Set-Content -Path $CacheFile -Value $State -NoNewline

    if (-not (Invoke-KasaSequence -Payloads $payloads.ToArray() -DelaysMs $delays.ToArray())) {
        # Bulb unreachable: undo the claim so the next hook retries rather than
        # believing the light is already showing this state.
        if ($null -ne $prev) { Set-Content -Path $CacheFile -Value $prev.Trim() -NoNewline }
        elseif (Test-Path $CacheFile) { Remove-Item $CacheFile -Force -ErrorAction SilentlyContinue }
    }
}
catch {
    # A status light must never break a hook.
}

exit 0
