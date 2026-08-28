# test_edge_click.ps1 - Native Edge GUI Automation (Strict Exact Match + Dynamic Logging)

$LogFile = "test_edge_click.log"
function Write-Log {
    param([string]$message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMsg = "$timestamp - INFO - $message"
    Write-Output $logMsg
    Add-Content -Path $LogFile -Value $logMsg
}

"" | Out-File -FilePath $LogFile -Encoding utf8
Write-Log "================ Start Native Edge GUI Automation ================"

# ---------------------------------------------------------
# Win32 API & System Assemblies
# ---------------------------------------------------------
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class Win32 {
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);

    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP   = 0x0004;
}
"@

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------
# Helper Functions
# ---------------------------------------------------------
function Get-RandomDelay {
    return Get-Random -Minimum 2 -Maximum 5
}

function Invoke-LeftClick {
    param([int]$X, [int]$Y)
    Write-Log "Clicking coordinate ($X, $Y)..."
    [Win32]::SetCursorPos($X, $Y)
    Start-Sleep -Milliseconds 150
    [Win32]::mouse_event([Win32]::MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [System.UIntPtr]::Zero)
    [Win32]::mouse_event([Win32]::MOUSEEVENTF_LEFTUP, 0, 0, 0, [System.UIntPtr]::Zero)
    
    $delay = Get-RandomDelay
    Write-Log "Random pause for ${delay}s after click..."
    Start-Sleep -Seconds $delay
}

function Send-AccountLineViaClipboard {
    param([int]$LineNumber, [string]$AccountFilePath = "account.txt")
    if (Test-Path $AccountFilePath) {
        $lines = Get-Content $AccountFilePath
        if ($lines.Count -ge $LineNumber) {
            $targetText = $lines[$LineNumber - 1].Trim()
            Write-Log "Pasting Line $LineNumber from account.txt -> [$targetText]"
            
            [System.Windows.Forms.Clipboard]::SetText($targetText)
            Start-Sleep -Milliseconds 200
            [System.Windows.Forms.SendKeys]::SendWait("^v")
            
            $delay = Get-RandomDelay
            Write-Log "Random pause for ${delay}s after typing..."
            Start-Sleep -Seconds $delay
        } else {
            Write-Log "ERROR: account.txt has fewer than $LineNumber lines."
            return $false
        }
    } else {
        Write-Log "ERROR: $AccountFilePath not found!"
        return $false
    }
    return $true
}

# ---------------------------------------------------------
# Enhanced OCR Function (Graceful Return on Fail)
# ---------------------------------------------------------
function Assert-ExactTextOnScreen {
    param(
        [string]$ExactTargetText, 
        [int]$MaxRetries = 15
    )
    
    $TargetScrotDir = Join-Path (Get-Location).Path "scrot_png"
    Write-Log "Searching for EXACT screen text: [$ExactTargetText]..."

    for ($i = 1; $i -le $MaxRetries; $i++) {
        $latestPng = Get-ChildItem -Path $TargetScrotDir -Filter "*.png" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $pngName = if ($latestPng) { $latestPng.Name } else { "No Screenshot Found" }

        $currentScreenContent = ""
        try {
            $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
            $bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
            
            $ms = New-Object System.IO.MemoryStream
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $g.Dispose()
            $bmp.Dispose()

            $tmpPath = "$PWD\temp_ocr_frame.png"
            [System.IO.File]::WriteAllBytes($tmpPath, $ms.ToArray())
            $ms.Dispose()

            $currentScreenContent = dotnet run --project .github/scripts/OcrApp/OcrApp.csproj -- $tmpPath
            Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Log "Warning: Exception during OCR capture: $_"
        }

        $cleanContent = ($currentScreenContent -split "\r?\n" | Where-Object { $_.Trim() -ne "" }) -join " | "

        Write-Log "OCR Attempt $i Raw Text: [$cleanContent]"
        Write-Log "Associated Frame Screenshot: $pngName"

        if ($currentScreenContent.Contains($ExactTargetText)) {
            Write-Log "MATCH SUCCESS! Found exact string [$ExactTargetText] on attempt ${i}!"
            return $true
        } else {
            Write-Log "MATCH FAILED on attempt ${i} for [$ExactTargetText]"
        }

        Start-Sleep -Seconds 2
    }

    Write-Log "TIMEOUT: Exact string [$ExactTargetText] not found after $MaxRetries retries."
    return $false
}

