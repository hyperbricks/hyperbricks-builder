# Verify this script's SHA-256 against the pinned GitHub copy before execution.
[CmdletBinding()]
param([string]$Version = '', [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'HyperBricks\bin'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-HBDownload([string]$Url, [string]$Path) {
    for ($redirect = 0; $redirect -le 4; $redirect++) {
        $uri = [Uri]$Url
        if ($uri.Scheme -cne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -ne '' -or
            $uri.Host -notin @('raw.githubusercontent.com', 'github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com')) {
            throw 'Unapproved download URL'
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $request = [Net.HttpWebRequest]::Create($uri)
        $request.AllowAutoRedirect = $false
        $request.UserAgent = 'HyperBricks-Installer'
        $request.Headers['Cache-Control'] = 'no-cache'
        $request.Timeout = 300000
        $response = $request.GetResponse()
        try {
            $status = [int]$response.StatusCode
            if ($status -in @(301, 302, 303, 307, 308)) {
                $Url = $response.Headers['Location']
                continue
            }
            if ($status -ne 200) { throw "Download returned HTTP $status" }
            $inputStream = $response.GetResponseStream()
            $outputStream = [IO.File]::Create($Path)
            try { $inputStream.CopyTo($outputStream) }
            finally { $outputStream.Dispose(); $inputStream.Dispose() }
            return [string]$response.Headers['Link']
        } finally { $response.Dispose() }
    }
    throw 'Too many redirects'
}
function Test-HBVersion([string]$Tag) {
    if ($Tag -cnotmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-([0-9A-Za-z-]+\.)*[0-9A-Za-z-]+)?$') { return $false }
    $parts = $Tag -split '-', 2
    if ($parts.Count -eq 2) {
        foreach ($item in ($parts[1] -split '\.')) { if ($item -match '^0[0-9]+$') { return $false } }
    }
    return $true
}
function Get-HBPathInstructions([string]$Destination) {
    $quotedBin = $Destination.Replace("'", "''")
    $quotedExecutable = (Join-Path $Destination 'hyperbricks.exe').Replace("'", "''")
    return @"

Check the installed executable:

  & '$quotedExecutable' version

If "hyperbricks version" is not recognized, add HyperBricks to your user PATH:

  `$bin = '$quotedBin'
  `$path = [Environment]::GetEnvironmentVariable("Path", "User")
  if (`$bin -notin (`$path -split ";")) {
      [Environment]::SetEnvironmentVariable("Path", "`$bin;`$path", "User")
  }

Close and reopen your terminal, then verify:

  hyperbricks version
"@
}
function Install-HyperBricks([string]$RequestedVersion, [string]$Destination) {
    if ($RequestedVersion -ne '' -and !(Test-HBVersion $RequestedVersion)) { throw 'Invalid version tag' }
    if (![IO.Path]::IsPathRooted($Destination)) { throw 'Install directory must be absolute' }
    $architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    if ($architecture -ne 'AMD64') { throw 'Windows installer currently supports amd64 only' }
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('hyperbricks-' + [Guid]::NewGuid())
    [void][IO.Directory]::CreateDirectory($temp)
    $stage = $null
    try {
        $tag = $RequestedVersion
        if ($tag -eq '') {
            $versionFile = Join-Path $temp 'version.md'
            $null = Get-HBDownload 'https://raw.githubusercontent.com/hyperbricks/hyperbricks-builder/main/version.md' $versionFile
            $text = [IO.File]::ReadAllText($versionFile)
            if ($text -cnotmatch '\Av[^\r\n]+\n?\z') { throw 'Invalid version file' }
            $tag = $text.TrimEnd([char]10)
        }
        if (!(Test-HBVersion $tag)) { throw 'Invalid version tag' }
        $name = "hyperbricks_${tag}_windows_amd64.zip"
        $base = "https://github.com/hyperbricks/hyperbricks-builder/releases/download/$tag"
        $checksum = Join-Path $temp 'checksum'; $archive = Join-Path $temp 'archive.zip'
        $null = Get-HBDownload "$base/$name.sha256" $checksum
        $line = [IO.File]::ReadAllText($checksum)
        if ($line -cnotmatch ('\A([0-9a-f]{64})  ' + [Regex]::Escape($name) + '\r?\n\z')) { throw 'Invalid checksum file' }
        $expected = $Matches[1]
        $null = Get-HBDownload "$base/$name" $archive
        if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected) { throw 'Archive SHA-256 mismatch' }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($archive)
        try {
            if ($zip.Entries.Count -ne 1 -or $zip.Entries[0].FullName -cne 'hyperbricks.exe') { throw 'Unexpected archive members' }
            $mode = ($zip.Entries[0].ExternalAttributes -shr 16) -band 0xF000
            if ($mode -ne 0 -and $mode -ne 0x8000) { throw 'Archive member is not a regular file' }
            [void][IO.Directory]::CreateDirectory($Destination)
            $target = Join-Path $Destination 'hyperbricks.exe'
            if (Test-Path $target) {
                $item = Get-Item -Force $target
                if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Refusing to replace directory or link' }
            }
            $stage = Join-Path $Destination ('.hyperbricks-' + [Guid]::NewGuid() + '.exe')
            $inputStream = $zip.Entries[0].Open(); $outputStream = [IO.File]::Open($stage, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
            try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose(); $inputStream.Dispose() }
        } finally { $zip.Dispose() }
        $output = @(& $stage version)
        if ($LASTEXITCODE -ne 0 -or $output -cnotcontains $tag) { throw 'Executable version differs from release' }
        if ([IO.File]::Exists($target)) { [IO.File]::Replace($stage, $target, [NullString]::Value) }
        else { [IO.File]::Move($stage, $target) }
        $stage = $null
        Write-Host "Installed HyperBricks ${tag}: $target"
        Write-Host (Get-HBPathInstructions $Destination)
    } finally {
        if ($stage -and [IO.File]::Exists($stage)) { [IO.File]::Delete($stage) }
        if ([IO.Directory]::Exists($temp)) { [IO.Directory]::Delete($temp, $true) }
    }
}
# Entry point
Install-HyperBricks $Version $InstallDir
