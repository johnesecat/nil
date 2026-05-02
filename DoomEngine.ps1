<#
.SYNOPSIS
    Doom-Style Procedural 3D Raycasting Engine for PowerShell (PS 5.1 Compatible)
.DESCRIPTION
    Fully functional Wolfenstein 3D-style engine. 
    Features: DDA Raycasting, A* Pathfinding, Line of Sight, Multi-floor, Mouse Look, Seamless Stairs.
.PARAMETER Debug
    Keeps the window open on crash to show errors.
.PARAMETER NoColor
    Disables ANSI colors for legacy consoles.
#>

param(
    [switch]$Debug,
    [switch]$NoColor
)

# ==============================================================================
# 1. WIN32 API P/INVOKES (Direct Console & Input Control)
# ==============================================================================
# PS 5.1 Fix: Do not include 'using' statements inside MemberDefinition.
# System and Runtime.InteropServices are implicitly available.

$StructDefinition = @"
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

public const int STD_INPUT_HANDLE = -10;
public const int STD_OUTPUT_HANDLE = -11;
public const int ENABLE_MOUSE_INPUT = 0x0010;
public const int ENABLE_EXTENDED_FLAGS = 0x0080;
public const int ENABLE_WINDOW_INPUT = 0x0008;
public const int ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200;
public const int ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;
public const int KEY_EVENT = 0x0001;
public const int MOUSE_EVENT = 0x0002;
"@

try {
    $InputTypes = Add-Type -MemberDefinition $StructDefinition -Name 'InputTypes' -Namespace 'Native' -PassThru
    $Kernel32 = Add-Type -MemberDefinition @"
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
"@ -Name 'Win32' -Namespace 'Native' -PassThru -ReferencedAssemblies $InputTypes.Assembly
} catch {
    Write-Host "CRITICAL ERROR: Failed to load Win32 Types." -ForegroundColor Red
    Write-Host "Error Details: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Ensure you are running Windows PowerShell or PowerShell 7+ on Windows." -ForegroundColor Yellow
    if (-not $Debug) { Start-Sleep -Seconds 5 } else { Read-Host "Press Enter to exit" }
    exit 1
}

# Constants
$STD_INPUT = [Native.Win32]::GetStdHandle(-10)
$STD_OUTPUT = [Native.Win32]::GetStdHandle(-11)
$ENABLE_MOUSE = 0x0010
$ENABLE_EXTENDED = 0x0080
$ENABLE_WINDOW = 0x0008
$ENABLE_VT_INPUT = 0x0200
$ENABLE_VT_PROCESS = 0x0004

# Setup Console Mode
$origInputMode = 0
$origOutputMode = 0

try {
    [Native.Win32]::GetConsoleMode($STD_INPUT, [ref]$origInputMode) | Out-Null
    [Native.Win32]::SetConsoleMode($STD_INPUT, ($origInputMode -bor $ENABLE_MOUSE -bor $ENABLE_EXTENDED -bor $ENABLE_WINDOW -bor $ENABLE_VT_INPUT)) | Out-Null
    
    [Native.Win32]::GetConsoleMode($STD_OUTPUT, [ref]$origOutputMode) | Out-Null
    [Native.Win32]::SetConsoleMode($STD_OUTPUT, ($origOutputMode -bor $ENABLE_VT_PROCESS)) | Out-Null
} catch {
    # Non-fatal, might be running in ISE or redirected
}

# Hide Cursor
$cursorInfo = New-Object Native.InputTypes+CONSOLE_CURSOR_INFO
$cursorInfo.dwSize = 1
$cursorInfo.bVisible = $false
try { [Native.Win32]::SetConsoleCursorInfo($STD_OUTPUT, [ref]$cursorInfo) | Out-Null } catch {}

# Set Buffer/Window Size
$Width = 100
$Height = 50
try {
    $Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($Width, $Height + 5)
    $Host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size($Width, $Height)
    $Host.UI.RawUI.CursorPosition = New-Object System.Management.Automation.Host.Coordinates(0,0)
} catch {}

