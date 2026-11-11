param([string]$SevenZip)
$ErrorActionPreference = 'Stop'
$projectPath = Split-Path -Parent $PSScriptRoot
$runtimePath = Join-Path $projectPath '.local\player-test'
$libraryPath = Join-Path $runtimePath 'libmpv'
$archiveName = 'mpv-dev-x86_64-20261108-git-8bc468896e.7z'
$archivePath = Join-Path $runtimePath $archiveName
# Optional full component pin; the application bundles the compact runtime.
$archiveHash = 'a36392a8fbd989ae274a37c63d01ef6c51b6070a5ebd2ee26d2715ae88f90ceb'
$upstreamMd5 = 'f6678a79e2526b16b45ff629574fd96f'
$downloadUrl = 'https://gh-proxy.org/https://github.com/zhongfly/mpv-winbuild/releases/download/2026-11-08-8bc468896e/' + $archiveName
if (-not $SevenZip) {
    foreach ($candidate in @('7za.exe', '7z.exe', 'D:\Tools\7zip\x64\7za.exe', 'C:\Program Files\7-Zip\7z.exe')) {
        $found = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($found) { $SevenZip = $found.Source; break }
    }
}
if (-not $SevenZip) { throw 'Pass -SevenZip <7za.exe> to prepare the test runtime.' }
Get-Command $SevenZip -ErrorAction Stop | Out-Null
New-Item -ItemType Directory -Path $libraryPath -Force | Out-Null
$cached = (Test-Path -LiteralPath $archivePath) -and ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -eq $archiveHash)
if (-not $cached) {
    $vendored = Join-Path $projectPath ('native\third_party\' + $archiveName)
    if (Test-Path -LiteralPath $vendored) {
        if ((Get-FileHash -LiteralPath $vendored -Algorithm SHA256).Hash -ne $archiveHash) {
            throw 'Vendored libmpv archive SHA-256 mismatch.'
        }
        Copy-Item -LiteralPath $vendored -Destination $archivePath -Force
        $cached = $true
    }
}
if (-not $cached) {
    $partialPath = $archivePath + '.download'
    Write-Host 'Downloading the pinned libmpv test runtime through gh-proxy.org...'
    Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $partialPath
    if ((Get-FileHash -LiteralPath $partialPath -Algorithm SHA256).Hash -ne $archiveHash) {
        throw 'libmpv archive SHA-256 mismatch; the download was not extracted.'
    }
    Move-Item -LiteralPath $partialPath -Destination $archivePath -Force
}
if ((Get-FileHash -LiteralPath $archivePath -Algorithm MD5).Hash -ne $upstreamMd5) {
    throw 'libmpv archive does not match the plugin release checksum.'
}
# Extract into the local test directory; no DLL is added to Flutter/APK assets.
& $SevenZip e $archivePath ('-o' + $libraryPath) 'libmpv-2.dll' -r -y | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'libmpv extraction failed.' }
$dllPath = Join-Path $libraryPath 'libmpv-2.dll'
if (-not (Test-Path -LiteralPath $dllPath)) { throw 'libmpv-2.dll was not found.' }
# The full libmpv imports the Vulkan loader provided by the existing ANGLE pin.
& (Join-Path $PSScriptRoot 'prepare-windows-media.ps1') -SevenZip $SevenZip
$angleArchive = Join-Path $projectPath '.local\windows-dependencies\ANGLE.7z'
& $SevenZip e $angleArchive ('-o' + $libraryPath) 'vulkan-1.dll' -r -y | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $libraryPath 'vulkan-1.dll'))) { throw 'Vulkan loader extraction failed.' }
$env:PATH = $libraryPath + [IO.Path]::PathSeparator + $env:PATH
$env:ASTERLINK_MPV_LIBRARY = $dllPath
Write-Host ('Prepared: ' + $dllPath)
Write-Host 'Run flutter test test/native_playback_test.dart to check real playback without a GUI or audio output.'
