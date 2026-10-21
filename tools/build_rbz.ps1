# Builds dist\easy_cabinet_<version>.rbz (the version is read from easy_cabinet.rb) and copies it to Downloads. Downloads keeps the new package and the five
# previous ones; older ones are deleted. Run from anywhere:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_rbz.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = Split-Path -Parent $PSScriptRoot
$version = [regex]::Match((Get-Content "$root\easy_cabinet.rb" -Raw), "EXTENSION_VERSION = '([^']+)'").Groups[1].Value
if (-not $version) { throw 'No version found in easy_cabinet.rb' }
$dist = "$root\dist"
$downloads = Join-Path $env:USERPROFILE 'Downloads'
New-Item -ItemType Directory -Force $dist | Out-Null
$out = "$dist\easy_cabinet_$version.rbz"

# dist holds only the package just built
Get-ChildItem $dist -Filter 'easy_cabinet_*.rbz' -File | Remove-Item
$zip = [IO.Compression.ZipFile]::Open($out, 'Create')
try {
  [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, "$root\easy_cabinet.rb", 'easy_cabinet.rb', 'Optimal')
  Get-ChildItem "$root\easy_cabinet" -Recurse -File | ForEach-Object {
    $entry = 'easy_cabinet/' + $_.FullName.Substring("$root\easy_cabinet\".Length).Replace('\', '/')
    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $entry, 'Optimal')
  }
} finally { $zip.Dispose() }

# Downloads: the new package and the five before it (by version number)
Copy-Item $out $downloads -Force
$packages = Get-ChildItem $downloads -Filter 'easy_cabinet_*.rbz' -File | Sort-Object { try { [version]($_.BaseName -replace '^easy_cabinet_', '') } catch { [version]'0.0' } } -Descending
$packages | Select-Object -Skip 6 | Remove-Item
"Built $out"
"In Downloads: " + ((Get-ChildItem $downloads -Filter 'easy_cabinet_*.rbz' -File | Sort-Object { try { [version]($_.BaseName -replace '^easy_cabinet_', '') } catch { [version]'0.0' } } -Descending | ForEach-Object Name) -join ', ')
