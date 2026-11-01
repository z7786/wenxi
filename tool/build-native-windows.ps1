param(
    [string]$Go = 'go',
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64'
)
$ErrorActionPreference = 'Stop'
$projectPath = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'build-common.ps1')
$sourcePath = Join-Path $projectPath 'native\gopeed'
$binaryPath = Join-Path $projectPath 'native\bin'
if ($Architecture -eq 'arm64') { $binaryPath = Join-Path $binaryPath 'arm64' }
New-Item -ItemType Directory -Path $binaryPath -Force | Out-Null
$priorGoos = $env:GOOS
$priorArch = $env:GOARCH
$priorCgo = $env:CGO_ENABLED
$priorProxy = $env:GOPROXY
$priorToolchain = $env:GOTOOLCHAIN
try {
    $env:GOOS = 'windows'
    $env:GOARCH = if ($Architecture -eq 'arm64') { 'arm64' } else { 'amd64' }
    $env:CGO_ENABLED = '0'
    if (-not $env:GOPROXY) { $env:GOPROXY = 'https://goproxy.cn,https://goproxy.io' }
    $env:GOTOOLCHAIN = 'go1.24.7'
    Push-Location -LiteralPath $sourcePath
    try {
        Invoke-AsterLinkTool -Command $Go -Arguments @('build', '-tags', 'nosqlite', '-trimpath', '-ldflags', '-s -w -checklinkname=0 -H=windowsgui -X github.com/GopeedLab/gopeed/pkg/base.Version=1.8.1', '-o', (Join-Path $binaryPath 'asterlink_gopeed.exe'), './cmd/asterlink') -Failure 'Windows Gopeed helper build failed'
    } finally { Pop-Location }
} finally {
    $env:GOOS = $priorGoos
    $env:GOARCH = $priorArch
    $env:CGO_ENABLED = $priorCgo
    $env:GOPROXY = $priorProxy
    $env:GOTOOLCHAIN = $priorToolchain
}
