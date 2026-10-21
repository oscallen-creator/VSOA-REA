# collect-removebg.ps1 - package the remove.bg desktop app's own code for REA.
#
# Reads only the install folder. It never reads %APPDATA% (settings there can
# hold your API key or login). Output: removebg-for-rea.zip on your Desktop,
# split into parts if larger than -MaxZipMB.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\collect-removebg.ps1
#   ... -AppDir "C:\path\to\remove.bg"   (if it is not found automatically)
[CmdletBinding()]
param(
    [string]$AppDir,
    [string]$OutDir = [Environment]::GetFolderPath('Desktop'),
    [ValidateRange(1, 4096)][int]$MaxFileMB = 40,
    [ValidateRange(1, 4096)][int]$MaxZipMB = 25,
    [string[]]$IncludeModules = @(),
    [ValidateRange(0, 4096)][int]$AutoFullMB = 60,
    [switch]$Full
)
$ErrorActionPreference = 'Stop'
$ScriptVersion = 2
$NamePattern = 'remove[\s._-]*bg'
$MB = 1024 * 1024
# Chromium/Electron runtime files: hashed in the inventory, not copied.
$Runtime = '^(chrome_\d+_percent\.pak|d3dcompiler_47\.dll|dxcompiler\.dll|dxil\.dll|ffmpeg\.dll|icudtl\.dat|libEGL\.dll|libGLESv2\.dll|resources\.pak|snapshot_blob\.bin|v8_context_snapshot\.bin|vk_swiftshader\.dll|vk_swiftshader_icd\.json|vulkan-1\.dll|LICENSES\.chromium\.html|locales/.*)$'

function Get-Prop($o, $n) { $p = $o.PSObject.Properties[$n]; if ($p) { $p.Value } }

function Get-DirFromCommand([string]$s) {
    if ($s -and $s -match '^\s*"?([^",]+?\.(exe|ico))') { Split-Path -Parent $Matches[1] }
}

function Resolve-AppRoot([string]$d) {
    # Squirrel installs keep each version in app-<version>; use the newest.
    if (-not (Test-Path -LiteralPath (Join-Path $d 'resources'))) {
        $v = Get-ChildItem -LiteralPath $d -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
            Sort-Object { try { [version]($_.Name.Substring(4)) } catch { [version]'0.0' } } | Select-Object -Last 1
        if ($v) { return $v.FullName }
    }
    $d
}

function Find-AppDirs {
    $dirs = New-Object System.Collections.Generic.List[string]
    $keys = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    foreach ($e in (Get-ItemProperty $keys -ErrorAction SilentlyContinue)) {
        if ((Get-Prop $e 'DisplayName') -notmatch $NamePattern) { continue }
        $dirs.Add((Get-Prop $e 'InstallLocation'))
        $dirs.Add((Get-DirFromCommand (Get-Prop $e 'DisplayIcon')))
        $dirs.Add((Get-DirFromCommand (Get-Prop $e 'UninstallString')))
    }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($b in "$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs", [Environment]::GetFolderPath('Desktop')) {
        if (-not $b) { continue }
        Get-ChildItem -LiteralPath $b -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -match $NamePattern } | ForEach-Object {
                $t = $shell.CreateShortcut($_.FullName).TargetPath
                if ($t) { $dirs.Add((Split-Path -Parent $t)) }
            }
    }
    foreach ($b in "$env:LOCALAPPDATA\Programs", $env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)}) {
        if (-not $b) { continue }
        Get-ChildItem -LiteralPath $b -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $NamePattern } | ForEach-Object { $dirs.Add($_.FullName) }
    }
    try {
        Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $NamePattern } |
            ForEach-Object { $dirs.Add($_.InstallLocation) }
    } catch { }
    $(foreach ($d in $dirs) {
        try {
            if (-not $d -or -not (Test-Path -LiteralPath $d -PathType Container)) { continue }
            $r = Resolve-AppRoot ((Resolve-Path -LiteralPath $d).ProviderPath.TrimEnd('\', '/'))
            if (Get-ChildItem -LiteralPath $r -Filter '*.exe' -File -ErrorAction SilentlyContinue) { $r }
        } catch { }
    }) | Select-Object -Unique
}

function Test-SafeRel([string]$rel) {
    foreach ($s in $rel.Split('/')) {
        if ($s -eq '' -or $s -eq '.' -or $s -eq '..' -or $s -match '[\x00-\x1f<>:"\\|?*]') { return $false }
    }
    $true
}

# Which application files to copy. App code always; dependencies only by name.
function Get-Wanted([string]$rel, [long]$size) {
    if ($size -gt $MaxFileMB * $MB) { return 'skipped: larger than MaxFileMB' }
    if (-not (Test-SafeRel $rel)) { return 'skipped: unsafe name' }
    if ($script:IncludeAll -or $rel -notmatch '(^|/)node_modules/') { return 'included' }
    if ($rel -match '^node_modules/(@[^/]+/)?[^/]+/package\.json$') { return 'included' }
    foreach ($m in $IncludeModules) { if ($rel -like "node_modules/$m/*") { return 'included' } }
    'skipped: dependency (listed in asar-index.csv)'
}

function Read-AsarHeader([IO.FileStream]$fs) {
    $br = New-Object IO.BinaryReader($fs)
    [void]$br.ReadUInt32()
    $headerSize = $br.ReadUInt32()
    [void]$br.ReadUInt32()
    $json = [Text.Encoding]::UTF8.GetString($br.ReadBytes($br.ReadInt32()))
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $tree = $json | ConvertFrom-Json -AsHashtable -Depth 1024
    } else {
        Add-Type -AssemblyName System.Web.Extensions
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $ser.MaxJsonLength = [int]::MaxValue
        $ser.RecursionLimit = 4096
        $tree = $ser.DeserializeObject($json)
    }
    @{ Tree = $tree; DataOffset = 8 + [long]$headerSize }
}