# ==============================================================================
# 2. GAME CONSTANTS & MATH HELPERS
# ==============================================================================
$MapWidth = 40
$MapHeight = 40
$MaxFloors = 5
$ViewDistance = 20.0
$FOV = [Math]::PI / 3.0
$Resolution = 2 

# Unicode Blocks
$Blocks = @(' ', [char]9617, [char]9618, [char]9619, [char]9608) 

# Keys
$VK_W = 0x57; $VK_S = 0x53; $VK_A = 0x41; $VK_D = 0x44
$VK_Q = 0x51; $VK_E = 0x45; $VK_SPACE = 0x20
$VK_UP = 0x26; $VK_DOWN = 0x28; $VK_LEFT = 0x25; $VK_RIGHT = 0x27
$VK_PGUP = 0x21; $VK_PGDN = 0x22; $VK_ESC = 0x1B
$VK_LBUTTON = 0x01

# ==============================================================================
# 3. PROCEDURAL MAP GENERATION (Cellular Automata + Stair Connection)
# ==============================================================================
function Initialize-Map {
    $global:Map = New-Object 'int[,,]' ($MapWidth, $MapHeight, $MaxFloors)
    $global:Visited = New-Object 'bool[,,]' ($MapWidth, $MapHeight, $MaxFloors)
    
    for ($z = 0; $z -lt $MaxFloors; $z++) {
        # Step 1: Random Noise
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

        # Step 2: Cellular Automata Smoothing
        for ($i = 0; $i -lt 4; $i++) {
            $newMap = $global:Map.Clone()
            for ($x = 1; $x -lt $MapWidth-1; $x++) {
                for ($y = 1; $y -lt $MapHeight-1; $y++) {
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

        # Step 3: Ensure Player Start is Clear
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

        # Step 4: Place Stairs
        if ($z -lt $MaxFloors - 1) {
            $found = $false
            $attempts = 0
            while (-not $found -and $attempts -lt 100) {
                $attempts++
                $sx = (Get-Random) % ($MapWidth - 4) + 2
                $sy = (Get-Random) % ($MapHeight - 4) + 2
                if ($global:Map[$sx, $sy, $z] -eq 0) {
                    $global:Map[$sx, $sy, $z] = 2 # Stair Up
                    $global:Map[$sx, $sy, $z+1] = 0 # Clear landing above
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
# 4. ADVANCED ENEMY AI (A* Pathfinding + Line of Sight)
# ==============================================================================
class Enemy {
    [float]$X
    [float]$Y
    [int]$Z
    [int]$State # 0: Idle, 1: Alert, 2: Chase, 3: Attack
    [float]$Health
    [System.Collections.Generic.List[string]]$Path
    [int]$LastPathFrame
    
    Enemy([float]$x, [float]$y, [int]$z) {
        $this.X = $x
        $this.Y = $y
        $this.Z = $z
        $this.State = 0
        $this.Health = 3.0
        $this.Path = New-Object System.Collections.Generic.List[string]
        $this.LastPathFrame = 0
    }

    [bool] HasLineOfSight([float]$px, [float]$py, [int]$pz) {
        if ($this.Z -ne $pz) { return $false }
        
        $dx = $px - $this.X
        $dy = $py - $this.Y
        $dist = [Math]::Sqrt(($dx * $dx) + ($dy * $dy))
        if ($dist -eq 0) { return $true }
        
        $steps = [int]($dist * 4)
        $sx = $dx / $steps
        $sy = $dy / $steps
        
        $cx = $this.X
        $cy = $this.Y
        
        for ($i = 0; $i -lt $steps; $i++) {
            $cx += $sx
            $cy += $sy
            $mx = [int]$cx
            $my = [int]$cy
            if ($mx -ge 0 -and $mx -lt $global:Map.GetLength(0) -and $my -ge 0 -and $my -lt $global:Map.GetLength(1)) {
                if ($global:Map[$mx, $my, $this.Z] -gt 0 -and $global:Map[$mx, $my, $this.Z] -lt 2) {
                    return $false
                }
            }
        }
        return $true
    }

    [void] UpdateAI([float]$px, [float]$py, [int]$pz, [int]$frame) {
        $dist = [Math]::Sqrt((($this.X - $px)*($this.X - $px)) + (($this.Y - $py)*($this.Y - $py)))
        
        if ($this.State -eq 0) {
            if ($frame % 20 -eq 0 -and $this.Z -eq $pz) {
                if ($this.HasLineOfSight($px, $py, $pz) -and $dist -lt 15) {
                    $this.State = 2
                }
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
                    $target = $this.Path[0].Split(',')
                    $tx = [float]$target[0] + 0.5
                    $ty = [float]$target[1] + 0.5
                    
                    $dToNode = [Math]::Sqrt((($this.X - $tx)*($this.X - $tx)) + (($this.Y - $ty)*($this.Y - $ty)))
                    if ($dToNode -lt 0.3) {
                        $this.Path.RemoveAt(0)
                    } else {
                        $this.MoveTowards($tx, $ty)
                    }
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
        $dx = $tx - $this.X
        $dy = $ty - $this.Y
        $len = [Math]::Sqrt(($dx*$dx) + ($dy*$dy))
        if ($len -gt 0) {
            $speed = 0.05
            $nx = $this.X + ($dx / $len) * $speed
            $ny = $this.Y + ($dy / $len) * $speed
            
            $ix = [int]$nx
            $iy = [int]$ny
            if ($ix -ge 0 -and $ix -lt $global:Map.GetLength(0) -and $iy -ge 0 -and $iy -lt $global:Map.GetLength(1)) {
                if ($global:Map[$ix, $iy, $this.Z] -eq 0 -or $global:Map[$ix, $iy, $this.Z] -ge 2) {
                    $this.X = $nx
                    $this.Y = $ny
                }
            }
        }
    }

    [void] CalculatePath([int]$sx, [int]$sy, [int]$ex, [int]$ey, [int]$targetZ) {
        $this.Path.Clear()
        if ($this.Z -ne $targetZ) { return }

        $openSet = New-Object System.Collections.Generic.List[string]
        $closedSet = New-Object System.Collections.Generic.HashSet[string]
        $cameFrom = @{}
        $gScore = @{}
        $fScore = @{}
        
        $startKey = "$sx,$sy"
        $openSet.Add($startKey) | Out-Null
        $gScore[$startKey] = 0
        $fScore[$startKey] = [Math]::Abs($sx - $ex) + [Math]::Abs($sy - $ey)
        
        $found = $false
        $iterations = 0
        
        while ($openSet.Count -gt 0 -and $iterations -lt 200) {
            $iterations++
            $currentKey = $null
            $lowestF = 999999
            foreach ($k in $openSet) {
                if ($fScore[$k] -lt $lowestF) {
                    $lowestF = $fScore[$k]
                    $currentKey = $k
                }
            }
            
            if ($currentKey -eq "$ex,$ey") { $found = $true; break }
            
            $openSet.Remove($currentKey) | Out-Null
            $closedSet.Add($currentKey) | Out-Null
            
            $parts = $currentKey.Split(',')
            $cx = [int]$parts[0]
            $cy = [int]$parts[1]
            
            $neighbors = @("$cx,$($cy-1)", "$cx,$($cy+1)", "$($cx-1),$cy", "$($cx+1),$cy")
            
            foreach ($nKey in $neighbors) {
                if ($closedSet.Contains($nKey)) { continue }
                
                $np = $nKey.Split(',')
                $nx = [int]$np[0]
                $ny = [int]$np[1]
                
                if ($nx -lt 0 -or $nx -ge $global:Map.GetLength(0) -or $ny -lt 0 -or $ny -ge $global:Map.GetLength(1)) { continue }
                if ($global:Map[$nx, $ny, $this.Z] -gt 0 -and $global:Map[$nx, $ny, $this.Z] -lt 2) { continue }
                
                $tentativeG = $gScore[$currentKey] + 1
                if (-not $gScore.ContainsKey($nKey) -or $tentativeG -lt $gScore[$nKey]) {
                    $cameFrom[$nKey] = $currentKey
                    $gScore[$nKey] = $tentativeG
                    $fScore[$nKey] = $tentativeG + ([Math]::Abs($nx - $ex) + [Math]::Abs($ny - $ey))
                    if (-not $openSet.Contains($nKey)) {
                        $openSet.Add($nKey) | Out-Null
                    }
                }
            }
        }
        
        if ($found) {
            $curr = "$ex,$ey"
            $pathList = New-Object System.Collections.Generic.Stack[string]
            while ($cameFrom.ContainsKey($curr)) {
                $pathList.Push($curr)
                $curr = $cameFrom[$curr]
            }
            while ($pathList.Count -gt 0) {
                $this.Path.Add($pathList.Pop())
            }
        }
    }
}

# ==============================================================================
# 5. GAME STATE & INPUT HANDLING
# ==============================================================================
$Global:GameState = @{
    PlayerX = 20.5
    PlayerY = 20.5
    PlayerZ = 0
    DirX = -1.0
    DirY = 0.0
    PlaneX = 0.0
    PlaneY = 0.66
    Health = 100
    Score = 0
    Running = $true
    LastTime = [DateTime]::Now.Ticks
    Frame = 0
    WeaponAnim = 0
    Shooting = $false
    OldMouseX = 0
    OldMouseY = 0
}

$Global:Enemies = New-Object System.Collections.Generic.List[Enemy]

function Spawn-Enemies {
    for ($i = 0; $i -lt 10; $i++) {
        $ex = (Get-Random) % ($MapWidth - 2) + 1
        $ey = (Get-Random) % ($MapHeight - 2) + 1
        $ez = (Get-Random) % $MaxFloors
        if ($global:Map[$ex, $ey, $ez] -eq 0) {
            if ([Math]::Sqrt((($ex-20)*($ex-20)) + (($ey-20)*($ey-20))) -gt 5) {
                $Global:Enemies.Add((New-Object Enemy ($ex + 0.5, $ey + 0.5, $ez)))
            }
        }
    }
}

function Shoot {
    $Global:GameState.Shooting = $true
    $Global:GameState.WeaponAnim = 5
    foreach ($en in $Global:Enemies.ToArray()) {
        if ($en.Z -eq $Global:GameState.PlayerZ) {
            $dx = $en.X - $Global:GameState.PlayerX
            $dy = $en.Y - $Global:GameState.PlayerY
            $dist = [Math]::Sqrt(($dx*$dx)+($dy*$dy))
            if ($dist -lt 10) {
                $dot = (($Global:GameState.DirX * ($dx/$dist)) + ($Global:GameState.DirY * ($dy/$dist)))
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

function Handle-Input {
    $events = New-Object Native.InputTypes+INPUT_RECORD[] 16
    $numRead = 0
    [Native.Win32]::ReadConsoleInput($STD_INPUT, $events, 16, [ref]$numRead) | Out-Null
    
    for ($i = 0; $i -lt $numRead; $i++) {
        $ev = $events[$i]
        
        if ($ev.EventType -eq 1) { # Key Event
            $key = $ev.KeyEvent.wVirtualKeyCode
            $down = $ev.KeyEvent.bKeyDown
            
            if ($down) {
                if ($key -eq $VK_Q) {
                    $oldDirX = $Global:GameState.DirX
                    $Global:GameState.DirX = ($Global:GameState.DirX * [Math]::Cos(0.1)) - ($Global:GameState.DirY * [Math]::Sin(0.1))
                    $Global:GameState.DirY = ($oldDirX * [Math]::Sin(0.1)) + ($Global:GameState.DirY * [Math]::Cos(0.1))
                    $oldPlaneX = $Global:GameState.PlaneX
                    $Global:GameState.PlaneX = ($Global:GameState.PlaneX * [Math]::Cos(0.1)) - ($Global:GameState.PlaneY * [Math]::Sin(0.1))
                    $Global:GameState.PlaneY = ($oldPlaneX * [Math]::Sin(0.1)) + ($Global:GameState.PlaneY * [Math]::Cos(0.1))
                }
                if ($key -eq $VK_E) {
                    $oldDirX = $Global:GameState.DirX
                    $Global:GameState.DirX = ($Global:GameState.DirX * [Math]::Cos(-0.1)) - ($Global:GameState.DirY * [Math]::Sin(-0.1))
                    $Global:GameState.DirY = ($oldDirX * [Math]::Sin(-0.1)) + ($Global:GameState.DirY * [Math]::Cos(-0.1))
                    $oldPlaneX = $Global:GameState.PlaneX
                    $Global:GameState.PlaneX = ($Global:GameState.PlaneX * [Math]::Cos(-0.1)) - ($Global:GameState.PlaneY * [Math]::Sin(-0.1))
                    $Global:GameState.PlaneY = ($oldPlaneX * [Math]::Sin(-0.1)) + ($Global:GameState.PlaneY * [Math]::Cos(-0.1))
                }
                if ($key -eq $VK_SPACE) { 
                    Shoot 
                }
                if ($key -eq $VK_ESC) {
                    $Global:GameState.Running = $false
                }
            }
        }
        
        if ($ev.EventType -eq 2) { # Mouse Event
            $mx = $ev.MouseEvent.dwMousePosition_X
            $my = $ev.MouseEvent.dwMousePosition_Y
            
            # Calculate Delta
            $dx = $mx - $Global:GameState.OldMouseX
            $dy = $my - $Global:GameState.OldMouseY
            
            $Global:GameState.OldMouseX = $mx
            $Global:GameState.OldMouseY = $my
            
            # Mouse Look (Rotate based on X delta)
            if ($dx -ne 0) {
                $sens = 0.05
                $angle = $dx * $sens
                
                $oldDirX = $Global:GameState.DirX
                $Global:GameState.DirX = ($Global:GameState.DirX * [Math]::Cos($angle)) - ($Global:GameState.DirY * [Math]::Sin($angle))
                $Global:GameState.DirY = ($oldDirX * [Math]::Sin($angle)) + ($Global:GameState.DirY * [Math]::Cos($angle))
                $oldPlaneX = $Global:GameState.PlaneX
                $Global:GameState.PlaneX = ($Global:GameState.PlaneX * [Math]::Cos($angle)) - ($Global:GameState.PlaneY * [Math]::Sin($angle))
                $Global:GameState.PlaneY = ($oldPlaneX * [Math]::Sin($angle)) + ($Global:GameState.PlaneY * [Math]::Cos($angle))
            }
            
            # Mouse Button (Shoot)
            if ($ev.MouseEvent.dwButtonState -band 1) {
                Shoot
            }
        }
    }
    
    # Continuous Movement (WASD)
    $moveSpeed = 0.15
    $strafeSpeed = 0.12
    
    $w = [bool]([Native.Win32]::GetAsyncKeyState($VK_W) -lt 0)
    $s = [bool]([Native.Win32]::GetAsyncKeyState($VK_S) -lt 0)
    $a = [bool]([Native.Win32]::GetAsyncKeyState($VK_A) -lt 0)
    $d = [bool]([Native.Win32]::GetAsyncKeyState($VK_D) -lt 0)
    
    $newX = $Global:GameState.PlayerX
    $newY = $Global:GameState.PlayerY
    
    if ($w) {
        $newX += $Global:GameState.DirX * $moveSpeed
        $newY += $Global:GameState.DirY * $moveSpeed
    }
    if ($s) {
        $newX -= $Global:GameState.DirX * $moveSpeed
        $newY -= $Global:GameState.DirY * $moveSpeed
    }
    if ($a) {
        $newX += $Global:GameState.DirY * $strafeSpeed
        $newY -= $Global:GameState.DirX * $strafeSpeed
    }
    if ($d) {
        $newX -= $Global:GameState.DirY * $strafeSpeed
        $newY += $Global:GameState.DirX * $strafeSpeed
    }
    
    # Collision Detection
    $ix = [int]$newX
    $iy = [int]$Global:GameState.PlayerY
    $iz = $Global:GameState.PlayerZ
    
    if ($ix -ge 0 -and $ix -lt $MapWidth -and $iy -ge 0 -and $iy -lt $MapHeight) {
        if ($global:Map[$ix, $iy, $iz] -eq 0 -or $global:Map[$ix, $iy, $iz] -ge 2) {
            $Global:GameState.PlayerX = $newX
        }
    }
    
    $ix = [int]$Global:GameState.PlayerX
    $iy = [int]$newY
    if ($ix -ge 0 -and $ix -lt $MapWidth -and $iy -ge 0 -and $iy -lt $MapHeight) {
        if ($global:Map[$ix, $iy, $iz] -eq 0 -or $global:Map[$ix, $iy, $iz] -ge 2) {
            $Global:GameState.PlayerY = $newY
        }
    }
    
    # Seamless Stair Logic
    $cx = [int]$Global:GameState.PlayerX
    $cy = [int]$Global:GameState.PlayerY
    
    # Check for Stair Up
    if ($global:Map[$cx, $cy, $iz] -eq 2) {
        if ($iz -lt $MaxFloors - 1) {
            # Verify space above is clear
            if ($global:Map[$cx, $cy, $iz+1] -eq 0) {
                $Global:GameState.PlayerZ++
                $Global:GameState.PlayerX = $cx + 0.5
                $Global:GameState.PlayerY = $cy + 0.5
            }
        }
    }
    
    # Manual Floor Change
    if ([bool]([Native.Win32]::GetAsyncKeyState($VK_PGUP) -lt 0)) {
         if ($Global:GameState.PlayerZ -lt $MaxFloors - 1) { 
             $Global:GameState.PlayerZ++ 
             Start-Sleep -Milliseconds 200 # Debounce
         }
    }
    if ([bool]([Native.Win32]::GetAsyncKeyState($VK_PGDN) -lt 0)) {
        if ($Global:GameState.PlayerZ -gt 0) { 
            $Global:GameState.PlayerZ-- 
            Start-Sleep -Milliseconds 200
        }
    }
}

# ==============================================================================
# 6. RAYCASTING ENGINE (DDA Algorithm)
# ==============================================================================
function Render-Frame {
    $Global:GameState.Frame++
    
    $screen = New-Object 'char[,]' ($Width, $Height)
    $colors = New-Object 'string[,]' ($Width, $Height)
    
    # Fill Background
    for ($x = 0; $x -lt $Width; $x++) {
        for ($y = 0; $y -lt $Height; $y++) {
            if ($y -lt $Height / 2) { 
                $screen[$x,$y] = ' '
                $colors[$x,$y] = '40;94'
            } else { 
                $screen[$x,$y] = '.'
                $colors[$x,$y] = '40;34'
            }
        }
    }
    
    # Cast Rays
    for ($x = 0; $x -lt $Width; $x += $Resolution) {
        $cameraX = (2 * $x / $Width) - 1
        $rayDirX = $Global:GameState.DirX + $Global:GameState.PlaneX * $cameraX
        $rayDirY = $Global:GameState.DirY + $Global:GameState.PlaneY * $cameraX
        
        $mapX = [int]$Global:GameState.PlayerX
        $mapY = [int]$Global:GameState.PlayerY
        
        $deltaDistX = [Math]::Abs(1 / $rayDirX)
        $deltaDistY = [Math]::Abs(1 / $rayDirY)
        
        $stepX = 0; $sideDistX = 0.0
        if ($rayDirX -lt 0) { $stepX = -1; $sideDistX = ($Global:GameState.PlayerX - $mapX) * $deltaDistX }
        else { $stepX = 1; $sideDistX = ($mapX + 1.0 - $Global:GameState.PlayerX) * $deltaDistX }
        
        $stepY = 0; $sideDistY = 0.0
        if ($rayDirY -lt 0) { $stepY = -1; $sideDistY = ($Global:GameState.PlayerY - $mapY) * $deltaDistY }
        else { $stepY = 1; $sideDistY = ($mapY + 1.0 - $Global:GameState.PlayerY) * $deltaDistY }
        
        $hit = 0; $side = 0; $wallType = 0
        
        while ($hit -eq 0) {
            if ($sideDistX -lt $sideDistY) { $sideDistX += $deltaDistX; $mapX += $stepX; $side = 0 }
            else { $sideDistY += $deltaDistY; $mapY += $stepY; $side = 1 }
            
            if ($mapX -lt 0 -or $mapX -ge $MapWidth -or $mapY -lt 0 -or $mapY -ge $MapHeight) { 
                $hit = 1; $wallType = 1 
            } elseif ($mapX -ge 0 -and $mapX -lt $MapWidth -and $mapY -ge 0 -and $mapY -lt $MapHeight) {
                if ($global:Map[$mapX, $mapY, $Global:GameState.PlayerZ] -gt 0) {
                    $hit = 1
                    $wallType = $global:Map[$mapX, $mapY, $Global:GameState.PlayerZ]
                }
            } else {
                $hit = 1
            }
        }
        
        $perpWallDist = if ($side -eq 0) { $sideDistX - $deltaDistX } else { $sideDistY - $deltaDistY }
        if ($perpWallDist -le 0) { $perpWallDist = 0.001 }
        
        $lineHeight = [int]($Height / $perpWallDist)
        $drawStart = [int]((-($lineHeight / 2) + ($Height / 2)))
        if ($drawStart -lt 0) { $drawStart = 0 }
        $drawEnd = [int](($lineHeight / 2) + ($Height / 2))
        if ($drawEnd -ge $Height) { $drawEnd = $Height - 1 }
        
        $cVal = 37; $bChar = [char]9608
        if ($wallType -eq 2 -or $wallType -eq 3) { $cVal = 93; $bChar = '#' }
        elseif ($side -eq 1) { $cVal = 90 }
        
        if ($perpWallDist -gt 4) { $cVal = 90; $bChar = [char]9619 }
        if ($perpWallDist -gt 8) { $cVal = 30; $bChar = [char]9617 }
        if ($perpWallDist -gt 12) { $cVal = 30; $bChar = ' ' }
        
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
    
    # Render Sprites
    $sortedEnemies = $Global:Enemies | Sort-Object { 
        [Math]::Sqrt((($_.X - $Global:GameState.PlayerX) * ($_.X - $Global:GameState.PlayerX)) + (($_.Y - $Global:GameState.PlayerY) * ($_.Y - $Global:GameState.PlayerY))) 
    } -Descending
    
    foreach ($en in $sortedEnemies) {
        if ($en.Z -ne $Global:GameState.PlayerZ) { continue }
        
        $spriteX = $en.X - $Global:GameState.PlayerX
        $spriteY = $en.Y - $Global:GameState.PlayerY
        
        $invDet = 1.0 / ($Global:GameState.PlaneX * $Global:GameState.DirY - $Global:GameState.DirX * $Global:GameState.PlaneY)
        $transformX = $invDet * ($Global:GameState.DirY * $spriteX - $Global:GameState.DirX * $spriteY)
        $transformY = $invDet * (-$Global:GameState.PlaneY * $spriteX + $Global:GameState.PlaneX * $spriteY)
        
        if ($transformY -le 0) { continue }
        
        $spriteScreenX = [int](($Width / 2) * (1 + $transformX / $transformY))
        $spriteHeight = [int]([Math]::Abs($Height / $transformY))
        
        $drawStartY = [int]((-($spriteHeight / 2) + ($Height / 2)))
        if ($drawStartY -lt 0) { $drawStartY = 0 }
        $drawEndY = [int](($spriteHeight / 2) + ($Height / 2))
        if ($drawEndY -ge $Height) { $drawEndY = $Height - 1 }
        
        $spriteWidth = [int]([Math]::Abs($Height / $transformY))
        $drawStartX = [int]((-($spriteWidth / 2) + ($spriteScreenX / 2)))
        $drawEndX = [int](($spriteWidth / 2) + ($spriteScreenX / 2))
        
        for ($stripe = $drawStartX; $stripe -lt $drawEndX; $stripe++) {
            if ($stripe -ge 0 -and $stripe -lt $Width) {
                 for ($y = $drawStartY; $y -lt $drawEndY; $y++) {
                     if ($y -ge 0 -and $y -lt $Height) {
                         if ($screen[$stripe, $y] -eq ' ' -or $screen[$stripe, $y] -eq '.') {
                             $screen[$stripe, $y] = [char]9786
                             $colors[$stripe, $y] = "40;91"
                         }
                     }
                 }
            }
        }
    }
    
    # Draw Weapon
    $wAnim = $Global:GameState.WeaponAnim
    if ($wAnim -gt 0) { $Global:GameState.WeaponAnim-- }
    
    # Output Buffer
    $output = New-Object System.Text.StringBuilder
    for ($y = 0; $y -lt $Height; $y++) {
        $line = ""
        for ($x = 0; $x -lt $Width; $x++) {
            $c = $screen[$x, $y]
            $col = $colors[$x, $y]
            $line += "`e[${col}m$c"
        }
        $line += "`e[0m`n"
        $output.Append($line) | Out-Null
    }
    
    # HUD
    $hud = "Health: $($Global:GameState.Health) | Score: $($Global:GameState.Score) | Floor: $($Global:GameState.PlayerZ + 1) | WASD=Move QE=Turn Space/Click=Fire PGUP/DN=Floors ESC=Quit"
    $output.Append("`e[7m${hud}`e[0m")
    
    [Console]::SetCursorPosition(0, 0)
    [Console]::Write($output.ToString())
}

# ==============================================================================
# 7. MAIN LOOP
# ==============================================================================
Initialize-Map
Spawn-Enemies

try {
    while ($Global:GameState.Running) {
        $now = [DateTime]::Now.Ticks
        $dt = ($now - $Global:GameState.LastTime) / 10000000.0
        $Global:GameState.LastTime = $now
        
        Handle-Input
        
        foreach ($en in $Global:Enemies.ToArray()) {
            $en.UpdateAI($Global:GameState.PlayerX, $Global:GameState.PlayerY, $Global:GameState.PlayerZ, $Global:GameState.Frame)
            
            $dist = [Math]::Sqrt((($en.X - $Global:GameState.PlayerX)*($en.X - $Global:GameState.PlayerX)) + (($en.Y - $Global:GameState.PlayerY)*($en.Y - $Global:GameState.PlayerY)))
            if ($dist -lt 0.8 -and $en.State -eq 3) {
                $Global:GameState.Health -= 1
                if ($Global:GameState.Health -le 0) {
                    $Global:GameState.Running = $false
                }
            }
        }
        
        Render-Frame
        
        Start-Sleep -Milliseconds 10
    }
} finally {
    # Reset Console
    try {
        [Native.Win32]::SetConsoleMode($STD_INPUT, $origInputMode) | Out-Null
        [Native.Win32]::SetConsoleMode($STD_OUTPUT, $origOutputMode) | Out-Null
        
        $cursorInfo.bVisible = $true
        [Native.Win32]::SetConsoleCursorInfo($STD_OUTPUT, [ref]$cursorInfo) | Out-Null
        [Console]::Clear()
    } catch {}
    
    Write-Host "Game Over! Final Score: $($Global:GameState.Score)" -ForegroundColor Cyan
    if (-not $Debug) { Start-Sleep -Seconds 3 } else { Read-Host "Press Enter to exit" }
}
