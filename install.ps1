# Installs or updates all Highflight VLC subtitle extensions (Windows).
#
# One-liner (PowerShell):
#   irm https://raw.githubusercontent.com/KiritoSenpaiCZ/VLC-Subtitles/main/install.ps1 | iex
#
# Or from a downloaded/cloned copy of the repo:
#   powershell -ExecutionPolicy Bypass -File install.ps1
#
# Run it again any time to update. Only the extension files are replaced;
# saved logins, tokens and downloaded subtitles are left alone.

$ErrorActionPreference = 'Stop'

$Extensions = @('hiyori', 'wosir', 'edna', 'kamui', 'titulky', 'legiekondor', 'nyasub', 'hanabi')
$RawBase = 'https://raw.githubusercontent.com/KiritoSenpaiCZ/VLC-Subtitles/main/extensions'
$Dest = Join-Path $env:APPDATA 'vlc\lua\extensions'

# version = "1.2.3" / VERSION = "1.2.3" inside an extension file, or $null
function Get-ExtVersion([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $m = Select-String -LiteralPath $Path -Pattern '(?i)\bversion\s*=\s*"([0-9][0-9.]*)"' | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return $null
}

# Local mode when this script sits next to an extensions\ folder (cloned or
# downloaded repo); otherwise (e.g. run through "irm | iex") download.
$LocalDir = $null
if ($PSScriptRoot) {
    $candidate = Join-Path $PSScriptRoot 'extensions'
    if (Test-Path -LiteralPath $candidate) { $LocalDir = $candidate }
}

if (-not $LocalDir) {
    # Windows PowerShell 5.1 may default to old TLS versions GitHub refuses
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

Write-Host ''
Write-Host 'Highflight VLC subtitle extensions' -ForegroundColor Cyan
Write-Host "Installing into: $Dest"
if ($LocalDir) { Write-Host "Source: $LocalDir" } else { Write-Host 'Source: GitHub (KiritoSenpaiCZ/VLC-Subtitles)' }
Write-Host ''

New-Item -ItemType Directory -Force -Path $Dest | Out-Null

$failed = 0
foreach ($name in $Extensions) {
    $file = "$name.lua"
    $target = Join-Path $Dest $file
    $tmp = Join-Path $Dest "$file.download"
    try {
        if ($LocalDir) {
            Copy-Item -LiteralPath (Join-Path $LocalDir $file) -Destination $tmp -Force
        } else {
            Invoke-WebRequest -UseBasicParsing -Uri "$RawBase/$file" -OutFile $tmp
        }
        # sanity check before replacing anything: a real VLC extension
        if (-not (Select-String -LiteralPath $tmp -Pattern 'function descriptor' -Quiet)) {
            throw 'the file does not look like a VLC extension'
        }
        $old = Get-ExtVersion $target
        $new = Get-ExtVersion $tmp
        Move-Item -LiteralPath $tmp -Destination $target -Force
        if (-not $old) {
            Write-Host ("  {0,-12} installed {1}" -f $name, $new) -ForegroundColor Green
        } elseif ($old -ne $new) {
            Write-Host ("  {0,-12} updated {1} -> {2}" -f $name, $old, $new) -ForegroundColor Green
        } else {
            Write-Host ("  {0,-12} up to date ({1})" -f $name, $new)
        }
    } catch {
        $failed++
        Write-Host ("  {0,-12} FAILED: {1}" -f $name, $_.Exception.Message) -ForegroundColor Red
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host ''
if ($failed -gt 0) {
    Write-Host "$failed extension(s) failed, the rest are installed. Run the installer again to retry." -ForegroundColor Yellow
} else {
    Write-Host 'All done.' -ForegroundColor Green
}
if (Get-Process -Name vlc -ErrorAction SilentlyContinue) {
    Write-Host 'VLC is running: close it completely and start it again to load the changes.' -ForegroundColor Yellow
} else {
    Write-Host 'Start VLC and open the extensions from the View menu.'
}
Write-Host ''
