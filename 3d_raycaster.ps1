<#
.SYNOPSIS
    PS-DOOM: Hardcore Tactical Engine.
.DESCRIPTION
    A high-fidelity raycasting engine for PowerShell.
    - AI: Ray-traced Line-of-Sight, state-driven behavior, and tactical pathing.
    - Combat: Corrected ballistic raycasting for both player and AI.
    - Graphics: Z-buffered sprite occlusion and high-speed .NET buffer blitting.
    Controls: W/S (Move), A/D (Rotate), Space (Fire), R (ADS), C (Toggle Lock), ESC (Quit).
#>

# --- Engine Setup & Constants ---
$ScreenWidth = 120
$ScreenHeight = 40
$MapSize = 32
$FOV_Normal = [Math]::PI / 3.0 
$FOV_ADS = [Math]::PI / 6.0
$CurrentFOV = $FOV_Normal
$MaxDepth = 25.0

# --- Game State ---
$Global:Player = [PSCustomObject]@{
    X = 0.0; Y = 0.0; Angle = 0.0; Health = 100; Ammo = 50; Score = 0
}
$Global:IsADS = $false
$Global:InputCaptured = $true
$Global:FireTimer = 0.0
$Global:MuzzleFlash = $false

# --- Map Generation (Cellular Automata) ---
function Get-MapValue($x, $y) {
    if ($x -lt 0 -or $x -ge $MapSize -or $y -lt 0 -or $y -ge $MapSize) { return '#' }
    return $Global:Map[($y * $MapSize) + $x]
}

function Generate-ProceduralMap {
    $m = New-Object char[] ($MapSize * $MapSize)
    for ($i=0; $i -lt $m.Length; $i++) { $m[$i] = if ((Get-Random -Max 100) -lt 45) { '#' } else { '.' } }
    
    for ($step=0; $step -lt 4; $step++) {
        $copy = $m.Clone()
        for ($y=1; $y -lt $MapSize-1; $y++) {
            for ($x=1; $x -lt $MapSize-1; $x++) {
                $count = 0
                for($iy=-1; $iy -le 1; $iy++) {
                    for($ix=-1; $ix -le 1; $ix++) { if($m[($y+$iy)*$MapSize + ($x+$ix)] -eq '#') { $count++ } }
                }
                $copy[$y*$MapSize + $x] = if($count -gt 4) { '#' } else { '.' }
            }
        }
        $m = $copy
    }
    # Enforce borders
    for ($i=0; $i -lt $MapSize; $i++) { $m[$i] = '#'; $m[($MapSize-1)*$MapSize + $i] = '#'; $m[$i*$MapSize] = '#'; $m[$i*$MapSize + ($MapSize-1)] = '#' }
    return $m
}

$Global:Map = Generate-ProceduralMap

# --- Entity AI Logic ---
function Test-LineOfSight($x1, $y1, $x2, $y2) {
    $dx = $x2 - $x1; $dy = $y2 - $y1
    $dist = [Math]::Sqrt($dx*$dx + $dy*$dy)
    $step = 0.2
    for ($d=0.2; $d -lt $dist; $d += $step) {
        $tx = [int]($x1 + ($dx/$dist)*$d); $ty = [int]($y1 + ($dy/$dist)*$d)
        if (Get-MapValue $tx $ty -eq '#') { return $false }
    }
    return $true
}

$Global:Enemies = @()
for ($i=0; $i -lt 8; $i++) {
    $ex, $ey = 0, 0
    do { $ex = Get-Random -Min 2 -Max ($MapSize-2); $ey = Get-Random -Min 2 -Max ($MapSize-2) } while (Get-MapValue $ex $ey -eq '#')
    $Global:Enemies += [PSCustomObject]@{
        X = [double]$ex; Y = [double]$ey; Health = 2; Active = $true
        State = "WANDER"; Angle = [double](Get-Random -Max 360); Cooldown = 0.0
    }
}

# --- Player Placement ---
do { $Global:Player.X = Get-Random -Min 2 -Max ($MapSize-2); $Global:Player.Y = Get-Random -Min 2 -Max ($MapSize-2) } while (Get-MapValue $Global:Player.X $Global:Player.Y -eq '#')

