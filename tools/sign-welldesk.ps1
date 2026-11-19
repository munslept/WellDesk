param([Parameter(Mandatory = $true)][string]$File)

$ErrorActionPreference = 'Stop'
if (-not $env:WELLDESK_SIGN_PFX_BASE64 -or -not $env:WELLDESK_SIGN_PFX_PASSWORD) {
    Write-Host 'Code signing certificate is not configured; artifact remains unsigned.'
    exit 0
}

$tool = Get-Command signtool.exe -ErrorAction SilentlyContinue
if ($tool) {
    $signTool = $tool.Source
} else {
    $sdkBin = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $signTool = Get-ChildItem $sdkBin -Filter signtool.exe -Recurse -File |
        Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
        Sort-Object FullName -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $signTool) { throw 'signtool.exe was not found in the Windows SDK' }

$certificate = Join-Path $env:RUNNER_TEMP 'welldesk-signing.pfx'
try {
    [IO.File]::WriteAllBytes($certificate, [Convert]::FromBase64String($env:WELLDESK_SIGN_PFX_BASE64))
    & $signTool sign /fd SHA256 /f $certificate /p $env:WELLDESK_SIGN_PFX_PASSWORD /tr http://timestamp.digicert.com /td SHA256 $File
    if ($LASTEXITCODE -ne 0) { throw 'Code signing failed' }
    & $signTool verify /pa /v $File
    if ($LASTEXITCODE -ne 0) { throw 'Signature verification failed' }
} finally {
    Remove-Item -LiteralPath $certificate -Force -ErrorAction SilentlyContinue
}
