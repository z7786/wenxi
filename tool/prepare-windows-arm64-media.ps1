param([string]$SevenZip)
$ErrorActionPreference = 'Stop'
$projectPath = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'windows-architecture.ps1')
. (Join-Path $PSScriptRoot 'build-common.ps1')
$cachePath = Join-Path $projectPath '.local\windows-dependencies\arm64'
$buildPath = Join-Path $projectPath 'build\windows\arm64'
New-Item -ItemType Directory -Path $cachePath, $buildPath -Force | Out-Null

function Get-VerifiedArchive {
    param([string]$Name, [string]$SHA256, [string[]]$Urls)
    $destination = Join-Path $cachePath $Name
    if ((Test-Path -LiteralPath $destination -PathType Leaf) -and
        (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -eq $SHA256) {
        return $destination
    }
    $partial = $destination + '.download'
    foreach ($url in $Urls) {
        Write-Host "Downloading ARM64 dependency $Name..."
        & curl.exe --fail --location --silent --show-error --connect-timeout 15 --max-time 180 --output $partial $url
        if ($LASTEXITCODE -eq 0 -and
            (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -eq $SHA256) {
            Move-Item -LiteralPath $partial -Destination $destination -Force
            return $destination
        }
    }
    throw "Cannot download the verified ARM64 dependency: $Name"
}

$mpvArchive = Get-VerifiedArchive -Name 'mpv-dev-aarch64-20261021-git-e471496c56.7z' `
    -SHA256 '015f133399b3525021b6d937cf54ace2761d4f70224d5e62f5df24191b28f398' `
    -Urls @(
        'https://gh-proxy.org/https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20261021/mpv-dev-aarch64-20261021-git-e471496c56.7z',
        'https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20261021/mpv-dev-aarch64-20261021-git-e471496c56.7z'
    )
$electronArchive = Get-VerifiedArchive -Name 'electron-v32.3.3-win32-arm64.zip' `
    -SHA256 '0cdac1de0f5750a0d327896b7b4fdeec47a32cc8a9ede1148dc8552a60417a4f' `
    -Urls @(
        'https://npmmirror.com/mirrors/electron/32.3.3/electron-v32.3.3-win32-arm64.zip',
        'https://gh-proxy.org/https://github.com/electron/electron/releases/download/v32.3.3/electron-v32.3.3-win32-arm64.zip'
    )
# Khronos headers are architecture independent. Runtime DLLs and generated
# import libraries below always come from the verified ARM64 distribution.
$headerArchive = Get-VerifiedArchive -Name 'ANGLE-headers-v1.0.1.7z' `
    -SHA256 'cc5911bb15d596fd5a2b362613ad35b7093b427117269a7359054a65746a5f9a' `
    -Urls @('https://gh-proxy.org/https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z')

if (-not $SevenZip) {
    foreach ($candidate in @('7za.exe', '7z.exe', 'D:\Tools\7zip\x64\7za.exe', 'C:\Program Files\7-Zip\7z.exe')) {
        $found = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($found) { $SevenZip = $found.Source; break }
    }
}
if (-not $SevenZip) { throw 'ARM64 mpv archives require current 7-Zip; pass -SevenZip <7za.exe>.' }
$mpvPath = Join-Path $buildPath 'libmpv-20261021'
$headersPath = Join-Path $cachePath 'angle-headers-v1.0.1'
Invoke-AsterLinkTool -Command $SevenZip -Arguments @('x', $mpvArchive, ('-o' + $mpvPath), '-y', '-bso0', '-bsp0') -Failure 'ARM64 mpv extraction failed'
Invoke-AsterLinkTool -Command $SevenZip -Arguments @('x', $headerArchive, ('-o' + $headersPath), 'include/*', '-y', '-bso0', '-bsp0') -Failure 'ANGLE header extraction failed'

$anglePath = Join-Path $buildPath 'ANGLE'
$angleLibPath = Join-Path $anglePath 'lib'
$licensePath = Join-Path $anglePath 'licenses'
New-Item -ItemType Directory -Path $angleLibPath, $licensePath -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $headersPath 'include') -Destination $anglePath -Recurse -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($electronArchive)
try {
    foreach ($name in @('libEGL.dll', 'libGLESv2.dll', 'd3dcompiler_47.dll', 'vk_swiftshader.dll', 'vulkan-1.dll')) {
        $entry = $zip.GetEntry($name)
        if (-not $entry) { throw "Missing ARM64 ANGLE component: $name" }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $anglePath $name), $true)
    }
    foreach ($name in @('LICENSE', 'LICENSES.chromium.html')) {
        [IO.Compression.ZipFileExtensions]::ExtractToFile($zip.GetEntry($name), (Join-Path $licensePath ('Electron-32.3.3-' + $name)), $true)
    }
} finally { $zip.Dispose() }
foreach ($dll in @((Join-Path $mpvPath 'libmpv-2.dll')) + @(Get-ChildItem -LiteralPath $anglePath -Filter '*.dll' -File | ForEach-Object FullName)) {
    if ((Get-AsterLinkPeMachine -Path $dll) -ne 0xaa64) { throw "Non-ARM64 media dependency: $dll" }
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsPath = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath | Select-Object -First 1)
if (-not $vsPath) { throw 'Install Visual Studio C++ ARM64 build tools.' }
$compilerVersion = Get-ChildItem -LiteralPath (Join-Path $vsPath 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$compilerPath = Join-Path $compilerVersion.FullName 'bin\Hostx64\x64'
$dumpbin = Join-Path $compilerPath 'dumpbin.exe'
$librarian = Join-Path $compilerPath 'lib.exe'

function New-Arm64ImportLibrary {
    param([string]$Dll, [string]$Output)
    $exportOutput = @(& $dumpbin /exports $Dll 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Cannot inspect DLL exports: $Dll" }
    $exports = @($exportOutput | ForEach-Object {
        if ($_ -match '^\s+\d+\s+[0-9a-fA-F]+\s+[0-9a-fA-F]+\s+([A-Za-z_][A-Za-z0-9_]*)\s*$') { $Matches[1] }
    })
    if ($exports.Count -eq 0) { throw "No C exports in $Dll" }
    $definition = $Output + '.def'
    [IO.File]::WriteAllText($definition, ('LIBRARY ' + [IO.Path]::GetFileName($Dll) + "`r`nEXPORTS`r`n" + ($exports -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
    Invoke-AsterLinkTool -Command $librarian -Arguments @('/nologo', '/MACHINE:ARM64', ('/DEF:' + $definition), ('/OUT:' + $Output)) -Failure 'ARM64 import-library generation failed'
}
$mpvInterface = Join-Path $buildPath 'libmpv'
New-Item -ItemType Directory -Path (Join-Path $mpvInterface 'include') -Force | Out-Null
Copy-Item -Path (Join-Path $mpvPath 'include\mpv\*') -Destination (Join-Path $mpvInterface 'include') -Force
New-Arm64ImportLibrary -Dll (Join-Path $mpvPath 'libmpv-2.dll') -Output (Join-Path $mpvInterface 'libmpv.dll.a')
New-Arm64ImportLibrary -Dll (Join-Path $anglePath 'libEGL.dll') -Output (Join-Path $angleLibPath 'libEGL.dll.lib')
New-Arm64ImportLibrary -Dll (Join-Path $anglePath 'libGLESv2.dll') -Output (Join-Path $angleLibPath 'libGLESv2.dll.lib')
Copy-Item -LiteralPath (Join-Path $projectPath 'assets\licenses\Windows-ARM64-media-NOTICES.txt') -Destination $licensePath -Force
Copy-Item -LiteralPath (Join-Path $projectPath 'assets\licenses\mpv-GPL-2.0.txt') -Destination $licensePath -Force
Write-Host 'Verified Windows ARM64 media libraries, headers, import libraries and licenses are ready.'
