# Runs the built Ambient on the CI runner against the mock publik, asks it one thing through its ambient:// link,
# and keeps the evidence: a screenshot of the desktop and Ambient's own log. Fails unless the turn finished.
param([Parameter(Mandatory = $true)][string]$AmbientExecutable, [Parameter(Mandatory = $true)][string]$EvidenceDirectory)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null

$env:PUBLIK_ORIGIN = "http://127.0.0.1:4555"
$env:PUBLIK_API_BASE_URL = "http://127.0.0.1:4555/api/v1"
# Built at run time so no key-shaped text sits in the repository; the mock accepts anything.
$env:PUBLIK_API_KEY = "pk_" + "ci_mock"
$env:DO_NOT_TRACK = "1"
$env:AMBIENT_DATA_DIR = Join-Path $EvidenceDirectory "data"
# Ambient hides its windows from screen capture; the screenshot below needs to see them.
$env:AMBIENT_SHOW_WINDOWS_IN_CAPTURES = "1"

$mock = Start-Process node -ArgumentList "$PSScriptRoot\mock-publik.mjs" -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $EvidenceDirectory "mock-publik.log")
Start-Sleep -Seconds 2
$ambient = Start-Process $AmbientExecutable -ArgumentList "ambient://ask?text=Say%20where%20you%20are%20running" -PassThru
Start-Sleep -Seconds 25

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bitmap = New-Object System.Drawing.Bitmap $screen.Width, $screen.Height
[System.Drawing.Graphics]::FromImage($bitmap).CopyFromScreen($screen.Left, $screen.Top, 0, 0, $bitmap.Size)
$bitmap.Save((Join-Path $EvidenceDirectory "desktop.png"))

$isStillRunning = -not $ambient.HasExited
if ($isStillRunning) { Stop-Process -Id $ambient.Id -Force }
Stop-Process -Id $mock.Id -Force -ErrorAction SilentlyContinue

$logPath = Join-Path $env:AMBIENT_DATA_DIR "ambient.log"
if (Test-Path $logPath) { Get-Content $logPath } else { Write-Host "Ambient wrote no log." }
if (-not $isStillRunning) { throw "Ambient exited on its own during the smoke run." }
if (-not (Select-String -Path $logPath -Pattern "state: Finished" -Quiet)) { throw "The turn did not finish." }
Write-Host "Smoke run passed: Ambient stayed up and finished the turn."
