param(
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64',
    [string]$SevenZip
)
$ErrorActionPreference = 'Stop'
if ($Architecture -eq 'arm64') {
    & (Join-Path $PSScriptRoot 'prepare-windows-arm64-media.ps1') -SevenZip $SevenZip
    return
}
$projectPath = Split-Path -Parent $PSScriptRoot
$cachePath = Join-Path $projectPath '.local\windows-dependencies'
$buildPath = Join-Path $projectPath 'build\windows\x64'
New-Item -ItemType Directory -Path $cachePath, $buildPath -Force | Out-Null
$archives = @(
    @{
        Name = 'mpv-dev-x86_64-20261108-git-8bc468896e.7z'
        SHA256 = 'a36392a8fbd989ae274a37c63d01ef6c51b6070a5ebd2ee26d2715ae88f90ceb'
        MD5 = 'f6678a79e2526b16b45ff629574fd96f'
        Url = 'https://gh-proxy.org/https://github.com/zhongfly/mpv-winbuild/releases/download/2026-11-08-8bc468896e/mpv-dev-x86_64-20261108-git-8bc468896e.7z'
    },
    @{
        Name = 'ANGLE.7z'
        SHA256 = 'cc5911bb15d596fd5a2b362613ad35b7093b427117269a7359054a65746a5f9a'
        MD5 = 'e866f13e8d552348058afaafe869b1ed'
        Url = 'https://gh-proxy.com/https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z'
    }
)
foreach ($archive in $archives) {
    $cachedFile = Join-Path $cachePath $archive.Name
    $buildFile = Join-Path $buildPath $archive.Name
    $cached = (Test-Path -LiteralPath $cachedFile) -and ((Get-FileHash -LiteralPath $cachedFile -Algorithm SHA256).Hash -eq $archive.SHA256)
    if (-not $cached) {
        foreach ($candidate in @((Join-Path $projectPath ('native\third_party\' + $archive.Name)), $buildFile, (Join-Path $projectPath ('.local\player-test\' + $archive.Name)))) {
            if ((Test-Path -LiteralPath $candidate) -and ((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -eq $archive.SHA256)) {
                Copy-Item -LiteralPath $candidate -Destination $cachedFile -Force
                $cached = $true
                break
            }
        }
    }
    if (-not $cached) {
        Write-Host ('Downloading ' + $archive.Name + ' from its pinned mirror...')
        $partialFile = $cachedFile + '.download'
        & curl.exe --fail --location --silent --show-error --retry 2 --connect-timeout 20 --max-time 180 --output $partialFile $archive.Url
        if ($LASTEXITCODE -ne 0) { throw ('Download failed: ' + $archive.Name) }
        if ((Get-FileHash -LiteralPath $partialFile -Algorithm SHA256).Hash -ne $archive.SHA256) {
            throw ('SHA-256 mismatch: ' + $archive.Name)
        }
        Move-Item -LiteralPath $partialFile -Destination $cachedFile -Force
    }
    if ((Get-FileHash -LiteralPath $cachedFile -Algorithm MD5).Hash -ne $archive.MD5) {
        throw ('Upstream checksum mismatch: ' + $archive.Name)
    }
    Copy-Item -LiteralPath $cachedFile -Destination $buildFile -Force
}
Write-Host 'Pinned Windows media dependencies are ready.'
