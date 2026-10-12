# Verify this script's SHA-256 against the pinned GitHub copy before execution.
[CmdletBinding()]
param([string]$Version = '', [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'HyperBricks\bin'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-HBDownload([string]$Url, [string]$Path) {
    for ($redirect = 0; $redirect -le 4; $redirect++) {
        $uri = [Uri]$Url
        if ($uri.Scheme -cne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -ne '' -or
            $uri.Host -notin @('api.github.com', 'github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com')) {
            throw 'Unapproved download URL'
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $request = [Net.HttpWebRequest]::Create($uri)
        $request.AllowAutoRedirect = $false
        $request.UserAgent = 'HyperBricks-Installer'
        $request.Accept = 'application/vnd.github+json'
        $request.Headers['Cache-Control'] = 'no-cache'
        $request.Timeout = 300000
        $response = $request.GetResponse()
        try {
            $status = [int]$response.StatusCode
            if ($status -in @(301, 302, 303, 307, 308)) {
                if ($uri.Host -eq 'api.github.com') { throw 'API redirect refused' }
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
function Compare-HBNumber([string]$A, [string]$B) {
    if ($A.Length -ne $B.Length) { return [Math]::Sign($A.Length - $B.Length) }
    return [Math]::Sign([String]::CompareOrdinal($A, $B))
}
function Compare-HBVersion([string]$A, [string]$B) {
    $aParts = $A.Substring(1) -split '-', 2; $bParts = $B.Substring(1) -split '-', 2
    $aCore = $aParts[0] -split '\.'; $bCore = $bParts[0] -split '\.'
    for ($i=0; $i -lt 3; $i++) {
        $c = Compare-HBNumber $aCore[$i] $bCore[$i]; if ($c -ne 0) { return $c }
    }
    if ($aParts.Count -eq 1 -and $bParts.Count -eq 1) { return 0 }
    if ($aParts.Count -eq 1) { return 1 }; if ($bParts.Count -eq 1) { return -1 }
    $aPre = $aParts[1] -split '\.'; $bPre = $bParts[1] -split '\.'
    for ($i=0; $i -lt [Math]::Min($aPre.Count, $bPre.Count); $i++) {
        $aNum = $aPre[$i] -match '^[0-9]+$'; $bNum = $bPre[$i] -match '^[0-9]+$'
        if ($aNum -and $bNum) { $c = Compare-HBNumber $aPre[$i] $bPre[$i] }
        elseif ($aNum) { $c = -1 } elseif ($bNum) { $c = 1 }
        else { $c = [String]::CompareOrdinal($aPre[$i], $bPre[$i]) }
        if ($c -ne 0) { return [Math]::Sign($c) }
    }
    return [Math]::Sign($aPre.Count - $bPre.Count)
}
function Select-HBRelease($Releases, [string]$Wanted) {
    $best = $null
    foreach ($release in $Releases) {
        $tag = [string]$release.tag_name
        if ($release.draft -or !(Test-HBVersion $tag) -or ($Wanted -ne '' -and $tag -cne $Wanted)) { continue }
        $complete = $true
        foreach ($platform in @('darwin_amd64','darwin_arm64','linux_amd64','linux_arm64','windows_amd64')) {
            $ext = if ($platform.StartsWith('windows')) { '.zip' } else { '.tar.gz' }
            $name = "hyperbricks_${tag}_${platform}${ext}"
            foreach ($file in @($name, "$name.sha256")) {
                $assets = @($release.assets | Where-Object { $_.name -ceq $file -and $_.state -eq 'uploaded' -and $_.digest -cmatch '^sha256:[0-9a-f]{64}$' })
                if ($assets.Count -ne 1) { $complete = $false }
            }
        }
        if ($complete -and ($null -eq $best -or (Compare-HBVersion $tag $best.tag_name) -gt 0)) { $best = $release }
    }
    if ($null -eq $best) { throw 'No complete published HyperBricks release found' }
    return $best
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
        $api = 'https://api.github.com/repos/hyperbricks/hyperbricks'
        $pageFile = Join-Path $temp 'release.json'
        $releases = @()
        if ($RequestedVersion -ne '') {
            $null = Get-HBDownload "$api/releases/tags/$RequestedVersion" $pageFile
            $releases = @(Get-Content -Raw $pageFile | ConvertFrom-Json)
        } else {
            for ($page=1; $page -le 1000; $page++) {
                $link = Get-HBDownload "$api/releases?per_page=100&page=$page" $pageFile
                $releases += @(Get-Content -Raw $pageFile | ConvertFrom-Json)
                if ($link -notmatch 'rel="next"') { break }
                if ($page -eq 1000) { throw 'Release listing exceeds pagination limit' }
            }
        }
        $release = Select-HBRelease $releases $RequestedVersion
        $tag = $release.tag_name
        $name = "hyperbricks_${tag}_windows_amd64.zip"
        $archiveAsset = @($release.assets | Where-Object { $_.name -ceq $name })[0]
        $checksumAsset = @($release.assets | Where-Object { $_.name -ceq "$name.sha256" })[0]
        $base = "https://github.com/hyperbricks/hyperbricks/releases/download/$tag"
        $checksum = Join-Path $temp 'checksum'; $archive = Join-Path $temp 'archive.zip'
        $null = Get-HBDownload "$base/$name.sha256" $checksum
        if ((Get-FileHash $checksum -Algorithm SHA256).Hash.ToLowerInvariant() -cne $checksumAsset.digest.Substring(7)) { throw 'Checksum file differs from GitHub digest' }
        $line = [IO.File]::ReadAllText($checksum)
        if ($line -cnotmatch ('\A([0-9a-f]{64})  ' + [Regex]::Escape($name) + '\r?\n\z')) { throw 'Invalid checksum file' }
        $expected = $Matches[1]
        if ($expected -cne $archiveAsset.digest.Substring(7)) { throw 'Archive checksum differs from GitHub digest' }
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
        Write-Host "Add this directory to PATH if needed: $Destination"
    } finally {
        if ($stage -and [IO.File]::Exists($stage)) { [IO.File]::Delete($stage) }
        if ([IO.Directory]::Exists($temp)) { [IO.Directory]::Delete($temp, $true) }
    }
}
# Entry point
Install-HyperBricks $Version $InstallDir
