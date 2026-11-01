param([Parameter(Mandatory)][string]$FlutterRoot)
$ErrorActionPreference = 'Stop'
$sdkPath = (Resolve-Path -LiteralPath $FlutterRoot).ProviderPath
$engineVersion = [IO.File]::ReadAllText((Join-Path $sdkPath 'bin\internal\engine.version')).Trim()
if ($engineVersion -ne '89c39edfdfae2949f6806e4a315c0c08522238b7') {
    throw 'This SDK adapter is verified only for Flutter 3.47.9. Use a separate SDK directory.'
}
$commandPath = Join-Path $sdkPath 'packages\flutter_tools\lib\src\commands\build_windows.dart'
$source = [IO.File]::ReadAllText($commandPath).Replace("`r`n", "`n")
if ($source.Contains("'Target Windows architecture for the isolated AsterLink build SDK.'")) {
    Write-Host 'The isolated SDK already supports --target-platform.'
    return
}
$optionAnchor = '    usesFlavorOption();'
$platformAnchor = @'
    final defaultTargetPlatform = (_operatingSystemUtils.hostPlatform == HostPlatform.windows_arm64)
        ? 'windows-arm64'
        : 'windows-x64';
    final targetPlatform = TargetPlatform.fromName(defaultTargetPlatform);
'@
if (-not $source.Contains($optionAnchor) -or -not $source.Contains($platformAnchor.TrimEnd())) {
    throw 'Unexpected Flutter source. No SDK files were changed.'
}
$options = @'
    usesFlavorOption();
    argParser.addOption(
      'target-platform',
      defaultsTo: operatingSystemUtils.hostPlatform == HostPlatform.windows_arm64
          ? 'windows-arm64'
          : 'windows-x64',
      allowed: const <String>['windows-x64', 'windows-arm64'],
      help: 'Target Windows architecture for the isolated AsterLink build SDK.',
    );
'@
$source = $source.Replace($optionAnchor, $options.TrimEnd())
$source = $source.Replace($platformAnchor.TrimEnd(), "    final targetPlatform = TargetPlatform.fromName(stringArg('target-platform')!);")
$source = $source.Replace('  final OperatingSystemUtils _operatingSystemUtils;', '')
$source = $source.Replace("  }) : _operatingSystemUtils = operatingSystemUtils,`n       super(verboseHelp: verboseHelp) {", '  }) : super(verboseHelp: verboseHelp) {')
$backupPath = $commandPath + '.before-asterlink-arm64'
if (-not (Test-Path -LiteralPath $backupPath)) { Copy-Item -LiteralPath $commandPath -Destination $backupPath }
[IO.File]::WriteAllText($commandPath, $source, [Text.UTF8Encoding]::new($false))
$snapshotPath = Join-Path $sdkPath 'bin\cache\flutter_tools.snapshot'
if (Test-Path -LiteralPath $snapshotPath) { Remove-Item -LiteralPath $snapshotPath }
Write-Host 'Isolated Flutter 3.47.9 SDK now supports Windows ARM64 cross-builds.'
