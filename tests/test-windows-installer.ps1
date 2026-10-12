param([Parameter(Mandatory=$true)][string]$Binary, [Parameter(Mandatory=$true)][string]$Tag)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$code = [IO.File]::ReadAllText((Join-Path $root 'installers/install.ps1'))
# Load the production functions without invoking the installer entry point.
. ([ScriptBlock]::Create(($code -split '# Entry point')[0]))
function Assert($Condition, [string]$Message) { if (!$Condition) { throw $Message } }
Assert (!(Test-HBVersion 'v1.0.0-beta.01')) 'Invalid numeric prerelease'
try { $null=Get-HBDownload 'https://evil.example/binary' 'unused'; throw 'UNEXPECTED_SUCCESS' }
catch { Assert ($_.Exception.Message -ne 'UNEXPECTED_SUCCESS') 'Untrusted URL accepted' }

# Validate the displayed commands without changing any environment settings.
$instructions = Get-HBPathInstructions "C:\Users\O'Brien\HyperBricks"
$verifyLine = @($instructions -split "`n" | Where-Object { $_.Trim().StartsWith('& ') })[0]
$null = [ScriptBlock]::Create($verifyLine)
$commands = (($instructions -split 'user PATH:')[1] -split 'Close and reopen')[0]
$null = [ScriptBlock]::Create($commands)
Assert ($commands.Contains("O''Brien")) 'Displayed path is not safely quoted'
Assert ($commands.Contains('[Environment]::SetEnvironmentVariable')) 'Persistent PATH instruction missing'

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
    [IO.File]::WriteAllText((Join-Path $fixture 'version.md'),"$Tag`n",[Text.UTF8Encoding]::new($false))
    $script:failure=''
    $script:explicit=$false
    # Replace transport only; exercise the real selection, hashing, extraction,
    # version execution and atomic replacement against a native binary.
    function Get-HBDownload([string]$Url,[string]$Path) {
        if($script:failure -eq 'interrupted'){throw 'Simulated interrupted download'}
        Assert (!$Url.Contains('api.github.com')) 'Installer called GitHub API'
        if ($script:explicit) { Assert (!$Url.EndsWith('/version.md')) 'Explicit tag fetched version.md' }
        $file=$Url.Substring($Url.LastIndexOf('/')+1)
        Copy-Item (Join-Path $fixture $file) $Path
        return ''
    }
    $dest=Join-Path $fixture 'installed'
    Install-HyperBricks '' $dest
    Assert ((Get-FileHash (Join-Path $dest 'hyperbricks.exe')).Hash -eq (Get-FileHash $Binary).Hash) 'Installed binary changed'
    $script:explicit=$true
    Install-HyperBricks $Tag $dest
    $script:explicit=$false
    [IO.File]::WriteAllText((Join-Path $fixture 'version.md'),"invalid/version`n")
    try { Install-HyperBricks '' $dest;throw 'UNEXPECTED_SUCCESS' }
    catch { Assert ($_.Exception.Message -ne 'UNEXPECTED_SUCCESS') 'Invalid version accepted' }
    Assert ((Get-FileHash (Join-Path $dest 'hyperbricks.exe')).Hash -eq (Get-FileHash $Binary).Hash) 'Invalid version damaged installation'
    [IO.File]::WriteAllText((Join-Path $fixture 'version.md'),"$Tag`n",[Text.UTF8Encoding]::new($false))
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
        try { Install-HyperBricks '' $dest;throw 'UNEXPECTED_SUCCESS' }
        catch { Assert ($_.Exception.Message -ne 'UNEXPECTED_SUCCESS') 'Unsafe archive accepted' }
        Assert ((Get-FileHash (Join-Path $dest 'hyperbricks.exe')).Hash -eq (Get-FileHash $Binary).Hash) 'Unsafe archive damaged installation'
    }
    Write-Host 'Windows installer selection, hash checks, native execution, replacement and failure preservation passed.'
} finally { [IO.Directory]::Delete($fixture,$true) }