function Get-AsarEntries($node, [string]$prefix) {
    $files = $node['files']
    foreach ($name in @($files.Keys)) {
        $child = $files[$name]
        $rel = if ($prefix) { "$prefix/$name" } else { [string]$name }
        if ($child.ContainsKey('files')) { Get-AsarEntries $child $rel; continue }
        [pscustomobject]@{
            Path = $rel
            Size = $(if ($child.ContainsKey('size')) { [long]$child['size'] } else { 0 })
            Offset = $(if ($child.ContainsKey('offset')) { [long]$child['offset'] } else { -1 })
            Unpacked = $child.ContainsKey('unpacked') -and [bool]$child['unpacked']
            Link = $(if ($child.ContainsKey('link')) { [string]$child['link'] } else { '' })
        }
    }
}

function Copy-Range([IO.Stream]$src, [long]$offset, [long]$count, [string]$dest) {
    $out = [IO.File]::Create($dest)
    try {
        [void]$src.Seek($offset, 'Begin')
        $buf = New-Object byte[] (1MB)
        while ($count -gt 0) {
            $n = $src.Read($buf, 0, [int][Math]::Min($buf.Length, $count))
            if ($n -le 0) { throw 'asar ended early' }
            $out.Write($buf, 0, $n); $count -= $n
        }
    } finally { $out.Dispose() }
}

function Export-Asar([string]$asar, [string]$dest, $log) {
    $fs = [IO.File]::Open($asar, 'Open', 'Read', 'ReadWrite, Delete')
    try {
        $h = Read-AsarHeader $fs
        $entries = @(Get-AsarEntries $h.Tree '')
        $total = [long]($entries | Measure-Object Size -Sum).Sum
        $script:IncludeAll = $Full -or $total -le $AutoFullMB * $MB
        foreach ($e in $entries) {
            $status = if ($e.Link) { 'skipped: symlink' } else { Get-Wanted $e.Path $e.Size }
            if ($status -eq 'included') {
                try {
                    $target = Join-Path $dest $e.Path
                    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
                    if ($e.Unpacked) { Copy-Item -LiteralPath (Join-Path "$asar.unpacked" $e.Path) $target -Force -ErrorAction Stop }
                    else { Copy-Range $fs ($h.DataOffset + $e.Offset) $e.Size $target }
                } catch { $status = "failed: $($_.Exception.Message)" }
            }
            $log.Add([pscustomobject]@{ Path = $e.Path; Size = $e.Size; Unpacked = $e.Unpacked; Status = $status })
        }
        [pscustomobject]@{ Entries = $entries.Count; Bytes = $total; IncludedAll = $script:IncludeAll }
    } finally { $fs.Dispose() }
}

