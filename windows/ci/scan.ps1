# Scans the built app and installer with Microsoft Defender on the runner, records whether each file is
# Authenticode-signed, and fails if Defender reports any threat. Results go to the evidence folder.
param([Parameter(Mandatory = $true)][string[]]$Paths, [Parameter(Mandatory = $true)][string]$EvidenceDirectory)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null
$report = Join-Path $EvidenceDirectory "defender-scan.txt"
$defender = Join-Path $env:ProgramFiles "Windows Defender\MpCmdRun.exe"
& $defender -SignatureUpdate | Out-Null
# Runners ship with Defender's live protection off. Turn it on the way a home PC has it (real-time and behaviour
# monitoring, cloud protection, automatic sample submission); it stays on for the rest of the job, so installing and
# running Ambient afterwards happens under it.
# The runner image turns it off through policy, which outranks Set-MpPreference, so clear those policies first.
"Policies before: " + ((Get-ChildItem "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.Name + " " + (($_.Property) -join ",") }) -join " ; ") | Tee-Object -FilePath $report
Remove-Item "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -Recurse -Force -ErrorAction SilentlyContinue
Set-MpPreference -DisableRealtimeMonitoring $false -DisableBehaviorMonitoring $false -DisableIOAVProtection $false -MAPSReporting Advanced -SubmitSamplesConsent SendSafeSamples
for ($i = 0; $i -lt 30 -and -not (Get-MpComputerStatus).RealTimeProtectionEnabled; $i++) { Start-Sleep -Seconds 1 }
$status = Get-MpComputerStatus
"Defender engine: $($status.AMEngineVersion), signatures: $($status.AntivirusSignatureVersion)" | Tee-Object -FilePath $report
"Real-time: $($status.RealTimeProtectionEnabled), behaviour monitoring: $($status.BehaviorMonitorEnabled), cloud: $((Get-MpPreference).MAPSReporting), mode: $($status.AMRunningMode)" | Tee-Object -FilePath $report -Append
# Without live protection the later "no detections" check would prove nothing.
if (-not ($status.RealTimeProtectionEnabled -and $status.BehaviorMonitorEnabled)) { throw "Could not turn on Defender's live protection on the runner" }

$failed = $false
foreach ($pattern in $Paths) {
  foreach ($file in Get-ChildItem -Path $pattern -File) {
    $output = & $defender -Scan -ScanType 3 -File $file.FullName -DisableRemediation 2>&1 | Out-String
    $signature = Get-AuthenticodeSignature $file.FullName
    "`n== $($file.Name) ($([math]::Round($file.Length / 1MB, 1)) MB)" | Tee-Object -FilePath $report -Append
    $info = $file.VersionInfo
    "Details: $($info.ProductName) $($info.FileVersion) | $($info.FileDescription) | $($info.CompanyName) | $($info.LegalCopyright)" | Tee-Object -FilePath $report -Append
    "Authenticode: $($signature.Status) $($signature.SignerCertificate.Subject)" | Tee-Object -FilePath $report -Append
    $output.Trim() | Tee-Object -FilePath $report -Append
    # MpCmdRun exits 2 when it finds a threat.
    if ($LASTEXITCODE -eq 2) { $failed = $true }
  }
}
if ($failed) { throw "Defender reported a threat; see defender-scan.txt" }
