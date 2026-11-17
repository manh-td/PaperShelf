# Builds build/PaperShelf-windows-x86_64.zip.
# 1. builds the PDF helper jar, 2. exports the Godot Windows build, 3. packs everything
# with the bundled Java runtime (see the packageWindows task in pdf_helper/build.gradle).
# Usage (from the PaperShelf folder): powershell -ExecutionPolicy Bypass -File tools\build_windows.ps1
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

Write-Host '== Exporting the Windows build'
New-Item -ItemType Directory -Force "$root\build\windows" | Out-Null
$out = "$root\build\windows\PaperShelf.exe"
if (Test-Path $out) { Remove-Item $out }
$p = Start-Process -FilePath $Godot -ArgumentList @('--headless', '--path', "`"$root\app`"", '--export-release', 'Windows', "`"$out`"") -NoNewWindow -PassThru
# Godot sometimes keeps running after writing the file; stop it once the file is complete.
$deadline = (Get-Date).AddMinutes(5)
while (-not $p.HasExited -and (Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 500
  if ((Test-Path $out) -and ((Get-Date) - (Get-Item $out).LastWriteTime).TotalSeconds -gt 5) { break }
}
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
if (-not (Test-Path $out)) { throw 'Godot export failed' }

Write-Host '== Packing'
& "$root\pdf_helper\gradlew.bat" -p "$root\pdf_helper" --no-daemon -q packageWindows
if ($LASTEXITCODE -ne 0) { throw 'packaging failed' }
$zip = Get-Item "$root\build\PaperShelf-windows-x86_64.zip"
Write-Host ("Done: {0} ({1:N1} MB)" -f $zip.FullName, ($zip.Length / 1MB))
