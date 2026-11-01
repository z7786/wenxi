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
        Name = 'mpv-dev-x86_64-20241021-git-0f78584.7z'
        SHA256 = 'e23701df0adc1fe57c8ede3ff313513b0b80519870058c2d35ff02754284a007'
        MD5 = '6ecf18e85b093c3f7edb16f3ee6603f3'
        Url = 'https://gh-proxy.com/https://github.com/media-kit/libmpv-win32-video-cmake/releases/download/20241021/mpv-dev-x86_64-20241021-git-0f78584.7z'
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
        foreach ($candidate in @($buildFile, (Join-Path $projectPath ('.local\player-test\' + $archive.Name)))) {
            if ((Test-Path -LiteralPath $candidate) -and ((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -eq $archive.SHA256)) {
                Copy-Item -LiteralPath $candidate -Destination $cachedFile -Force
                $cached = $true
                break
            }
        }
    }
    if (-not $cached) {
        Write-Host ('Downloading ' + $archive.Name + ' through gh-proxy.com...')
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
