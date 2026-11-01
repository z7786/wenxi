function Get-AsterLinkPeMachine {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d) {
            throw "Not a Windows PE binary: $Path"
        }
        $stream.Position = 0x3c
        $peOffset = $reader.ReadUInt32()
        if ($peOffset -gt $stream.Length - 6) { throw "Invalid PE header: $Path" }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw "Invalid PE signature: $Path" }
        return $reader.ReadUInt16()
    } finally { $reader.Dispose() }
}

function Assert-AsterLinkWindowsArchitecture {
    param(
        [Parameter(Mandatory)][string]$RuntimePath,
        [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64'
    )
    $expectedMachine = if ($Architecture -eq 'arm64') { 0xaa64 } else { 0x8664 }
    $binaries = @(Get-ChildItem -LiteralPath $RuntimePath -Recurse -File |
        Where-Object { $_.Extension -in @('.exe', '.dll') })
    if ($binaries.Count -eq 0) { throw 'The runtime has no Windows binaries.' }
    foreach ($binary in $binaries) {
        $machine = Get-AsterLinkPeMachine -Path $binary.FullName
        if ($machine -ne $expectedMachine) {
            throw ("Architecture mismatch: {0} is PE 0x{1:x4}, expected {2}." -f $binary.Name, $machine, $Architecture)
        }
    }
    $snapshotPath = Join-Path $RuntimePath 'data\app.so'
    $stream = [IO.File]::OpenRead($snapshotPath)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        $magic = $reader.ReadUInt32()
        if ($magic -eq 0x464c457f) {
            if ($reader.ReadByte() -ne 2 -or $reader.ReadByte() -ne 1) {
                throw 'The Dart AOT snapshot must be a little-endian ELF64 file.'
            }
            $stream.Position = 18
            $elfMachine = $reader.ReadUInt16()
            $expectedElf = if ($Architecture -eq 'arm64') { 183 } else { 62 }
            if ($elfMachine -ne $expectedElf) {
                throw "Dart AOT architecture mismatch: ELF $elfMachine, expected $Architecture."
            }
        } elseif (($magic -band 0xffff) -eq 0x5a4d) {
            if ((Get-AsterLinkPeMachine -Path $snapshotPath) -ne $expectedMachine) {
                throw 'Dart AOT PE architecture differs from the Windows runtime.'
            }
        } else { throw 'Unrecognized Dart AOT snapshot format.' }
    } finally { $reader.Dispose() }
    Write-Host "Verified $($binaries.Count) Windows $Architecture binaries and the Dart AOT snapshot."
}
