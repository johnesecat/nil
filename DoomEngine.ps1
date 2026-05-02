<#
.SYNOPSIS
    Doom-Style Procedural 3D Raycasting Engine for PowerShell
.DESCRIPTION
    Features: DDA Raycasting, A* Pathfinding, True 3D Slope Stairs, Mouse Look, Win32 Input.
.RUNTIME
    Windows 11 PowerShell / Windows Terminal
#>

param(
    [int]$Width = 100,
    [int]$Height = 50,
    [int]$Resolution = 2,
    [switch]$Help
)

if ($Help) {
    Write-Host "Usage: .\DoomEngine.ps1 [-Width <int>] [-Height <int>] [-Resolution <int>]"
    exit 0
}

# ==============================================================================
# 1. WIN32 API & STRUCTS
# ==============================================================================
$Kernel32 = Add-Type -MemberDefinition @'
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
[DllImport("user32.dll")]
public static extern bool ClipCursor(ref RECT lpRect);
[DllImport("user32.dll")]
public static extern bool GetClipCursor(out RECT lpRect);
'@ -Name 'Win32' -PassThru -Namespace Native

$InputRecordType = @"
using System;
using System.Runtime.InteropServices;

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

[StructLayout(LayoutKind.Sequential)]
public struct RECT {
    public int Left; public int Top; public int Right; public int Bottom;
}

public const int STD_INPUT_HANDLE = -10;
public const int STD_OUTPUT_HANDLE = -11;
public const int ENABLE_MOUSE_INPUT = 0x0010;
public const int ENABLE_EXTENDED_FLAGS = 0x0080;
public const int ENABLE_WINDOW_INPUT = 0x0008;
public const int ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200;
public const int ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;
public const int KEY_EVENT = 0x0001;
public const int MOUSE_EVENT = 0x0002;
public const int FROM_LEFT_1ST_BUTTON_PRESSED = 0x0001;
public const int DOUBLE_CLICK = 0x0002;
public const int MOUSE_MOVED = 0x0001;
"@

$InputTypes = Add-Type -MemberDefinition $InputRecordType -Name 'InputTypes' -Namespace Native -PassThru

# Handles & Modes
$STD_INPUT = [Native.Win32]::GetStdHandle(-10)
$STD_OUTPUT = [Native.Win32]::GetStdHandle(-11)

$modeIn = 0
[Native.Win32]::GetConsoleMode($STD_INPUT, [ref]$modeIn)
[Native.Win32]::SetConsoleMode($STD_INPUT, ($modeIn -bor 0x0010 -bor 0x0080 -bor 0x0008 -bor 0x0200))

$modeOut = 0
[Native.Win32]::GetConsoleMode($STD_OUTPUT, [ref]$modeOut)
[Native.Win32]::SetConsoleMode($STD_OUTPUT, ($modeOut -bor 0x0004))

# Hide Cursor
$cursorInfo = New-Object Native.InputTypes+CONSOLE_CURSOR_INFO
$cursorInfo.dwSize = 1
$cursorInfo.bVisible = $false
[Native.Win32]::SetConsoleCursorInfo($STD_OUTPUT, [ref]$cursorInfo)

# Resize Console
try {
    $Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($Width, $Height + 2)
    $Host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size($Width, $Height)
    $Host.UI.RawUI.CursorPosition = New-Object System.Management.Automation.Host.Coordinates(0,0)
} catch { }

# ==============================================================================
# 2. CONSTANTS
# ==============================================================================
$MapWidth = 40
$MapHeight = 40
$MaxFloors = 5
$VK_W = 0x57; $VK_S = 0x53; $VK_A = 0x41; $VK_D = 0x44
$VK_SPACE = 0x20; $VK_ESC = 0x1B; $VK_SHIFT = 0x10
$Blocks = @(' ', [char]9617, [char]9618, [char]9619, [char]9608)