# --- Renderer Hardware Setup ---
[Console]::CursorVisible = $false
[Console]::Clear()
$Buffer = New-Object char[] ($ScreenWidth * $ScreenHeight)
$ZBuffer = New-Object double[] ($ScreenWidth)
$Shades = @('█', '▓', '▒', '░', ' ')

# --- Core Loop ---
$Running = $true
$LastTick = [DateTime]::Now

while ($Running -and $Global:Player.Health -gt 0) {
    $Now = [DateTime]::Now
    $dt = ($Now - $LastTick).TotalSeconds
    $LastTick = $Now
    if ($dt -eq 0) { $dt = 0.01 }

    # 1. Physical Input
    if ([Console]::KeyAvailable) {
        $k = [Console]::ReadKey($true).Key
        if ($Global:InputCaptured) {
            $rs = ($Global:IsADS ? 1.8 : 3.8) * $dt
            $ms = ($Global:IsADS ? 3.5 : 7.5) * $dt
            switch ($k) {
                'A' { $Global:Player.Angle -= $rs }
                'D' { $Global:Player.Angle += $rs }
                'W' { 
                    $nx = $Global:Player.X + [Math]::Cos($Global:Player.Angle) * $ms
                    $ny = $Global:Player.Y + [Math]::Sin($Global:Player.Angle) * $ms
                    if (Get-MapValue [int]$nx [int]$ny -ne '#') { $Global:Player.X = $nx; $Global:Player.Y = $ny }
                }
                'S' { 
                    $nx = $Global:Player.X - [Math]::Cos($Global:Player.Angle) * $ms
                    $ny = $Global:Player.Y - [Math]::Sin($Global:Player.Angle) * $ms
                    if (Get-MapValue [int]$nx [int]$ny -ne '#') { $Global:Player.X = $nx; $Global:Player.Y = $ny }
                }
                'R' { $Global:IsADS = -not $Global:IsADS; $CurrentFOV = if($Global:IsADS){$FOV_ADS}else{$FOV_Normal} }
                'C' { $Global:InputCaptured = $false; [Console]::Clear(); Write-Host "PAUSED. Any key to resume." -F Yellow; [void][Console]::ReadKey($true); $Global:InputCaptured = $true; [Console]::Clear() }
                'Spacebar' { 
                    if ($Global:Player.Ammo -gt 0) {
                        $Global:Player.Ammo--; $Global:FireTimer = 0.12; $Global:MuzzleFlash = $true
                        foreach ($e in $Global:Enemies) {
                            if (-not $e.Active) { continue }
                            $vx = $e.X - $Global:Player.X; $vy = $e.Y - $Global:Player.Y
                            $d = [Math]::Sqrt($vx*$vx + $vy*$vy)
                            $ang = [Math]::Atan2($vy, $vx) - $Global:Player.Angle
                            while($ang -lt -[Math]::PI){$ang += 2*[Math]::PI}; while($ang -gt [Math]::PI){$ang -= 2*[Math]::PI}
                            if ([Math]::Abs($ang) -lt ($Global:IsADS ? 0.06 : 0.15) -and (Test-LineOfSight $Global:Player.X $Global:Player.Y $e.X $e.Y)) {
                                $e.Health--; if($e.Health -le 0){$e.Active = $false; $Global:Player.Score += 250}
                            }
                        }
                    }
                }
                'Escape' { $Running = $false }
            }
        }
    }

    # 2. Advanced FSM AI Logic
    foreach ($e in $Global:Enemies) {
        if (-not $e.Active) { continue }
        $dist = [Math]::Sqrt(($e.X-$Global:Player.X)*($e.X-$Global:Player.X) + ($e.Y-$Global:Player.Y)*($e.Y-$Global:Player.Y))
        
        $hasLoS = Test-LineOfSight $e.X $e.Y $Global:Player.X $Global:Player.Y

        if ($hasLoS -and $dist -lt 15.0) {
            $e.State = "COMBAT"
            # Move into range
            if ($dist -gt 5.0) {
                $e.X += ($Global:Player.X - $e.X) / $dist * 2.5 * $dt
                $e.Y += ($Global:Player.Y - $e.Y) / $dist * 2.5 * $dt
            }
            # Shooting logic
            $e.Cooldown -= $dt
            if ($e.Cooldown -le 0 -and $dist -lt 12.0) {
                $Global:Player.Health -= 8
                $e.Cooldown = 1.8 
            }
        } else {
            $e.State = "WANDER"
            $e.X += [Math]::Cos($e.Angle) * 1.5 * $dt
            $e.Y += [Math]::Sin($e.Angle) * 1.5 * $dt
            if (Get-MapValue [int]$e.X [int]$e.Y -eq '#') { $e.Angle += [Math]::PI / 2 }
        }
    }

    # 3. Raycasting Pipeline
    for ($x = 0; $x -lt $ScreenWidth; $x++) {
        $RayA = ($Global:Player.Angle - $CurrentFOV/2) + ($x/$ScreenWidth)*$CurrentFOV
        $RayX = [Math]::Cos($RayA); $RayY = [Math]::Sin($RayA)
        $d = 0.0; $hit = $false
        while (-not $hit -and $d -lt $MaxDepth) {
            $d += 0.1
            if (Get-MapValue [int]($Global:Player.X + $RayX*$d) [int]($Global:Player.Y + $RayY*$d) -eq '#') { $hit = $true }
        }
        $z = $d * [Math]::Cos($RayA - $Global:Player.Angle)
        $ZBuffer[$x] = $z
        $h = [int]($ScreenHeight / $z)
        $ceil = [int]($ScreenHeight/2 - $h/2)
        $floor = [int]($ScreenHeight/2 + $h/2)
        
        for ($y=0; $y -lt $ScreenHeight; $y++) {
            $idx = $y*$ScreenWidth + $x
            if ($y -lt $ceil) { $Buffer[$idx] = ' ' }
            elseif ($y -lt $floor) { $Buffer[$idx] = $Shades[[int]([Math]::Min(4, ($d/$MaxDepth)*4))] }
            else { $Buffer[$idx] = '·' }
        }
    }

    # 4. Entity Rendering (Z-Sorted)
    foreach ($e in $Global:Enemies) {
        if (-not $e.Active) { continue }
        $vx = $e.X - $Global:Player.X; $vy = $e.Y - $Global:Player.Y
        $edist = [Math]::Sqrt($vx*$vx + $vy*$vy)
        $eang = [Math]::Atan2($vy, $vx) - $Global:Player.Angle
        while($eang -lt -[Math]::PI){$eang += 2*[Math]::PI}; while($eang -gt [Math]::PI){$eang -= 2*[Math]::PI}
        
        if ([Math]::Abs($eang) -lt $CurrentFOV) {
            $sx = [int](($ScreenWidth/2) * (1 + $eang/($CurrentFOV/2)))
            $sh = [int]($ScreenHeight / $edist)
            for ($ix=$sx-($sh/4); $ix -lt $sx+($sh/4); $ix++) {
                if ($ix -ge 0 -and $ix -lt $ScreenWidth -and $ZBuffer[$ix] -gt $edist) {
                    for ($iy=$ScreenHeight/2-$sh/2; $iy -lt $ScreenHeight/2+$sh/2; $iy++) {
                        if ($iy -ge 0 -and $iy -lt $ScreenHeight) { $Buffer[[int]$iy*$ScreenWidth + [int]$ix] = 'H' }
                    }
                }
            }
        }
    }

    # 5. Weapon FX & HUD Overlay
    $mid = $ScreenWidth/2
    if ($Global:FireTimer -gt 0) { 
        $Global:FireTimer -= $dt
        $Buffer[($ScreenHeight/2)*$ScreenWidth + $mid] = '*' 
    } else {
        if ($Global:IsADS) {
            $Buffer[($ScreenHeight/2)*$ScreenWidth + $mid] = 'O'
        } else {
            $Buffer[($ScreenHeight/2)*$ScreenWidth + $mid] = '+'
        }
    }

    # 6. Atomic Write to Terminal
    [Console]::SetCursorPosition(0,0)
    [Console]::Write($Buffer, 0, $Buffer.Length)
    $hud = " [HEALTH: $($Global:Player.Health)%] [AMMO: $($Global:Player.Ammo)] [SCORE: $($Global:Player.Score)] [MODE: $(if($Global:IsADS){'ADS'}else{'HIP'})] "
    [Console]::SetCursorPosition(0, $ScreenHeight); Write-Host $hud -ForegroundColor Cyan -NoNewline
}

[Console]::Clear()
Write-Host " GAME OVER. SCORE: $($Global:Player.Score) " -ForegroundColor Red
[Console]::CursorVisible = $true
