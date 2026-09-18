[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$UnisonExe,

    [string]$Distro = 'Ubuntu-26.04',

    [switch]$KeepFixtures
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$fixtureId = [Guid]::NewGuid().ToString('N')
$fixtureBase = Join-Path ([IO.Path]::GetTempPath()) "unison-wsl-it-$fixtureId"
$windowsRoot = Join-Path $fixtureBase 'windows'
$configDir = Join-Path $fixtureBase 'config'
$linuxRoot = "/tmp/unison-wsl-it-$fixtureId"
$wslRoot = "\\wsl.localhost\$Distro\tmp\unison-wsl-it-$fixtureId"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-WslShell {
    param([Parameter(Mandatory = $true)][string]$Command)
    & wsl.exe -d $Distro -- sh -lc $Command
    if ($LASTEXITCODE -ne 0) {
        throw "WSL fixture command failed with exit code $LASTEXITCODE"
    }
}

function Invoke-WorkspaceSync {
    param([switch]$AllowFailure)

    $arguments = @(
        $windowsRoot,
        $wslRoot,
        '-wslworkspace',
        '-batch',
        '-confirmbigdel=false'
    )
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = (& $UnisonExe @arguments 2>&1 | Out-String)
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
    $exitCode = $LASTEXITCODE
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "Unison failed with exit code $exitCode`n$output"
    }
    [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Write-Utf8Bytes {
    param([string]$Path, [string]$Value)
    [IO.File]::WriteAllBytes($Path, [Text.UTF8Encoding]::new($false).GetBytes($Value))
}

if (-not (Test-Path -LiteralPath $UnisonExe -PathType Leaf)) {
    throw "Unison executable not found: $UnisonExe"
}

New-Item -ItemType Directory -Path $windowsRoot, $configDir | Out-Null
$oldUnison = $env:UNISON
$env:UNISON = $configDir

try {
    Invoke-WslShell "mkdir -p '$linuxRoot'"

    Write-Utf8Bytes (Join-Path $windowsRoot 'from-windows.txt') "windows`n"
    Invoke-WslShell "printf 'linux\n' > '$linuxRoot/from-linux.txt'"
    $null = Invoke-WorkspaceSync

    Assert-True (Test-Path (Join-Path $windowsRoot 'from-linux.txt')) `
        'Linux-to-Windows creation did not propagate'
    Assert-True (Test-Path (Join-Path $wslRoot 'from-windows.txt')) `
        'Windows-to-Linux creation did not propagate'

    New-Item -ItemType Directory -Path (Join-Path $windowsRoot '.git') | Out-Null
    Write-Utf8Bytes (Join-Path $windowsRoot '.git\windows-only') "local`n"
    Invoke-WslShell "mkdir -p '$linuxRoot/.git'; printf 'local\n' > '$linuxRoot/.git/linux-only'"
    $null = Invoke-WorkspaceSync

    Assert-True (-not (Test-Path (Join-Path $wslRoot '.git\windows-only'))) `
        'Windows .git state crossed into WSL'
    Assert-True (-not (Test-Path (Join-Path $windowsRoot '.git\linux-only'))) `
        'WSL .git state crossed into Windows'

    Write-Utf8Bytes (Join-Path $windowsRoot 'delete-vs-edit.txt') "base`n"
    $null = Invoke-WorkspaceSync
    Remove-Item -LiteralPath (Join-Path $windowsRoot 'delete-vs-edit.txt')
    Invoke-WslShell "printf 'linux edit\n' > '$linuxRoot/delete-vs-edit.txt'"
    $conflict = Invoke-WorkspaceSync -AllowFailure

    Assert-True (Test-Path (Join-Path $wslRoot 'delete-vs-edit.txt')) `
        'Deletion incorrectly destroyed the independently edited Linux file'
    Assert-True (-not (Test-Path (Join-Path $windowsRoot 'delete-vs-edit.txt'))) `
        'Conflict resolution silently recreated the deleted Windows file'
    Assert-True ($conflict.Output -match '(?i)conflict|skipped') `
        'Deletion-vs-modification was not reported as unresolved'

    Invoke-WslShell "ln -s /etc/passwd '$linuxRoot/outside-link'"
    $symlink = Invoke-WorkspaceSync -AllowFailure
    Assert-True (-not (Test-Path (Join-Path $windowsRoot 'outside-link'))) `
        'A Linux symlink escaping the WSL root was copied to Windows'
    Assert-True ($symlink.Output -match '(?i)reparse point|symbolic link') `
        'The escaping Linux symlink was not reported'

    Write-Host 'Disposable Windows/WSL workspace smoke tests passed.'
}
finally {
    $env:UNISON = $oldUnison
    if ($KeepFixtures) {
        Write-Host "Kept Windows fixture: $fixtureBase"
        Write-Host "Kept WSL fixture: $linuxRoot"
    }
    else {
        if ($fixtureBase -like "*unison-wsl-it-$fixtureId*") {
            Remove-Item -LiteralPath $fixtureBase -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($linuxRoot -match '^/tmp/unison-wsl-it-[0-9a-f]{32}$') {
            & wsl.exe -d $Distro -- rm -rf -- $linuxRoot
        }
    }
}
