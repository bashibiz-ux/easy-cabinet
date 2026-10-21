# Builds dist\easy_cabinet_<version>.rbz (the version is read from easy_cabinet.rb), copies it to Downloads, and keeps the five previous packages in dist\backup.
# Run from anywhere:  powershell -NoProfile -File tools\build_rbz.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = Split-Path -Parent $PSScriptRoot
$version = [regex]::Match((Get-Content "$root\easy_cabinet.rb" -Raw), "EXTENSION_VERSION = '([^']+)'").Groups[1].Value
if (-not $version) { throw 'No version found in easy_cabinet.rb' }
$dist = "$root\dist"
$backup = "$dist\backup"
$downloads = Join-Path $env:USERPROFILE 'Downloads'
New-Item -ItemType Directory -Force $backup | Out-Null
$out = "$dist\easy_cabinet_$version.rbz"

# the packages built before this one go to the backup (never overwritten), then only the newest five are kept there
foreach ($old in @(Get-ChildItem $dist -Filter 'easy_cabinet_*.rbz' -File) + @(Get-ChildItem $downloads -Filter 'easy_cabinet*.rbz' -File)) {
  if ($old.Name -ne "easy_cabinet_$version.rbz" -and -not (Test-Path "$backup\$($old.Name)")) { Copy-Item $old.FullName "$backup\$($old.Name)" }
  Remove-Item $old.FullName
}
if (Test-Path $out) { Remove-Item $out }

$zip = [IO.Compression.ZipFile]::Open($out, 'Create')
try {
  [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, "$root\easy_cabinet.rb", 'easy_cabinet.rb', 'Optimal')
  Get-ChildItem "$root\easy_cabinet" -Recurse -File | ForEach-Object {
    $entry = 'easy_cabinet/' + $_.FullName.Substring("$root\easy_cabinet\".Length).Replace('\', '/')
    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $entry, 'Optimal')
  }
} finally { $zip.Dispose() }

Copy-Item $out $downloads -Force
Get-ChildItem $backup -Filter 'easy_cabinet_*.rbz' -File | Sort-Object LastWriteTime -Descending | Select-Object -Skip 5 | Remove-Item
"Built $out"
"Backup: " + ((Get-ChildItem $backup -Filter 'easy_cabinet_*.rbz' -File | Sort-Object LastWriteTime -Descending | ForEach-Object Name) -join ', ')
