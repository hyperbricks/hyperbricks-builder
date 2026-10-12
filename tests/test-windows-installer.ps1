param([Parameter(Mandatory=$true)][string]$Binary, [Parameter(Mandatory=$true)][string]$Tag)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$code = [IO.File]::ReadAllText((Join-Path $root 'installers/install.ps1'))
# Load the production functions without invoking the installer entry point.
. ([ScriptBlock]::Create(($code -split '# Entry point')[0]))
function Assert($Condition, [string]$Message) { if (!$Condition) { throw $Message } }
Assert ((Compare-HBVersion 'v1.10.0-beta.10' 'v1.10.0-beta.2') -gt 0) 'Numeric prerelease ordering'
Assert ((Compare-HBVersion 'v1.10.0' 'v1.10.0-beta.10') -gt 0) 'Stable ordering'
Assert (!(Test-HBVersion 'v1.0.0-beta.01')) 'Invalid numeric prerelease'
try { $null=Get-HBDownload 'https://evil.example/binary' 'unused'; throw 'UNEXPECTED_SUCCESS' }
catch { Assert ($_.Exception.Message -ne 'UNEXPECTED_SUCCESS') 'Untrusted URL accepted' }

$fixture=Join-Path ([IO.Path]::GetTempPath()) ('hb-installer-test-'+[Guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($fixture)
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $payload=Join-Path $fixture 'payload';[void][IO.Directory]::CreateDirectory($payload)
    Copy-Item $Binary (Join-Path $payload 'hyperbricks.exe')
    $name="hyperbricks_${Tag}_windows_amd64.zip"
    $archive=Join-Path $fixture $name
    [IO.Compression.ZipFile]::CreateFromDirectory($payload,$archive)
    $hash=(Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $fixture "$name.sha256"),"$hash  $name`n",[Text.UTF8Encoding]::new($false))
    $sideHash=(Get-FileHash (Join-Path $fixture "$name.sha256") -Algorithm SHA256).Hash.ToLowerInvariant()
    $assets=@()
    foreach($platform in @('darwin_amd64','darwin_arm64','linux_amd64','linux_arm64','windows_amd64')) {
        $ext=if($platform.StartsWith('windows')){'.zip'}else{'.tar.gz'}
        $assetName="hyperbricks_${Tag}_${platform}${ext}"
        $assets+=@{name=$assetName;state='uploaded';digest="sha256:$hash"}
        $assets+=@{name="$assetName.sha256";state='uploaded';digest="sha256:$sideHash"}
    }
    $release=@{tag_name=$Tag;draft=$false;assets=$assets}
    [IO.File]::WriteAllText((Join-Path $fixture 'metadata.json'),(ConvertTo-Json -InputObject @($release) -Depth 8))
    [IO.File]::WriteAllText((Join-Path $fixture 'release.json'),(ConvertTo-Json -InputObject $release -Depth 8))
    Assert ((Select-HBRelease @($release) $Tag).tag_name -ceq $Tag) 'Exact tag selection'
    try { $null=Select-HBRelease @($release) 'v99.99.99'; throw 'UNEXPECTED_SUCCESS' }
    catch { Assert ($_.Exception.Message -ne 'UNEXPECTED_SUCCESS') 'Unknown tag accepted' }
    $incomplete=@{tag_name='v99.99.99';draft=$false;assets=@()}
    Assert ((Select-HBRelease @($incomplete,$release) '').tag_name -ceq $Tag) 'Incomplete release selected'
    $draft=@{tag_name='v99.99.99';draft=$true;assets=$assets}
    Assert ((Select-HBRelease @($draft,$release) '').tag_name -ceq $Tag) 'Draft selected'
    $script:failure=''
    # Replace transport only; exercise the real selection, hashing, extraction,
    # version execution and atomic replacement against a native binary.
    function Get-HBDownload([string]$Url,[string]$Path) {
        if($script:failure -eq 'interrupted'){throw 'Simulated interrupted download'}
        if($Url.Contains('?per_page=')){$file='metadata.json'}
        elseif($Url.Contains('/releases/tags/')){$file='release.json'}
        else{$file=$Url.Substring($Url.LastIndexOf('/')+1)}
        Copy-Item (Join-Path $fixture $file) $Path
        return ''
    }
    $dest=Join-Path $fixture 'installed'
    Install-HyperBricks '' $dest
    Assert ((Get-FileHash (Join-Path $dest 'hyperbricks.exe')).Hash -eq (Get-FileHash $Binary).Hash) 'Installed binary changed'
    Install-HyperBricks $Tag $dest
    foreach($failure in @('interrupted','hash')) {
        $script:failure=$failure
        if($failure -eq 'hash'){[IO.File]::WriteAllText($archive,'corrupt')}
        try {Install-HyperBricks '' $dest;throw 'UNEXPECTED_SUCCESS'}
        catch {Assert ($_.Exception.Message -ne 'UNEXPECTED_SUCCESS') 'Failure accepted'}
        Assert ((Get-FileHash (Join-Path $dest 'hyperbricks.exe')).Hash -eq (Get-FileHash $Binary).Hash) 'Existing installation damaged'
    }
    $script:failure=''
    # Give malformed archives matching hashes, so archive validation itself is exercised.
    foreach($member in @('../hyperbricks.exe','other.exe','hyperbricks.exe/')) {
        Remove-Item $archive
        $z=[IO.Compression.ZipFile]::Open($archive,[IO.Compression.ZipArchiveMode]::Create)
        try { $null=$z.CreateEntry($member) } finally { $z.Dispose() }
        $badHash=(Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText((Join-Path $fixture "$name.sha256"),"$badHash  $name`n",[Text.UTF8Encoding]::new($false))
        $badSide=(Get-FileHash (Join-Path $fixture "$name.sha256") -Algorithm SHA256).Hash.ToLowerInvariant()
        foreach($asset in $assets) {
            if($asset.name -ceq $name){$asset.digest="sha256:$badHash"}
            if($asset.name -ceq "$name.sha256"){$asset.digest="sha256:$badSide"}
        }
        [IO.File]::WriteAllText((Join-Path $fixture 'metadata.json'),(ConvertTo-Json -InputObject @($release) -Depth 8))
        try { Install-HyperBricks '' $dest;throw 'UNEXPECTED_SUCCESS' }
        catch { Assert ($_.Exception.Message -ne 'UNEXPECTED_SUCCESS') 'Unsafe archive accepted' }
        Assert ((Get-FileHash (Join-Path $dest 'hyperbricks.exe')).Hash -eq (Get-FileHash $Binary).Hash) 'Unsafe archive damaged installation'
    }
    Write-Host 'Windows installer selection, hash checks, native execution, replacement and failure preservation passed.'
} finally { [IO.Directory]::Delete($fixture,$true) }
