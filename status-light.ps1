# status-light.ps1 - drive a physical status light from Claude Code hooks.
#
#   red    = waiting for confirmation
#   yellow = running
#   green  = finished, ready for a new task
#
# Backend: TP-Link Kasa KL125 ("office 1") over the legacy autokey-XOR
# protocol on TCP 9999. No dependencies, no cloud, no credentials.
#
# To swap hardware, replace Set-Light. Nothing else in this file changes.
#
# Usage: status-light.ps1 <red|yellow|green|off>

param(
    [Parameter(Mandatory)]
    [ValidateSet('red', 'yellow', 'green', 'off')]
    [string]$State
)

# ---- configuration -------------------------------------------------------
$BulbIp     = '192.168.0.104'
$BulbPort   = 9999
$Brightness = 60          # 1-100. Lower this if the room feels flooded.
$ConnectMs  = 1000        # give up quietly if the bulb is slow or offline

# Hue/saturation per state. Set green to @{ hue = 0; sat = 0 } for warm white
# if you would rather the light stay usable as a room light when idle.
$Colors = @{
    red    = @{ hue = 0;   sat = 100 }
    yellow = @{ hue = 60;  sat = 100 }
    green  = @{ hue = 120; sat = 100 }
}

$CacheFile = Join-Path $env:TEMP 'claude-status-light.state'
# --------------------------------------------------------------------------

function Set-Light {
    param([string]$State)

    if ($State -eq 'off') {
        $payload = '{"smartlife.iot.smartbulb.lightingservice":{"transition_light_state":{"ignore_default":1,"on_off":0,"transition_period":0}}}'
    }
    else {
        $c = $Colors[$State]
        $payload = '{"smartlife.iot.smartbulb.lightingservice":{"transition_light_state":{' +
                   '"ignore_default":1,"on_off":1,"mode":"normal",' +
                   '"hue":' + $c.hue + ',"saturation":' + $c.sat + ',' +
                   '"brightness":' + $Brightness + ',"color_temp":0,"transition_period":0}}}'
    }

    # TP-Link autokey XOR cipher, initial key 171, 4-byte big-endian length prefix
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $enc = New-Object byte[] $bytes.Length
    $key = 171
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $key = $key -bxor $bytes[$i]
        $enc[$i] = $key
    }
    $len = [BitConverter]::GetBytes([int]$bytes.Length)
    [Array]::Reverse($len)

    $client = New-Object Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($BulbIp, $BulbPort, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($ConnectMs)) { return $false }
        $client.EndConnect($ar)
        $stream = $client.GetStream()
        $stream.Write($len, 0, 4)
        $stream.Write($enc, 0, $enc.Length)
        $stream.Flush()
        return $true
    }
    finally {
        $client.Close()
    }
}

try {
    # Skip the network entirely when the light already shows this state.
    # PostToolUse and PreToolUse fire constantly; without this the bulb would
    # take a TCP connection per tool call.
    if (Test-Path $CacheFile) {
        $last = (Get-Content $CacheFile -Raw -ErrorAction SilentlyContinue)
        if ($null -ne $last -and $last.Trim() -eq $State) { exit 0 }
    }

    if (Set-Light -State $State) {
        Set-Content -Path $CacheFile -Value $State -NoNewline
    }
    # On failure the cache is left alone so the next hook retries.
}
catch {
    # A status light must never break a hook.
}

exit 0
