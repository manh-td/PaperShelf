# Builds build/PaperShelf-linux-x86_64.tar.gz on this Windows machine.
# 1. builds the PDF helper jar, 2. exports the Godot Linux build, 3. packs everything
# with the bundled Java runtime (see the packageLinux task in pdf_helper/build.gradle).
# Usage (from the PaperShelf folder): powershell -ExecutionPolicy Bypass -File tools\build_linux.ps1
param(
  [string]$Godot = 'D:\Godot\Godot_v4.7.2-stable_win64_console.exe',
  [string]$JavaHome = 'C:\Program Files\Eclipse Adoptium\jdk-17.0.21.9-hotspot'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$env:JAVA_HOME = $JavaHome

Write-Host '== Building the PDF helper'
& "$root\pdf_helper\gradlew.bat" -p "$root\pdf_helper" --no-daemon -q copyJarToGodot
if ($LASTEXITCODE -ne 0) { throw 'helper build failed' }

Write-Host '== Exporting the Linux build'
New-Item -ItemType Directory -Force "$root\build\linux" | Out-Null
$out = "$root\build\linux\PaperShelf.x86_64"
if (Test-Path $out) { Remove-Item $out }
$p = Start-Process -FilePath $Godot -ArgumentList @('--headless', '--path', "`"$root\app`"", '--export-release', 'Linux', "`"$out`"") -NoNewWindow -PassThru
# Godot sometimes keeps running after writing the file; stop it once the file is complete.
$deadline = (Get-Date).AddMinutes(5)
while (-not $p.HasExited -and (Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 500
  if ((Test-Path $out) -and ((Get-Date) - (Get-Item $out).LastWriteTime).TotalSeconds -gt 5) { break }
}
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
if (-not (Test-Path $out)) { throw 'Godot export failed' }

Write-Host '== Packing'
& "$root\pdf_helper\gradlew.bat" -p "$root\pdf_helper" --no-daemon -q packageLinux
if ($LASTEXITCODE -ne 0) { throw 'packaging failed' }
$tgz = Get-Item "$root\build\PaperShelf-linux-x86_64.tar.gz"
Write-Host ("Done: {0} ({1:N1} MB)" -f $tgz.FullName, ($tgz.Length / 1MB))
