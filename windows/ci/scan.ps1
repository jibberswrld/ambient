# Scans the built app and installer with Microsoft Defender on the runner, records whether each file is
# Authenticode-signed, and fails if Defender reports any threat. Results go to the evidence folder.
param([Parameter(Mandatory = $true)][string[]]$Paths, [Parameter(Mandatory = $true)][string]$EvidenceDirectory)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null
$report = Join-Path $EvidenceDirectory "defender-scan.txt"
$defender = Join-Path $env:ProgramFiles "Windows Defender\MpCmdRun.exe"
& $defender -SignatureUpdate | Out-Null
"Defender engine: $((Get-MpComputerStatus).AMEngineVersion), signatures: $((Get-MpComputerStatus).AntivirusSignatureVersion)" | Tee-Object -FilePath $report

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