function Write-Zip([string]$zipPath, $items) {
    $zip = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
    try {
        foreach ($i in $items) {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $i.FullName, $i.Rel, 'Optimal')
        }
    } finally { $zip.Dispose() }
}

# --- locate the app --------------------------------------------------------
if (-not $AppDir) {
    $found = @(Find-AppDirs)
    if ($found.Count -eq 0) {
        $dl = Get-ChildItem -LiteralPath (Join-Path $env:USERPROFILE 'Downloads') -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $NamePattern }
        if ($dl) { Write-Host "Found $($dl[0].Name) in Downloads but no installed app. Install it, then run this again." -ForegroundColor Yellow }
        throw 'remove.bg is not installed where expected. Re-run with -AppDir "<install folder>".'
    }
    if ($found.Count -gt 1) { Write-Host "Several candidates; using the first:`n  $($found -join "`n  ")" }
    $AppDir = $found[0]
}
$AppDir = (Resolve-Path -LiteralPath $AppDir).ProviderPath.TrimEnd('\', '/')
Write-Host "App folder: $AppDir"

$running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $p = $null; try { $p = $_.Path } catch { }
    $p -and $p.StartsWith($AppDir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) })
if ($running.Count -gt 0) {
    $ans = Read-Host "remove.bg is running and may lock its files. Close it now? [Y/n]"
    if ($ans -match '^[nN]') { throw 'Close remove.bg (including its tray icon) and run this again.' }
    $running | ForEach-Object { try { [void]$_.CloseMainWindow() } catch { } }
    Start-Sleep -Seconds 3
    $running | Where-Object { -not $_.HasExited } | Stop-Process -Force -ErrorAction SilentlyContinue
}

# --- stage -----------------------------------------------------------------
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stage = Join-Path ([IO.Path]::GetTempPath()) "rbg-$stamp"
$meta = Join-Path $stage '_rea'
[void][IO.Directory]::CreateDirectory($meta)
try {
    $asar = Join-Path $AppDir 'resources/app.asar'
    $appFolder = Join-Path $AppDir 'resources/app'
    $mode = if (Test-Path -LiteralPath $asar) { 'electron-asar' } elseif (Test-Path -LiteralPath $appFolder) { 'electron-folder' } else { 'native' }
    $script:IncludeAll = [bool]$Full
    $inventory = New-Object System.Collections.Generic.List[object]
    $listErrors = $null
    $all = @(Get-ChildItem -LiteralPath $AppDir -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable listErrors)
    foreach ($f in $all) {
        $rel = $f.FullName.Substring($AppDir.Length + 1).Replace('\', '/')
        $hash = 'unreadable'
        try { $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash } catch { }
        $vi = if ($f.Extension -match '^\.(exe|dll|node)$') { $f.VersionInfo }
        $status = if ($rel -match $Runtime -or $rel -match '^resources/app\.asar(\.unpacked/|$)') { 'not copied: runtime or asar' }
            elseif ($mode -eq 'electron-folder' -and $rel.StartsWith('resources/app/')) { Get-Wanted $rel.Substring(14) $f.Length }
            elseif ($mode -ne 'native' -and $f.Extension -match '^\.(exe|dll)$') { 'not copied: Electron binary' }
            else { Get-Wanted $rel $f.Length }
        if ($status -eq 'included') {
            $target = if ($mode -eq 'electron-folder' -and $rel.StartsWith('resources/app/')) { "app/$($rel.Substring(14))" } else { "install/$rel" }
            try {
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent (Join-Path $stage $target)))
                Copy-Item -LiteralPath $f.FullName (Join-Path $stage $target) -ErrorAction Stop
            } catch { $status = "failed: $($_.Exception.Message)" }
        }
        $inventory.Add([pscustomobject]@{
            Path = $rel; Size = $f.Length; SHA256 = $hash; Status = $status
            Product = $vi.ProductName; Company = $vi.CompanyName
            FileVersion = $vi.FileVersion; ProductVersion = $vi.ProductVersion
        })
    }
    $inventory | Export-Csv -LiteralPath (Join-Path $meta 'inventory.csv') -NoTypeInformation -Encoding UTF8
    $asarInfo = $null
    if ($mode -eq 'electron-asar') {
        $log = New-Object System.Collections.Generic.List[object]
        $asarInfo = Export-Asar $asar (Join-Path $stage 'app') $log
        $log | Export-Csv -LiteralPath (Join-Path $meta 'asar-index.csv') -NoTypeInformation -Encoding UTF8
    }
    $mainExe = $inventory | Where-Object { $_.Path -notmatch '/' -and $_.Path -match '\.exe$' -and $_.Path -notmatch '^(uninstall|unins|update|elevate)' } |
        Sort-Object Size -Descending | Select-Object -First 1
    [ordered]@{
        collector = "collect-removebg.ps1 v$ScriptVersion"; collectedAt = (Get-Date).ToString('o')
        powershell = $PSVersionTable.PSVersion.ToString(); os = [Environment]::OSVersion.VersionString
        appDir = $AppDir; mode = $mode; mainExe = $mainExe; asar = $asarInfo
        listErrors = @($listErrors | ForEach-Object { $_.ToString() })
        options = [ordered]@{ maxFileMB = $MaxFileMB; maxZipMB = $MaxZipMB; includeModules = $IncludeModules; full = [bool]$Full }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $meta 'manifest.json') -Encoding UTF8

    # --- zip, splitting into parts that fit -MaxZipMB -----------------------
    $now = Get-Date
    $items = @(Get-ChildItem -LiteralPath $stage -Recurse -File | ForEach-Object {
        $_.LastWriteTime = $now   # zip entries cannot hold pre-1980 times
        [pscustomobject]@{ FullName = $_.FullName; Length = $_.Length; Rel = $_.FullName.Substring($stage.Length + 1).Replace('\', '/') }
    } | Sort-Object @{ e = { -not $_.Rel.StartsWith('_rea/') } }, Rel)
    [void][IO.Directory]::CreateDirectory($OutDir)
    $budget = [long]$MaxZipMB * $MB * 3
    while ($true) {
        $parts = New-Object System.Collections.Generic.List[object]
        $cur = New-Object System.Collections.Generic.List[object]; $sum = 0L
        foreach ($i in $items) {
            if ($cur.Count -gt 0 -and $sum + $i.Length -gt $budget) { $parts.Add($cur.ToArray()); $cur.Clear(); $sum = 0L }
            $cur.Add($i); $sum += $i.Length
        }
        if ($cur.Count -gt 0) { $parts.Add($cur.ToArray()) }
        $zips = @(); $tooBig = $false
        for ($n = 0; $n -lt $parts.Count; $n++) {
            $name = if ($parts.Count -eq 1) { 'removebg-for-rea.zip' } else { "removebg-for-rea-part$($n + 1)of$($parts.Count).zip" }
            $zipPath = Join-Path $OutDir $name
            Remove-Item -LiteralPath $zipPath -ErrorAction SilentlyContinue
            Write-Zip $zipPath $parts[$n]
            $zips += Get-Item -LiteralPath $zipPath
            if ($zips[-1].Length -gt $MaxZipMB * $MB -and $parts[$n].Count -gt 1) { $tooBig = $true }
        }
        if (-not $tooBig) { break }
        $zips | Remove-Item -ErrorAction SilentlyContinue
        $budget = [long]($budget / 2)
    }
    Get-ChildItem -LiteralPath $OutDir -Filter 'removebg-for-rea*.zip' | Where-Object { $zips.FullName -notcontains $_.FullName } |
        Remove-Item -ErrorAction SilentlyContinue
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("Mode: {0}. Packed {1} files." -f $mode, @($items).Count)
if ($asarInfo) { Write-Host ("app.asar: {0} entries, {1:N1} MB; dependencies {2}." -f $asarInfo.Entries, ($asarInfo.Bytes / $MB), $(if ($asarInfo.IncludedAll) { 'included' } else { 'listed only' })) }
$zips | ForEach-Object { Write-Host ("Created {0} ({1:N1} MB)" -f $_.FullName, ($_.Length / $MB)) -ForegroundColor Green }
Write-Host 'Drag the zip file(s) into the Claude chat.'
if ($env:OS -eq 'Windows_NT') { Start-Process explorer.exe "/select,`"$($zips[0].FullName)`"" }
