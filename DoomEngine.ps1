<#
.SYNOPSIS
    Doom-Style Procedural 3D Raycasting Engine for PowerShell
.DESCRIPTION
    Fully functional Wolfenstein 3D-style engine. 
    Features: DDA Raycasting, A* Pathfinding, Line of Sight, Multi-floor, Win32 Input, Mouse Look.
.PARAMETER Debug
    Keeps the console window open on crash to display errors.
.PARAMETER Width
    Console buffer width (default 100).
.PARAMETER Height
    Console buffer height (default 50).
#>

param(
    [switch]$Debug,
    [int]$Width = 100,
    [int]$Height = 50
)

# Global State
$Global:GameState = @{
    Running = $true
    PlayerX = 20.5
    PlayerY = 20.5
    PlayerZ = 0
    DirX = -1.0
    DirY = 0.0
    PlaneX = 0.0
    PlaneY = 0.66
    Health = 100
    Score = 0
    Frame = 0
    WeaponAnim = 0
}

$Global:Enemies = New-Object System.Collections.Generic.List[object]
$Global:Map = $null
$Global:MaxFloors = 5
$Global:MapWidth = 40
$Global:MapHeight = 40

# ==============================================================================
# 1. WIN32 API & TYPE LOADING (Robust Implementation)
# ==============================================================================
$Script:Win32Loaded = $false

