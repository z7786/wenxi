[CmdletBinding()]
param([string]$FlutterRoot = $env:FLUTTER_ROOT)
$ErrorActionPreference = 'Stop'
if (-not $FlutterRoot) { throw 'FLUTTER_ROOT is required for the isolated ARM64 SDK.' }
$sdkPath = (Resolve-Path -LiteralPath $FlutterRoot).ProviderPath
$engine = [IO.File]::ReadAllText((Join-Path $sdkPath 'bin/internal/engine.version')).Trim()
if ($engine -ne '89c39edfdfae2949f6806e4a315c0c08522238b7') { throw 'Expected Flutter 3.47.9 engine.' }
& (Join-Path $PSScriptRoot 'enable-windows-arm64-sdk.ps1') -FlutterRoot $sdkPath
$flutter = Join-Path $sdkPath 'bin/flutter.bat'
& $flutter precache --windows
if ($LASTEXITCODE -ne 0) { throw 'Windows host SDK preparation failed.' }
$cache = Join-Path (Split-Path -Parent $PSScriptRoot) '.local/arm64-sdk-downloads'
New-Item -ItemType Directory -Path $cache -Force | Out-Null
$archives = @(
    @{ Name='windows-arm64-flutter.zip'; Relative='windows-arm64-release/windows-arm64-flutter.zip'; Folder='windows-arm64-release'; Hash='1fc9922668afbe4327abeb451ee078113879b4d890be6390732596a363f6eba5' },
    @{ Name='flutter-cpp-client-wrapper.zip'; Relative='windows-arm64/flutter-cpp-client-wrapper.zip'; Folder='windows-arm64'; Hash='48ce2e40268f8f681ee44fe51cc5e5bace8ff6987e01bf76ee9bc329dc4a5b24' }
)
foreach ($archive in $archives) {
    $file = Join-Path $cache $archive.Name
    $verified = (Test-Path -LiteralPath $file) -and (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -eq $archive.Hash
    if (-not $verified) {
        foreach ($hostUrl in @('https://storage.googleapis.com', 'https://storage.flutter-io.cn')) {
            $url = "$hostUrl/flutter_infra_release/flutter/$engine/$($archive.Relative)"
            & curl.exe --fail --location --silent --show-error --retry 2 --connect-timeout 15 --max-time 300 --output $file $url
            if ($LASTEXITCODE -eq 0 -and (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -eq $archive.Hash) { $verified = $true; break }
        }
    }
    if (-not $verified) { throw "Cannot obtain verified SDK archive $($archive.Name)." }
    $folder = Join-Path $sdkPath ("bin/cache/artifacts/engine/" + $archive.Folder)
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    Expand-Archive -LiteralPath $file -DestinationPath $folder -Force
}
# These are architecture-independent data and tool snapshots from the same engine.
Copy-Item -LiteralPath (Join-Path $sdkPath 'bin/cache/artifacts/engine/windows-x64/icudtl.dat') -Destination (Join-Path $sdkPath 'bin/cache/artifacts/engine/windows-arm64/icudtl.dat') -Force
Copy-Item -LiteralPath (Join-Path $sdkPath 'bin/cache/artifacts/engine/windows-x64/const_finder.dart.snapshot') -Destination (Join-Path $sdkPath 'bin/cache/artifacts/engine/windows-arm64/const_finder.dart.snapshot') -Force
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 Microsoft.VisualStudio.Component.VC.ATL.ARM64 -property installationPath
if (-not $vs) { throw 'The runner requires Visual Studio ARM64 C++ tools and ATL.' }
Write-Host 'Pinned Windows ARM64 Flutter engine and Visual Studio tools are ready.'
