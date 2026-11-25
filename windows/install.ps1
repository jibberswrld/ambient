# Installs Ambient for Windows. Run in PowerShell:
#   irm https://raw.githubusercontent.com/jibberswrld/ambient/main/windows/install.ps1 | iex
# A file downloaded by PowerShell carries no "downloaded from the internet" mark, so SmartScreen does not stop the
# unsigned installer the way it does when the browser downloads it. Defender still scans everything as usual.
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue" # Windows PowerShell's progress bar makes downloads many times slower.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# CI points this at a local copy of the installer it just built.
$url = $env:AMBIENT_SETUP_URL
if (-not $url) {
  # The newest release that has a Windows installer; a Mac-only release can be newer.
  $releases = Invoke-RestMethod "https://api.github.com/repos/jibberswrld/ambient/releases?per_page=20" -UseBasicParsing
  $asset = $releases | Where-Object { -not $_.prerelease } | ForEach-Object { $_.assets } |
    Where-Object { $_.name -like "*_x64-setup.exe" } | Select-Object -First 1
  if (-not $asset) { throw "No Ambient release has a Windows installer yet." }
  $url = $asset.browser_download_url
}

$setup = Join-Path $env:TEMP "Ambient-setup.exe"
Write-Host "Downloading Ambient..."
Invoke-WebRequest $url -OutFile $setup -UseBasicParsing
Write-Host "Installing..."
Start-Process $setup -ArgumentList "/S" -Wait
Remove-Item $setup -ErrorAction SilentlyContinue

$app = Join-Path $env:LOCALAPPDATA "Ambient\ambient.exe"
if (-not (Test-Path $app)) { throw "The installer finished but Ambient is not at $app." }
Write-Host "Ambient is installed. Opening it now; it is also in the Start menu."
Start-Process $app