# ---------------------------------------------------------
# Background Screenshot Monitor Process
# ---------------------------------------------------------
Write-Log "Starting background screenshot job..."
$WorkspacePath = (Get-Location).Path
$TargetScrotDir = Join-Path $WorkspacePath "scrot_png"

if (-not (Test-Path $TargetScrotDir)) {
    New-Item -ItemType Directory -Path $TargetScrotDir -Force | Out-Null
}

$ScreenshotScript = [scriptblock]::Create(@"
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
    `$saveDir = "$TargetScrotDir"
    `$count = 1
    while (`$true) {
        try {
            `$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
            `$bmp = New-Object System.Drawing.Bitmap `$bounds.Width, `$bounds.Height
            `$graphics = [System.Drawing.Graphics]::FromImage(`$bmp)
            `$graphics.CopyFromScreen(`$bounds.Location, [System.Drawing.Point]::Empty, `$bounds.Size)
            
            `$filename = "shot_{0}_{1:D4}.png" -f (Get-Date -Format "yyyyMMdd_HHmmss"), `$count
            `$fullPath = Join-Path `$saveDir `$filename
            `$bmp.Save(`$fullPath, [System.Drawing.Imaging.ImageFormat]::Png)
            `$graphics.Dispose()
            `$bmp.Dispose()
            `$count++
        } catch {}
        Start-Sleep -Seconds 1
    }
"@)

$job = Start-Job -ScriptBlock $ScreenshotScript

# ---------------------------------------------------------
# Main Execution Flow - Strict Break on Failure
# ---------------------------------------------------------
try {
    Write-Log "Launching Microsoft Edge (Maximized)..."
    Start-Process "msedge.exe" -ArgumentList `
        "--start-maximized", `
        "--no-first-run", `
        "--no-default-browser-check", `
        "--disable-fre", `
        "https://signup.live.com"

    # Step 1: 输入邮箱
    if (-not (Assert-ExactTextOnScreen -ExactTargetText "Create your Microsoft account" -MaxRetries 15)) {
        throw "Step 1 Failed: 'Create your Microsoft account' target text missing."
    }
    Invoke-LeftClick -X 518 -Y 386
    Send-AccountLineViaClipboard -LineNumber 1
    # 放弃 SendKeys {ENTER}，显式点击 Next 按钮
    Invoke-LeftClick -X 516 -Y 458
    Start-Sleep -Seconds 3

    # Step 2: 输入密码
    if (-not (Assert-ExactTextOnScreen -ExactTargetText "Create your password" -MaxRetries 15)) {
        throw "Step 2 Failed: Page did NOT advance to password screen! Stopping to prevent misclick."
    }
    Invoke-LeftClick -X 516 -Y 362
    Send-AccountLineViaClipboard -LineNumber 2
    # 点击 Next 按钮
    Invoke-LeftClick -X 500 -Y 605
    Start-Sleep -Seconds 3

    # Step 3: 填写详细信息 (姓名/生日)
    if (-not (Assert-ExactTextOnScreen -ExactTargetText "Add details" -MaxRetries 15)) {
        throw "Step 3 Failed: 'Add details' screen missing."
    }
    
    # 后续 Step 3 点击逻辑...
    Write-Log "All steps executed successfully. Holding screen for 10s..."
    Start-Sleep -Seconds 10
} catch {
    Write-Log "CRITICAL ERROR DETECTED: $_"
    exit 1
} finally {
    Stop-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -ErrorAction SilentlyContinue
    Write-Log "Background screenshot job stopped."
    Write-Log "================ Automation Task Finished ================"
}