function Initialize-Win32Types {
    if ($Script:Win32Loaded) { return }

    try {
        # Define Structs
        $TypeDef = @"
using System;
using System.Runtime.InteropServices;

namespace Native {
    [StructLayout(LayoutKind.Explicit)]
    public struct INPUT_RECORD {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
        [FieldOffset(4)] public MOUSE_EVENT_RECORD MouseEvent;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEY_EVENT_RECORD {
        public bool bKeyDown;
        public ushort wRepeatCount;
        public ushort wVirtualKeyCode;
        public ushort wVirtualScanCode;
        public char uChar;
        public uint dwControlKeyState;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSE_EVENT_RECORD {
        public int dwMousePosition_X;
        public int dwMousePosition_Y;
        public uint dwButtonState;
        public uint dwControlKeyState;
        public uint dwEventFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct CONSOLE_CURSOR_INFO {
        public uint dwSize;
        public bool bVisible;
    }

    public static class Constants {
        public const int STD_INPUT_HANDLE = -10;
        public const int STD_OUTPUT_HANDLE = -11;
        public const int ENABLE_MOUSE_INPUT = 0x0010;
        public const int ENABLE_EXTENDED_FLAGS = 0x0080;
        public const int ENABLE_WINDOW_INPUT = 0x0008;
        public const int ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200;
        public const int ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;
        public const int KEY_EVENT = 0x0001;
        public const int MOUSE_EVENT = 0x0002;
    }
}
"@
        Add-Type -TypeDefinition $TypeDef -Namespace Native -PassThru | Out-Null

        # Define P/Invoke Class
        $Kernel32Def = @"
using System;
using System.Runtime.InteropServices;
using Native;

public static class Win32Kernel {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);
    
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetConsoleMode(IntPtr hConsoleOutput, ref uint lpMode);
    
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleMode(IntPtr hConsoleOutput, uint dwMode);
    
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleCursorPosition(IntPtr hConsoleOutput, int dwCursorPosition);
    
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleCursorInfo(IntPtr hConsoleOutput, ref CONSOLE_CURSOR_INFO lpConsoleCursorInfo);
    
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ReadConsoleInput(IntPtr hConsoleInput, [Out] INPUT_RECORD[] lpBuffer, uint nLength, ref uint lpNumberOfEventsRead);
    
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);
}
"@
        Add-Type -TypeDefinition $Kernel32Def -ReferencedAssemblies "System.Runtime.InteropServices" -PassThru | Out-Null
        
        $Script:Win32Loaded = $true
        return $true
    }
    catch {
        Write-Host "CRITICAL: Failed to load Win32 Types. Ensure you are running Windows PowerShell or PWSh on Windows." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        if (-not $Debug) { Start-Sleep -Seconds 5 }
        exit 1
    }
}

# Initialize Types Immediately
Initialize-Win32Types

# Handles
$STD_INPUT = [Win32Kernel]::GetStdHandle([Native.Constants]::STD_INPUT_HANDLE)
$STD_OUTPUT = [Win32Kernel]::GetStdHandle([Native.Constants]::STD_OUTPUT_HANDLE)

# Setup Modes
$modeIn = 0
[Win32Kernel]::GetConsoleMode($STD_INPUT, [ref]$modeIn)
[Win32Kernel]::SetConsoleMode($STD_INPUT, ($modeIn -bor [Native.Constants]::ENABLE_MOUSE_INPUT -bor [Native.Constants]::ENABLE_EXTENDED_FLAGS -bor [Native.Constants]::ENABLE_VIRTUAL_TERMINAL_INPUT))

$modeOut = 0
[Win32Kernel]::GetConsoleMode($STD_OUTPUT, [ref]$modeOut)
[Win32Kernel]::SetConsoleMode($STD_OUTPUT, ($modeOut -bor [Native.Constants]::ENABLE_VIRTUAL_TERMINAL_PROCESSING))

# Hide Cursor
$cursorInfo = New-Object Native.CONSOLE_CURSOR_INFO
$cursorInfo.dwSize = 1
$cursorInfo.bVisible = $false
[Win32Kernel]::SetConsoleCursorInfo($STD_OUTPUT, [ref]$cursorInfo)

# Resize Buffer
try {
    $Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($Width, $Height + 5)
    $Host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size($Width, $Height)
    $Host.UI.RawUI.CursorPosition = New-Object System.Management.Automation.Host.Coordinates(0,0)
} catch { }

# Keys
$VK_W = 0x57; $VK_S = 0x53; $VK_A = 0x41; $VK_D = 0x44
$VK_Q = 0x51; $VK_E = 0x45; $VK_SPACE = 0x20
$VK_PGUP = 0x21; $VK_PGDN = 0x22; $VK_ESC = 0x1B
$VK_SHIFT = 0x10

# ==============================================================================
# 2. MAP GENERATION (Cellular Automata)
# ==============================================================================
function Initialize-Map {
    $global:Map = New-Object 'int[,,]' ($Global:MapWidth, $Global:MapHeight, $Global:MaxFloors)
    
    for ($z = 0; $z -lt $Global:MaxFloors; $z++) {
        # Noise
        for ($x = 0; $x -lt $Global:MapWidth; $x++) {
            for ($y = 0; $y -lt $Global:MapHeight; $y++) {
                if ($x -eq 0 -or $x -eq $Global:MapWidth-1 -or $y -eq 0 -or $y -eq $Global:MapHeight-1) {
                    $global:Map[$x,$y,$z] = 1
                } else {
                    if ((Get-Random) % 10 -lt 4) { $global:Map[$x,$y,$z] = 1 } else { $global:Map[$x,$y,$z] = 0 }
                }
            }
        }

        # Smooth (4 passes)
        for ($i = 0; $i -lt 4; $i++) {
            $newMap = $global:Map.Clone()
            for ($x = 1; $x -lt $Global:MapWidth-1; $x++) {
                for ($y = 1; $y -lt $Global:MapHeight-1; $y++) {
                    $neighbors = 0
                    for ($dx = -1; $dx -le 1; $dx++) {
                        for ($dy = -1; $dy -le 1; $dy++) {
                            if ($dx -eq 0 -and $dy -eq 0) { continue }
                            if ($global:Map[$x+$dx, $y+$dy, $z] -eq 1) { $neighbors++ }
                        }
                    }
                    if ($neighbors -gt 4) { $newMap[$x,$y,$z] = 1 }
                    elseif ($neighbors -lt 4) { $newMap[$x,$y,$z] = 0 }
                }
            }
            $global:Map = $newMap
        }

        # Clear Start Area
        if ($z -eq 0) {
            for ($dx = -2; $dx -le 2; $dx++) {
                for ($dy = -2; $dy -le 2; $dy++) {
                    $gx = 20 + $dx
                    $gy = 20 + $dy
                    if ($gx -gt 0 -and $gx -lt $Global:MapWidth-1 -and $gy -gt 0 -and $gy -lt $Global:MapHeight-1) {
                        $global:Map[$gx, $gy, 0] = 0
                    }
                }
            }
        }

        # Stairs
        if ($z -lt $Global:MaxFloors - 1) {
            $found = $false
            $attempts = 0
            while (-not $found -and $attempts -lt 100) {
                $attempts++
                $sx = (Get-Random) % ($Global:MapWidth - 4) + 2
                $sy = (Get-Random) % ($Global:MapHeight - 4) + 2
                if ($global:Map[$sx, $sy, $z] -eq 0) {
                    $global:Map[$sx, $sy, $z] = 2 # Up
                    $global:Map[$sx, $sy, $z+1] = 0
                    $global:Map[$sx+1, $sy, $z+1] = 0
                    $global:Map[$sx, $sy+1, $z+1] = 0
                    $global:Map[$sx+1, $sy+1, $z+1] = 0
                    $found = $true
                }
            }
        }
    }
}

# ==============================================================================
# 3. ENEMY AI CLASS (A* Pathfinding)
# ==============================================================================
class Enemy {
    [float]$X; [float]$Y; [int]$Z
    [int]$State; [float]$Health
    [System.Collections.Generic.List[string]]$Path
    [int]$LastPathFrame
    
    Enemy([float]$x, [float]$y, [int]$z) {
        $this.X = $x; $this.Y = $y; $this.Z = $z
        $this.State = 0; $this.Health = 3.0
        $this.Path = New-Object System.Collections.Generic.List[string]
        $this.LastPathFrame = 0
    }

    [bool] HasLineOfSight([float]$px, [float]$py, [int]$pz) {
        if ($this.Z -ne $pz) { return $false }
        $dx = $px - $this.X; $dy = $py - $this.Y
        $dist = [Math]::Sqrt(($dx*$dx) + ($dy*$dy))
        if ($dist -eq 0) { return $true }
        
        $steps = [int]($dist * 4)
        $sx = $dx / $steps; $sy = $dy / $steps
        $cx = $this.X; $cy = $this.Y
        
        for ($i = 0; $i -lt $steps; $i++) {
            $cx += $sx; $cy += $sy
            $mx = [int]$cx; $my = [int]$cy
            if ($mx -ge 0 -and $mx -lt $Global:MapWidth -and $my -ge 0 -and $my -lt $Global:MapHeight) {
                if ($global:Map[$mx, $my, $this.Z] -gt 0 -and $global:Map[$mx, $my, $this.Z] -lt 2) { return $false }
            }
        }
        return $true
    }

    [void] UpdateAI([float]$px, [float]$py, [int]$pz, [int]$frame) {
        $dist = [Math]::Sqrt((($this.X-$px)*($this.X-$px)) + (($this.Y-$py)*($this.Y-$py)))
        
        if ($this.State -eq 0) {
            if ($frame % 20 -eq 0 -and $this.Z -eq $pz -and $this.HasLineOfSight($px, $py, $pz) -and $dist -lt 15) {
                $this.State = 2
            }
        } elseif ($this.State -eq 2) {
            if ($frame -gt $this.LastPathFrame + 30) {
                if ($this.HasLineOfSight($px, $py, $pz)) { $this.MoveTowards($px, $py) }
                else { $this.CalculatePath([int]$this.X, [int]$this.Y, [int]$px, [int]$py, $pz); $this.LastPathFrame = $frame }
            } else {
                if ($this.Path.Count -gt 0) {
                    $target = $this.Path[0].Split(',')
                    $tx = [float]$target[0] + 0.5; $ty = [float]$target[1] + 0.5
                    $dToNode = [Math]::Sqrt((($this.X-$tx)*($this.X-$tx)) + (($this.Y-$ty)*($this.Y-$ty)))
                    if ($dToNode -lt 0.3) { $this.Path.RemoveAt(0) } else { $this.MoveTowards($tx, $ty) }
                } else {
                    if ($dist -lt 1) { $this.State = 3 } else { $this.MoveTowards($px, $py) }
                }
            }
            if ($dist -lt 1.0) { $this.State = 3 }
        } elseif ($this.State -eq 3) {
            if ($dist -gt 1.5) { $this.State = 2 }
        }
    }

    [void] MoveTowards([float]$tx, [float]$ty) {
        $dx = $tx - $this.X; $dy = $ty - $this.Y
        $len = [Math]::Sqrt(($dx*$dx) + ($dy*$dy))
        if ($len -gt 0) {
            $speed = 0.05
            $nx = $this.X + ($dx/$len)*$speed; $ny = $this.Y + ($dy/$len)*$speed
            $ix = [int]$nx; $iy = [int]$ny
            if ($ix -ge 0 -and $ix -lt $Global:MapWidth -and $iy -ge 0 -and $iy -lt $Global:MapHeight) {
                if ($global:Map[$ix, $iy, $this.Z] -eq 0 -or $global:Map[$ix, $iy, $this.Z] -ge 2) {
                    $this.X = $nx; $this.Y = $ny
                }
            }
        }
    }

    [void] CalculatePath([int]$sx, [int]$sy, [int]$ex, [int]$ey, [int]$targetZ) {
        $this.Path.Clear()
        if ($this.Z -ne $targetZ) { return }

        $openSet = New-Object System.Collections.Generic.List[string]
        $closedSet = New-Object System.Collections.Generic.HashSet[string]
        $cameFrom = @{}; $gScore = @{}; $fScore = @{}
        
        $startKey = "$sx,$sy"
        $openSet.Add($startKey) | Out-Null
        $gScore[$startKey] = 0
        $fScore[$startKey] = [Math]::Abs($sx-$ex) + [Math]::Abs($sy-$ey)
        
        $found = $false; $iterations = 0
        while ($openSet.Count -gt 0 -and $iterations -lt 200) {
            $iterations++
            $currentKey = $null; $lowestF = 999999
            foreach ($k in $openSet) {
                if ($fScore[$k] -lt $lowestF) { $lowestF = $fScore[$k]; $currentKey = $k }
            }
            if ($currentKey -eq "$ex,$ey") { $found = $true; break }
            
            $openSet.Remove($currentKey) | Out-Null
            $closedSet.Add($currentKey) | Out-Null
            
            $parts = $currentKey.Split(','); $cx = [int]$parts[0]; $cy = [int]$parts[1]
            $neighbors = @("$cx,$($cy-1)", "$cx,$($cy+1)", "$($cx-1),$cy", "$($cx+1),$cy")
            
            foreach ($nKey in $neighbors) {
                if ($closedSet.Contains($nKey)) { continue }
                $np = $nKey.Split(','); $nx = [int]$np[0]; $ny = [int]$np[1]
                if ($nx -lt 0 -or $nx -ge $Global:MapWidth -or $ny -lt 0 -or $ny -ge $Global:MapHeight) { continue }
                if ($global:Map[$nx, $ny, $this.Z] -gt 0 -and $global:Map[$nx, $ny, $this.Z] -lt 2) { continue }
                
                $tentativeG = $gScore[$currentKey] + 1
                if (-not $gScore.ContainsKey($nKey) -or $tentativeG -lt $gScore[$nKey]) {
                    $cameFrom[$nKey] = $currentKey
                    $gScore[$nKey] = $tentativeG
                    $fScore[$nKey] = $tentativeG + ([Math]::Abs($nx-$ex) + [Math]::Abs($ny-$ey))
                    if (-not $openSet.Contains($nKey)) { $openSet.Add($nKey) | Out-Null }
                }
            }
        }
        
        if ($found) {
            $curr = "$ex,$ey"; $pathList = New-Object System.Collections.Generic.Stack[string]
            while ($cameFrom.ContainsKey($curr)) { $pathList.Push($curr); $curr = $cameFrom[$curr] }
            while ($pathList.Count -gt 0) { $this.Path.Add($pathList.Pop()) }
        }
    }
}

function Spawn-Enemies {
    for ($i = 0; $i -lt 10; $i++) {
        $ex = (Get-Random) % ($Global:MapWidth - 2) + 1
        $ey = (Get-Random) % ($Global:MapHeight - 2) + 1
        $ez = (Get-Random) % $Global:MaxFloors
        if ($global:Map[$ex, $ey, $ez] -eq 0) {
            if ([Math]::Sqrt((($ex-20)*($ex-20)) + (($ey-20)*($ey-20))) -gt 5) {
                $Global:Enemies.Add((New-Object Enemy ($ex + 0.5, $ey + 0.5, $ez)))
            }
        }
    }
}

# ==============================================================================
# 4. INPUT HANDLING (Mouse + Keyboard)
# ==============================================================================
$Script:LastMouseX = -1
$Script:LastMouseY = -1

function Handle-Input {
    $events = New-Object Native.INPUT_RECORD[] 16
    $numRead = 0
    [Win32Kernel]::ReadConsoleInput($STD_INPUT, $events, 16, [ref]$numRead) | Out-Null
    
    for ($i = 0; $i -lt $numRead; $i++) {
        $ev = $events[$i]
        if ($ev.EventType -eq 1) { # Key
            if ($ev.KeyEvent.bKeyDown) {
                $key = $ev.KeyEvent.wVirtualKeyCode
                if ($key -eq $VK_Q) { Rotate(-0.1) }
                if ($key -eq $VK_E) { Rotate(0.1) }
                if ($key -eq $VK_SPACE) { Shoot() }
                if ($key -eq $VK_ESC) { $Global:GameState.Running = $false }
            }
        }
        if ($ev.EventType -eq 2) { # Mouse
            $mx = $ev.MouseEvent.dwMousePosition_X
            $my = $ev.MouseEvent.dwMousePosition_Y
            if ($Script:LastMouseX -ne -1) {
                $delta = $mx - $Script:LastMouseX
                if ([Math]::Abs($delta) -gt 0) {
                    Rotate($delta * 0.05)
                }
            }
            $Script:LastMouseX = $mx
            $Script:LastMouseY = $my
        }
    }
    
    # Movement
    $moveSpeed = 0.15; $strafeSpeed = 0.12
    $w = [bool]([Win32Kernel]::GetAsyncKeyState($VK_W) -lt 0)
    $s = [bool]([Win32Kernel]::GetAsyncKeyState($VK_S) -lt 0)
    $a = [bool]([Win32Kernel]::GetAsyncKeyState($VK_A) -lt 0)
    $d = [bool]([Win32Kernel]::GetAsyncKeyState($VK_D) -lt 0)
    
    $newX = $Global:GameState.PlayerX; $newY = $Global:GameState.PlayerY
    if ($w) { $newX += $Global:GameState.DirX*$moveSpeed; $newY += $Global:GameState.DirY*$moveSpeed }
    if ($s) { $newX -= $Global:GameState.DirX*$moveSpeed; $newY -= $Global:GameState.DirY*$moveSpeed }
    if ($a) { $newX += $Global:GameState.DirY*$strafeSpeed; $newY -= $Global:GameState.DirX*$strafeSpeed }
    if ($d) { $newX -= $Global:GameState.DirY*$strafeSpeed; $newY += $Global:GameState.DirX*$strafeSpeed }
    
    # Collision X
    $ix = [int]$newX; $iy = [int]$Global:GameState.PlayerY; $iz = $Global:GameState.PlayerZ
    if ($ix -ge 0 -and $ix -lt $Global:MapWidth -and $iy -ge 0 -and $iy -lt $Global:MapHeight) {
        if ($global:Map[$ix, $iy, $iz] -eq 0 -or $global:Map[$ix, $iy, $iz] -ge 2) { $Global:GameState.PlayerX = $newX }
    }
    # Collision Y
    $ix = [int]$Global:GameState.PlayerX; $iy = [int]$newY
    if ($ix -ge 0 -and $ix -lt $Global:MapWidth -and $iy -ge 0 -and $iy -lt $Global:MapHeight) {
        if ($global:Map[$ix, $iy, $iz] -eq 0 -or $global:Map[$ix, $iy, $iz] -ge 2) { $Global:GameState.PlayerY = $newY }
    }
    
    # Seamless Stairs
    $cx = [int]$Global:GameState.PlayerX; $cy = [int]$Global:GameState.PlayerY
    $tile = $global:Map[$cx, $cy, $iz]
    if ($tile -eq 2 -and $iz -lt $Global:MaxFloors - 1) {
        $Global:GameState.PlayerZ++
        $Global:GameState.PlayerX = $cx + 0.5; $Global:GameState.PlayerY = $cy + 0.5
    }
    
    if ([bool]([Win32Kernel]::GetAsyncKeyState($VK_PGUP) -lt 0) -and $Global:GameState.PlayerZ -lt $Global:MaxFloors - 1) { $Global:GameState.PlayerZ++ }
    if ([bool]([Win32Kernel]::GetAsyncKeyState($VK_PGDN) -lt 0) -and $Global:GameState.PlayerZ -gt 0) { $Global:GameState.PlayerZ-- }
}

function Rotate($angle) {
    $oldDirX = $Global:GameState.DirX
    $c = [Math]::Cos($angle); $s = [Math]::Sin($angle)
    $Global:GameState.DirX = ($Global:GameState.DirX * $c) - ($Global:GameState.DirY * $s)
    $Global:GameState.DirY = ($oldDirX * $s) + ($Global:GameState.DirY * $c)
    $oldPlaneX = $Global:GameState.PlaneX
    $Global:GameState.PlaneX = ($Global:GameState.PlaneX * $c) - ($Global:GameState.PlaneY * $s)
    $Global:GameState.PlaneY = ($oldPlaneX * $s) + ($Global:GameState.PlaneY * $c)
}

function Shoot() {
    $Global:GameState.WeaponAnim = 5
    foreach ($en in $Global:Enemies.ToArray()) {
        if ($en.Z -eq $Global:GameState.PlayerZ) {
            $dx = $en.X - $Global:GameState.PlayerX; $dy = $en.Y - $Global:GameState.PlayerY
            $dist = [Math]::Sqrt(($dx*$dx)+($dy*$dy))
            if ($dist -lt 10) {
                $dot = (($Global:GameState.DirX * ($dx/$dist)) + ($Global:GameState.DirY * ($dy/$dist)))
                if ($dot -gt 0.8) {
                    $en.Health--
                    if ($en.Health -le 0) { $Global:Enemies.Remove($en) | Out-Null; $Global:GameState.Score += 100 }
                    break
                }
            }
        }
    }
}

# ==============================================================================
# 5. RENDER ENGINE (DDA + Sprites)
# ==============================================================================
function Render-Frame {
    $Global:GameState.Frame++
    $screen = New-Object 'char[,]' ($Width, $Height)
    $colors = New-Object 'string[,]' ($Width, $Height)
    
    # Background
    for ($x = 0; $x -lt $Width; $x++) {
        for ($y = 0; $y -lt $Height; $y++) {
            if ($y -lt $Height/2) { $screen[$x,$y]=' '; $colors[$x,$y]='40;94' }
            else { $screen[$x,$y]='.'; $colors[$x,$y]='40;34' }
        }
    }
    
    # Rays
    for ($x = 0; $x -lt $Width; $x += 2) {
        $cameraX = (2*$x/$Width) - 1
        $rayDirX = $Global:GameState.DirX + $Global:GameState.PlaneX*$cameraX
        $rayDirY = $Global:GameState.DirY + $Global:GameState.PlaneY*$cameraX
        
        $mapX = [int]$Global:GameState.PlayerX; $mapY = [int]$Global:GameState.PlayerY
        $deltaDistX = [Math]::Abs(1/$rayDirX); $deltaDistY = [Math]::Abs(1/$rayDirY)
        
        $stepX = 0; $sideDistX = 0.0
        if ($rayDirX -lt 0) { $stepX=-1; $sideDistX=($Global:GameState.PlayerX-$mapX)*$deltaDistX }
        else { $stepX=1; $sideDistX=($mapX+1.0-$Global:GameState.PlayerX)*$deltaDistX }
        
        $stepY = 0; $sideDistY = 0.0
        if ($rayDirY -lt 0) { $stepY=-1; $sideDistY=($Global:GameState.PlayerY-$mapY)*$deltaDistY }
        else { $stepY=1; $sideDistY=($mapY+1.0-$Global:GameState.PlayerY)*$deltaDistY }
        
        $hit = 0; $side = 0; $wallType = 0
        while ($hit -eq 0) {
            if ($sideDistX -lt $sideDistY) { $sideDistX+=$deltaDistX; $mapX+=$stepX; $side=0 }
            else { $sideDistY+=$deltaDistY; $mapY+=$stepY; $side=1 }
            
            if ($mapX -lt 0 -or $mapX -ge $Global:MapWidth -or $mapY -lt 0 -or $mapY -ge $Global:MapHeight) { $hit=1; $wallType=1 }
            elseif ($global:Map[$mapX, $mapY, $Global:GameState.PlayerZ] -gt 0) { $hit=1; $wallType=$global:Map[$mapX, $mapY, $Global:GameState.PlayerZ] }
        }
        
        $perpWallDist = if ($side -eq 0) { $sideDistX-$deltaDistX } else { $sideDistY-$deltaDistY }
        if ($perpWallDist -le 0) { $perpWallDist = 0.001 }
        
        $lineHeight = [int]($Height/$perpWallDist)
        $drawStart = [int]((-($lineHeight/2) + ($Height/2))); if ($drawStart -lt 0) { $drawStart=0 }
        $drawEnd = [int](($lineHeight/2) + ($Height/2)); if ($drawEnd -ge $Height) { $drawEnd=$Height-1 }
        
        $cVal = 37; $bChar = [char]9608
        if ($wallType -eq 2) { $cVal=93; $bChar='#' }
        elseif ($side -eq 1) { $cVal=90 }
        if ($perpWallDist -gt 4) { $cVal=90; $bChar=[char]9619 }
        if ($perpWallDist -gt 8) { $cVal=30; $bChar=[char]9617 }
        if ($perpWallDist -gt 12) { $cVal=30; $bChar=' ' }
        
        for ($y = $drawStart; $y -lt $drawEnd; $y++) {
            $screen[$x,$y] = $bChar; $colors[$x,$y] = "40;${cVal}"
            $screen[$x+1,$y] = $bChar; $colors[$x+1,$y] = "40;${cVal}"
        }
    }
    
    # Sprites
    $sorted = $Global:Enemies | Sort-Object { [Math]::Sqrt((($_.X-$Global:GameState.PlayerX)*($_.X-$Global:GameState.PlayerX)) + (($_.Y-$Global:GameState.PlayerY)*($_.Y-$Global:GameState.PlayerY))) } -Descending
    foreach ($en in $sorted) {
        if ($en.Z -ne $Global:GameState.PlayerZ) { continue }
        $spriteX = $en.X - $Global:GameState.PlayerX; $spriteY = $en.Y - $Global:GameState.PlayerY
        $invDet = 1.0 / ($Global:GameState.PlaneX*$Global:GameState.DirY - $Global:GameState.DirX*$Global:GameState.PlaneY)
        $transformX = $invDet * ($Global:GameState.DirY*$spriteX - $Global:GameState.DirX*$spriteY)
        $transformY = $invDet * (-$Global:GameState.PlaneY*$spriteX + $Global:GameState.PlaneX*$spriteY)
        
        if ($transformY -le 0) { continue }
        $spriteScreenX = [int](($Width/2) * (1 + $transformX/$transformY))
        $spriteHeight = [int]([Math]::Abs($Height/$transformY))
        $drawStartY = [int]((-($spriteHeight/2) + ($Height/2))); if ($drawStartY -lt 0) { $drawStartY=0 }
        $drawEndY = [int](($spriteHeight/2) + ($Height/2)); if ($drawEndY -ge $Height) { $drawEndY=$Height-1 }
        $spriteWidth = [int]([Math]::Abs($Height/$transformY))
        $drawStartX = [int]((-($spriteWidth/2) + ($spriteScreenX/2))); $drawEndX = [int](($spriteWidth/2) + ($spriteScreenX/2))
        
        for ($stripe = $drawStartX; $stripe -lt $drawEndX; $stripe++) {
            if ($stripe -ge 0 -and $stripe -lt $Width) {
                for ($y = $drawStartY; $y -lt $drawEndY; $y++) {
                    if ($y -ge 0 -and $y -lt $Height) {
                        if ($screen[$stripe,$y] -eq ' ' -or $screen[$stripe,$y] -eq '.') {
                            $screen[$stripe,$y] = [char]9786; $colors[$stripe,$y] = "40;91"
                        }
                    }
                }
            }
        }
    }
    
    # Output
    $output = New-Object System.Text.StringBuilder
    for ($y = 0; $y -lt $Height; $y++) {
        $line = ""
        for ($x = 0; $x -lt $Width; $x++) { $line += "`e[$($colors[$x,$y])]m$($screen[$x,$y])" }
        $output.AppendLine("$line`e[0m") | Out-Null
    }
    $hud = "HP:$($Global:GameState.Health) Sc:$($Global:GameState.Score) Fl:$($Global:GameState.PlayerZ+1) | WASD Move | Mouse Look | Space Fire | ESC Quit"
    $output.Append("`e[7m${hud}`e[0m") | Out-Null
    
    [Console]::SetCursorPosition(0,0)
    [Console]::Write($output.ToString())
}

# ==============================================================================
# 6. MAIN LOOP
# ==============================================================================
Initialize-Map
Spawn-Enemies

try {
    while ($Global:GameState.Running) {
        Handle-Input
        foreach ($en in $Global:Enemies.ToArray()) {
            $en.UpdateAI($Global:GameState.PlayerX, $Global:GameState.PlayerY, $Global:GameState.PlayerZ, $Global:GameState.Frame)
            $dist = [Math]::Sqrt((($en.X-$Global:GameState.PlayerX)*($en.X-$Global:GameState.PlayerX)) + (($en.Y-$Global:GameState.PlayerY)*($en.Y-$Global:GameState.PlayerY)))
            if ($dist -lt 0.8 -and $en.State -eq 3) {
                $Global:GameState.Health -= 1
                if ($Global:GameState.Health -le 0) { $Global:GameState.Running = $false }
            }
        }
        Render-Frame
        Start-Sleep -Milliseconds 16 # ~60 FPS cap
    }
} finally {
    $cursorInfo.bVisible = $true
    [Win32Kernel]::SetConsoleCursorInfo($STD_OUTPUT, [ref]$cursorInfo)
    [Console]::Clear()
    Write-Host "Game Over! Score: $($Global:GameState.Score)" -ForegroundColor Cyan
    if (-not $Debug) { Start-Sleep -Seconds 2 }
}