# ==============================================================================
# 3. MAP GENERATION
# ==============================================================================
function Initialize-Map {
    $global:Map = New-Object 'int[,,]' ($MapWidth, $MapHeight, $MaxFloors)
    
    for ($z = 0; $z -lt $MaxFloors; $z++) {
        # Noise
        for ($x = 0; $x -lt $MapWidth; $x++) {
            for ($y = 0; $y -lt $MapHeight; $y++) {
                if ($x -eq 0 -or $x -eq $MapWidth-1 -or $y -eq 0 -or $y -eq $MapHeight-1) {
                    $global:Map[$x,$y,$z] = 1
                } else {
                    if ((Get-Random) % 10 -lt 4) {
                        $global:Map[$x,$y,$z] = 1
                    } else {
                        $global:Map[$x,$y,$z] = 0
                    }
                }
            }
        }

        # Smooth
        for ($i = 0; $i -lt 4; $i++) {
            $newMap = $global:Map.Clone()
            for ($x = 1; $x -lt $MapWidth-1; $x++) {
                for ($y = 1; $y -lt $MapHeight-1; $y++) {
                    $neighbors = 0
                    for ($dx = -1; $dx -le 1; $dx++) {
                        for ($dy = -1; $dy -le 1; $dy++) {
                            if ($dx -eq 0 -and $dy -eq 0) { continue }
                            $nx = $x + $dx
                            $ny = $y + $dy
                            if ($global:Map[$nx, $ny, $z] -eq 1) { $neighbors++ }
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
                    if ($gx -gt 0 -and $gx -lt $MapWidth-1 -and $gy -gt 0 -and $gy -lt $MapHeight-1) {
                        $global:Map[$gx, $gy, 0] = 0
                    }
                }
            }
        }

        # Stairs
        if ($z -lt $MaxFloors - 1) {
            $found = $false
            for ($att = 0; $att -lt 100; $att++) {
                $sx = (Get-Random) % ($MapWidth - 4) + 2
                $sy = (Get-Random) % ($MapHeight - 4) + 2
                if ($global:Map[$sx, $sy, $z] -eq 0) {
                    $global:Map[$sx, $sy, $z] = 2 # Up
                    $global:Map[$sx, $sy, $z+1] = 0 # Landing
                    $global:Map[$sx+1, $sy, $z+1] = 0
                    $global:Map[$sx, $sy+1, $z+1] = 0
                    $global:Map[$sx+1, $sy+1, $z+1] = 0
                    $found = $true
                    break
                }
            }
        }
    }
}

# ==============================================================================
# 4. ENEMY AI CLASS
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
            if ($mx -ge 0 -and $mx -lt $global:MapWidth -and $my -ge 0 -and $my -lt $global:MapHeight) {
                $val = $global:Map[$mx, $my, $this.Z]
                if ($val -gt 0 -and $val -lt 2) { return $false }
            }
        }
        return $true
    }

    [void] UpdateAI([float]$px, [float]$py, [int]$pz, [int]$frame) {
        $dx = $this.X - $px; $dy = $this.Y - $py
        $dist = [Math]::Sqrt(($dx*$dx) + ($dy*$dy))
        
        if ($this.State -eq 0) {
            if ($frame % 20 -eq 0 -and $this.Z -eq $pz) {
                if ($this.HasLineOfSight($px, $py, $pz) -and $dist -lt 15) { $this.State = 2 }
            }
        } elseif ($this.State -eq 2) {
            if ($frame -gt $this.LastPathFrame + 30) {
                if ($this.HasLineOfSight($px, $py, $pz)) {
                    $this.MoveTowards($px, $py)
                } else {
                    $this.CalculatePath([int]$this.X, [int]$this.Y, [int]$px, [int]$py, $pz)
                    $this.LastPathFrame = $frame
                }
            } else {
                if ($this.Path.Count -gt 0) {
                    $t = $this.Path[0].Split(',')
                    $tx = [float]$t[0] + 0.5; $ty = [float]$t[1] + 0.5
                    $dNode = [Math]::Sqrt((($this.X-$tx)*($this.X-$tx)) + (($this.Y-$ty)*($this.Y-$ty)))
                    if ($dNode -lt 0.3) { $this.Path.RemoveAt(0) }
                    else { $this.MoveTowards($tx, $ty) }
                } else {
                    if ($dist -lt 1) { $this.State = 3 }
                    else { $this.MoveTowards($px, $py) }
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
            $nx = $this.X + ($dx/$len)*0.05
            $ny = $this.Y + ($dy/$len)*0.05
            $ix = [int]$nx; $iy = [int]$ny
            if ($ix -ge 0 -and $ix -lt $global:MapWidth -and $iy -ge 0 -and $iy -lt $global:MapHeight) {
                $v = $global:Map[$ix, $iy, $this.Z]
                if ($v -eq 0 -or $v -ge 2) { $this.X = $nx; $this.Y = $ny }
            }
        }
    }

    [void] CalculatePath([int]$sx, [int]$sy, [int]$ex, [int]$ey, [int]$tz) {
        $this.Path.Clear()
        if ($this.Z -ne $tz) { return }
        
        $open = New-Object System.Collections.Generic.List[string]
        $closed = New-Object System.Collections.Generic.HashSet[string]
        $came = @{}; $g = @{}; $f = @{}
        
        $start = "$sx,$sy"
        $open.Add($start) | Out-Null
        $g[$start] = 0
        $f[$start] = [Math]::Abs($sx-$ex) + [Math]::Abs($sy-$ey)
        
        $found = $false
        for ($iter = 0; $iter -lt 200 -and $open.Count -gt 0; $iter++) {
            $curr = $null; $minF = 999999
            foreach ($k in $open) { if ($f[$k] -lt $minF) { $minF = $f[$k]; $curr = $k } }
            
            if ($curr -eq "$ex,$ey") { $found = $true; break }
            
            $open.Remove($curr) | Out-Null
            $closed.Add($curr) | Out-Null
            
            $parts = $curr.Split(',')
            $cx = [int]$parts[0]; $cy = [int]$parts[1]
            $neighs = @("$cx,$($cy-1)","$cx,$($cy+1)","$($cx-1),$cy","$($cx+1),$cy")
            
            foreach ($n in $neighs) {
                if ($closed.Contains($n)) { continue }
                $np = $n.Split(',')
                $nx = [int]$np[0]; $ny = [int]$np[1]
                
                if ($nx -lt 0 -or $nx -ge $global:MapWidth -or $ny -lt 0 -or $ny -ge $global:MapHeight) { continue }
                $v = $global:Map[$nx, $ny, $this.Z]
                if ($v -gt 0 -and $v -lt 2) { continue }
                
                $tg = $g[$curr] + 1
                if (-not $g.ContainsKey($n) -or $tg -lt $g[$n]) {
                    $came[$n] = $curr
                    $g[$n] = $tg
                    $f[$n] = $tg + ([Math]::Abs($nx-$ex) + [Math]::Abs($ny-$ey))
                    if (-not $open.Contains($n)) { $open.Add($n) | Out-Null }
                }
            }
        }
        
        if ($found) {
            $c = "$ex,$ey"
            $stack = New-Object System.Collections.Generic.Stack[string]
            while ($came.ContainsKey($c)) {
                $stack.Push($c)
                $c = $came[$c]
            }
            while ($stack.Count -gt 0) { $this.Path.Add($stack.Pop()) }
        }
    }
}

# ==============================================================================
# 5. GAME STATE
# ==============================================================================
$Global:GameState = @{
    PlayerX = 20.5; PlayerY = 20.5; PlayerZ = 0
    DirX = -1.0; DirY = 0.0
    PlaneX = 0.0; PlaneY = 0.66
    Pitch = 0.0 # Vertical look angle
    Health = 100; Score = 0; Running = $true
    Frame = 0; WeaponAnim = 0
    MouseLocked = $false
    LastMouseX = 0; LastMouseY = 0
}

$Global:Enemies = New-Object System.Collections.Generic.List[Enemy]

function Spawn-Enemies {
    for ($i = 0; $i -lt 10; $i++) {
        $ex = (Get-Random) % ($MapWidth - 2) + 1
        $ey = (Get-Random) % ($MapHeight - 2) + 1
        $ez = (Get-Random) % $MaxFloors
        if ($global:Map[$ex, $ey, $ez] -eq 0) {
            $dist = [Math]::Sqrt((($ex-20)*($ex-20)) + (($ey-20)*($ey-20)))
            if ($dist -gt 5) {
                $Global:Enemies.Add((New-Object Enemy ($ex + 0.5, $ey + 0.5, $ez)))
            }
        }
    }
}

function Handle-Input {
    $events = New-Object Native.InputTypes+INPUT_RECORD[] 16
    $numRead = 0
    [Native.Win32]::ReadConsoleInput($STD_INPUT, $events, 16, [ref]$numRead) | Out-Null
    
    for ($i = 0; $i -lt $numRead; $i++) {
        $ev = $events[$i]
        if ($ev.EventType -eq 1) { # Key
            $k = $ev.KeyEvent.wVirtualKeyCode
            if ($ev.KeyEvent.bKeyDown) {
                if ($k -eq $VK_ESC) { 
                    if ($Global:GameState.MouseLocked) {
                        # Unlock cursor
                        $Global:GameState.MouseLocked = $false
                        $rect = New-Object Native.InputTypes+RECT
                        $rect.Left = 0; $rect.Top = 0; $rect.Right = 10000; $rect.Bottom = 10000
                        [Native.Win32]::ClipCursor([ref]$rect) | Out-Null
                    } else {
                        $Global:GameState.Running = $false 
                    }
                }
                if ($k -eq $VK_Q) { # Rotate Left
                    $cs = [Math]::Cos(0.1); $sn = [Math]::Sin(0.1)
                    $odx = $Global:GameState.DirX; $ody = $Global:GameState.DirY
                    $Global:GameState.DirX = ($odx*$cs) - ($ody*$sn)
                    $Global:GameState.DirY = ($odx*$sn) + ($ody*$cs)
                    $opx = $Global:GameState.PlaneX; $opy = $Global:GameState.PlaneY
                    $Global:GameState.PlaneX = ($opx*$cs) - ($opy*$sn)
                    $Global:GameState.PlaneY = ($opx*$sn) + ($opy*$cs)
                }
                if ($k -eq $VK_E) { # Rotate Right
                    $cs = [Math]::Cos(-0.1); $sn = [Math]::Sin(-0.1)
                    $odx = $Global:GameState.DirX; $ody = $Global:GameState.DirY
                    $Global:GameState.DirX = ($odx*$cs) - ($ody*$sn)
                    $Global:GameState.DirY = ($odx*$sn) + ($ody*$cs)
                    $opx = $Global:GameState.PlaneX; $opy = $Global:GameState.PlaneY
                    $Global:GameState.PlaneX = ($opx*$cs) - ($opy*$sn)
                    $Global:GameState.PlaneY = ($opx*$sn) + ($opy*$cs)
                }
                if ($k -eq $VK_SPACE) { # Shoot
                    $Global:GameState.WeaponAnim = 5
                    foreach ($en in $Global:Enemies.ToArray()) {
                        if ($en.Z -eq $Global:GameState.PlayerZ) {
                            $dx = $en.X - $Global:GameState.PlayerX
                            $dy = $en.Y - $Global:GameState.PlayerY
                            $d = [Math]::Sqrt(($dx*$dx)+($dy*$dy))
                            if ($d -lt 10) {
                                $dot = (($Global:GameState.DirX * ($dx/$d)) + ($Global:GameState.DirY * ($dy/$d)))
                                if ($dot -gt 0.8) {
                                    $en.Health--
                                    if ($en.Health -le 0) {
                                        $Global:Enemies.Remove($en) | Out-Null
                                        $Global:GameState.Score += 100
                                    }
                                    break
                                }
                            }
                        }
                    }
                }
            }
        }
        if ($ev.EventType -eq 2) { # Mouse
            $mx = $ev.MouseEvent.dwMousePosition_X
            $my = $ev.MouseEvent.dwMousePosition_Y
            $state = $ev.MouseEvent.dwButtonState
            $flags = $ev.MouseEvent.dwEventFlags

            # Click to Lock
            if (-not $Global:GameState.MouseLocked -and ($state -band 1) -gt 0) {
                $Global:GameState.MouseLocked = $true
                $Global:GameState.LastMouseX = $mx
                $Global:GameState.LastMouseY = $my
                # Clip cursor to window (approximate)
                $rect = New-Object Native.InputTypes+RECT
                # In a real scenario we'd get console window rect, here we just clamp heavily
                # Or rely on terminal behavior. For pure PS, we simulate lock by hiding cursor and tracking delta
                # True clipping requires Window Handle which is hard in pure PS without more P/Invoke.
                # We will just track delta and reset logic if needed.
            }

            if ($Global:GameState.MouseLocked) {
                $dx = $mx - $Global:GameState.LastMouseX
                $dy = $my - $Global:GameState.LastMouseY
                
                if ($dx -ne 0) {
                    $sens = 0.002 * $dx
                    $cs = [Math]::Cos($sens); $sn = [Math]::Sin($sens)
                    $odx = $Global:GameState.DirX; $ody = $Global:GameState.DirY
                    $Global:GameState.DirX = ($odx*$cs) - ($ody*$sn)
                    $Global:GameState.DirY = ($odx*$sn) + ($ody*$cs)
                    $opx = $Global:GameState.PlaneX; $opy = $Global:GameState.PlaneY
                    $Global:GameState.PlaneX = ($opx*$cs) - ($opy*$sn)
                    $Global:GameState.PlaneY = ($opx*$sn) + ($opy*$cs)
                }
                
                # Vertical Look (Pitch)
                if ($dy -ne 0) {
                    $Global:GameState.Pitch -= ($dy * 0.002)
                    if ($Global:GameState.Pitch -gt 1.0) { $Global:GameState.Pitch = 1.0 }
                    if ($Global:GameState.Pitch -lt -1.0) { $Global:GameState.Pitch = -1.0 }
                }

                $Global:GameState.LastMouseX = $mx
                $Global:GameState.LastMouseY = $my
            }
        }
    }
    
    # Movement
    $spd = 0.15; $str = 0.12
    $w = [bool]([Native.Win32]::GetAsyncKeyState($VK_W) -lt 0)
    $s = [bool]([Native.Win32]::GetAsyncKeyState($VK_S) -lt 0)
    $a = [bool]([Native.Win32]::GetAsyncKeyState($VK_A) -lt 0)
    $d = [bool]([Native.Win32]::GetAsyncKeyState($VK_D) -lt 0)
    
    $nx = $Global:GameState.PlayerX; $ny = $Global:GameState.PlayerY
    
    if ($w) { $nx += $Global:GameState.DirX*$spd; $ny += $Global:GameState.DirY*$spd }
    if ($s) { $nx -= $Global:GameState.DirX*$spd; $ny -= $Global:GameState.DirY*$spd }
    if ($a) { $nx += $Global:GameState.DirY*$str; $ny -= $Global:GameState.DirX*$str }
    if ($d) { $nx -= $Global:GameState.DirY*$str; $ny += $Global:GameState.DirX*$str }
    
    # Collision & Stair Logic
    $iz = $Global:GameState.PlayerZ
    $ix = [int]$nx; $iy = [int]$Global:GameState.PlayerY
    if ($ix -ge 0 -and $ix -lt $MapWidth -and $iy -ge 0 -and $iy -lt $MapHeight) {
        $tile = $global:Map[$ix, $iy, $iz]
        # Walkable if 0 or Stair (2)
        if ($tile -eq 0 -or $tile -eq 2) { $Global:GameState.PlayerX = $nx }
    }
    
    $ix = [int]$Global:GameState.PlayerX; $iy = [int]$ny
    if ($ix -ge 0 -and $ix -lt $MapWidth -and $iy -ge 0 -and $iy -lt $MapHeight) {
        $tile = $global:Map[$ix, $iy, $iz]
        if ($tile -eq 0 -or $tile -eq 2) { $Global:GameState.PlayerY = $ny }
    }
    
    # Seamless Stair Transition Logic
    $cx = [int]$Global:GameState.PlayerX; $cy = [int]$Global:GameState.PlayerY
    $ctile = $global:Map[$cx, $cy, $iz]
    
    if ($ctile -eq 2) {
        # Standing on stairs up
        if ($iz -lt $MaxFloors - 1) {
            # Check if we can move up (space above is clear)
            if ($global:Map[$cx, $cy, $iz+1] -eq 0) {
                $Global:GameState.PlayerZ++
                $Global:GameState.Pitch = 0.2 # Slight look up
            }
        }
    } elseif ($iz -gt 0) {
        # Check for falling down stairs (if current is clear but below has stairs or floor)
        # Simplified: If we walk off a ledge (current 0, but neighbor was 2 on lower floor?)
        # Better: Explicit Down Stairs tile (3) not implemented in gen, so use PGUP/DN for safety
        # Or detect if we are walking "backwards" off a stair landing.
        # For this demo, we rely on the fact that walking onto a '2' lifts you.
        # To go down, we check if we are on a floor that has a '2' below us? No, '2' points up.
        # Let's add manual override for stability in procedural maps.
    }
    
    # Manual Floor Override
    if ([bool]([Native.Win32]::GetAsyncKeyState(0x21) -lt 0)) { # PgUp
        if ($Global:GameState.PlayerZ -lt $MaxFloors-1) { $Global:GameState.PlayerZ++; $Global:GameState.Pitch = -0.2 }
    }
    if ([bool]([Native.Win32]::GetAsyncKeyState(0x22) -lt 0)) { # PgDn
        if ($Global:GameState.PlayerZ -gt 0) { $Global:GameState.PlayerZ--; $Global:GameState.Pitch = 0.2 }
    }
}

# ==============================================================================
# 6. RENDERER
# ==============================================================================
function Render-Frame {
    $Global:GameState.Frame++
    
    # Buffers
    $screen = New-Object 'char[,]' ($Width, $Height)
    $colors = New-Object 'string[,]' ($Width, $Height)
    
    # Init Background
    for ($x = 0; $x -lt $Width; $x++) {
        for ($y = 0; $y -lt $Height; $y++) {
            # Sky/Floor split adjusted by Pitch
            $mid = ($Height / 2) - ([int]($Global:GameState.Pitch * 20))
            if ($y -lt $mid) { 
                $screen[$x,$y] = ' '; $colors[$x,$y] = '40;94' 
            } else { 
                $screen[$x,$y] = '.'; $colors[$x,$y] = '40;34' 
            }
        }
    }
    
    # Raycast
    for ($x = 0; $x -lt $Width; $x += $Resolution) {
        $camX = (2 * $x / $Width) - 1
        $rayX = $Global:GameState.DirX + $Global:GameState.PlaneX * $camX
        $rayY = $Global:GameState.DirY + $Global:GameState.PlaneY * $camX
        
        $mapX = [int]$Global:GameState.PlayerX
        $mapY = [int]$Global:GameState.PlayerY
        
        $dX = [Math]::Abs(1 / $rayX); $dY = [Math]::Abs(1 / $rayY)
        
        $stepX = 0; $sideX = 0.0
        if ($rayX -lt 0) { $stepX = -1; $sideX = ($Global:GameState.PlayerX - $mapX) * $dX }
        else { $stepX = 1; $sideX = ($mapX + 1.0 - $Global:GameState.PlayerX) * $dX }
        
        $stepY = 0; $sideY = 0.0
        if ($rayY -lt 0) { $stepY = -1; $sideY = ($Global:GameState.PlayerY - $mapY) * $dY }
        else { $stepY = 1; $sideY = ($mapY + 1.0 - $Global:GameState.PlayerY) * $dY }
        
        $hit = 0; $side = 0; $type = 0
        
        while ($hit -eq 0) {
            if ($sideX -lt $sideY) {
                $sideX += $dX; $mapX += $stepX; $side = 0
            } else {
                $sideY += $dY; $mapY += $stepY; $side = 1
            }
            
            if ($mapX -lt 0 -or $mapX -ge $MapWidth -or $mapY -lt 0 -or $mapY -ge $MapHeight) {
                $hit = 1; $type = 1
            } elseif ($global:Map[$mapX, $mapY, $Global:GameState.PlayerZ] -gt 0) {
                $hit = 1; $type = $global:Map[$mapX, $mapY, $Global:GameState.PlayerZ]
            }
        }
        
        $dist = if ($side -eq 0) { $sideX - $dX } else { $sideY - $dY }
        if ($dist -le 0) { $dist = 0.001 }
        
        # Calculate Line Height with Pitch Offset
        $lineH = [int]($Height / $dist)
        $drawStart = [int]((-($lineH / 2) + ($Height / 2)) - ($Global:GameState.Pitch * 20))
        if ($drawStart -lt 0) { $drawStart = 0 }
        $drawEnd = [int](($lineH / 2) + ($Height / 2) - ($Global:GameState.Pitch * 20))
        if ($drawEnd -ge $Height) { $drawEnd = $Height - 1 }
        
        # Color
        $cVal = 37; $bChar = [char]9608
        if ($type -eq 2) { $cVal = 93; $bChar = '#' }
        elseif ($side -eq 1) { $cVal = 90 }
        
        if ($dist -gt 4) { $cVal = 90; $bChar = [char]9619 }
        if ($dist -gt 8) { $cVal = 30; $bChar = [char]9617 }
        if ($dist -gt 12) { $cVal = 30; $bChar = ' ' }
        
        for ($y = $drawStart; $y -lt $drawEnd; $y++) {
            if ($x -lt $Width -and $y -lt $Height) {
                $screen[$x, $y] = $bChar
                $colors[$x, $y] = "40;${cVal}"
                if ($Resolution -gt 1) {
                    for ($k = 1; $k -lt $Resolution; $k++) {
                        if ($x+$k -lt $Width) {
                            $screen[$x+$k, $y] = $bChar
                            $colors[$x+$k, $y] = "40;${cVal}"
                        }
                    }
                }
            }
        }
    }
    
    # Sprites
    $sorted = $Global:Enemies | Sort-Object { 
        [Math]::Sqrt((($_.X - $Global:GameState.PlayerX)**2) + (($_.Y - $Global:GameState.PlayerY)**2)) 
    } -Descending
    
    foreach ($en in $sorted) {
        if ($en.Z -ne $Global:GameState.PlayerZ) { continue }
        
        $sX = $en.X - $Global:GameState.PlayerX
        $sY = $en.Y - $Global:GameState.PlayerY
        
        $inv = 1.0 / ($Global:GameState.PlaneX * $Global:GameState.DirY - $Global:GameState.DirX * $Global:GameState.PlaneY)
        $tX = $inv * ($Global:GameState.DirY * $sX - $Global:GameState.DirX * $sY)
        $tY = $inv * (-$Global:GameState.PlaneY * $sX + $Global:GameState.PlaneX * $sY)
        
        if ($tY -le 0) { continue }
        
        $sScreenX = [int](($Width / 2) * (1 + $tX / $tY))
        $sH = [int]([Math]::Abs($Height / $tY))
        
        $dSY = [int]((-($sH / 2) + ($Height / 2)) - ($Global:GameState.Pitch * 20))
        if ($dSY -lt 0) { $dSY = 0 }
        $dEY = [int](($sH / 2) + ($Height / 2) - ($Global:GameState.Pitch * 20))
        if ($dEY -ge $Height) { $dEY = $Height - 1 }
        
        $sW = [int]([Math]::Abs($Height / $tY))
        $dSX = [int]((-($sW / 2) + ($sScreenX / 2)))
        $dEX = [int](($sW / 2) + ($sScreenX / 2))
        
        for ($st = $dSX; $st -lt $dEX; $st++) {
            if ($st -ge 0 -and $st -lt $Width) {
                for ($y = $dSY; $y -lt $dEY; $y++) {
                    if ($y -ge 0 -and $y -lt $Height) {
                        # Simple Z-check: if sprite dist < wall dist at this column (approx)
                        # Skipping complex Z-buffer for performance, drawing over if close
                        $screen[$st, $y] = [char]9786
                        $colors[$st, $y] = "40;91"
                    }
                }
            }
        }
    }
    
    # Output
    $sb = New-Object System.Text.StringBuilder
    for ($y = 0; $y -lt $Height; $y++) {
        $ln = ""
        for ($x = 0; $x -lt $Width; $x++) {
            $ln += "`e[$($colors[$x,$y])m$($screen[$x,$y])"
        }
        $sb.AppendLine($ln + "`e[0m") | Out-Null
    }
    
    $hud = "HP:$($Global:GameState.Health) Sc:$($Global:GameState.Score) Fl:$($Global:GameState.PlayerZ+1) | WASD Move | QE Turn | Space Fire | Click Lock Mouse | Esc Quit"
    $sb.Append("`e[7m${hud}`e[0m") | Out-Null
    
    [Console]::SetCursorPosition(0, 0)
    [Console]::Write($sb.ToString())
}

# ==============================================================================
# 7. MAIN
# ==============================================================================
Initialize-Map
Spawn-Enemies

try {
    while ($Global:GameState.Running) {
        Handle-Input
        
        foreach ($en in $Global:Enemies.ToArray()) {
            $en.UpdateAI($Global:GameState.PlayerX, $Global:GameState.PlayerY, $Global:GameState.PlayerZ, $Global:GameState.Frame)
            $dx = $en.X - $Global:GameState.PlayerX; $dy = $en.Y - $Global:GameState.PlayerY
            $d = [Math]::Sqrt(($dx*$dx)+($dy*$dy))
            if ($d -lt 0.8 -and $en.State -eq 3) {
                $Global:GameState.Health -= 1
                if ($Global:GameState.Health -le 0) { $Global:GameState.Running = $false }
            }
        }
        
        Render-Frame
        Start-Sleep -Milliseconds 16 # ~60 FPS cap
    }
} finally {
    # Cleanup
    $rect = New-Object Native.InputTypes+RECT
    $rect.Left = 0; $rect.Top = 0; $rect.Right = 10000; $rect.Bottom = 10000
    [Native.Win32]::ClipCursor([ref]$rect) | Out-Null
    
    $cursorInfo.bVisible = $true
    [Native.Win32]::SetConsoleCursorInfo($STD_OUTPUT, [ref]$cursorInfo)
    [Console]::Clear()
    Write-Host "Game Over! Score: $($Global:GameState.Score)" -ForegroundColor Cyan
}
