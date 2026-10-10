[CmdletBinding()]
param([Parameter(Mandatory)][string]$Installer, [Parameter(Mandatory)][string]$Version)
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("lithe-release-install-" + [guid]::NewGuid())
$installRoot = Join-Path $testRoot 'app'
New-Item -ItemType Directory -Path $testRoot | Out-Null
$application = $null
$setup = $null
$uninstaller = $null
function Get-InstallSnapshot {
    @(Get-ChildItem -LiteralPath $installRoot -File -Recurse | Sort-Object FullName | ForEach-Object {
        "$($_.FullName):$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
    }) -join "`n"
}
try {
    $setup = Start-Process -FilePath (Resolve-Path -LiteralPath $Installer).Path `
        -ArgumentList @('/S', "/D=$installRoot") -WindowStyle Hidden -PassThru
    if (-not $setup.WaitForExit(120000)) { throw 'Silent installation exceeded 120 seconds' }
    if ($setup.ExitCode -ne 0) { throw "Installer failed: $($setup.ExitCode)" }
    $executable = Join-Path $installRoot 'lithe-windows.exe'
    if (-not (Test-Path -LiteralPath $executable)) { throw 'Installed executable missing' }
    $actualVersion = (Get-Item -LiteralPath $executable).VersionInfo.ProductVersion
    if ($actualVersion -ne $Version) { throw "Installed version mismatch: $actualVersion" }
    $before = Get-InstallSnapshot
    $application = Start-Process -FilePath $executable -WindowStyle Hidden -PassThru
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $windowObserved = $false
    while ($clock.Elapsed.TotalSeconds -lt 20) {
        $application.Refresh()
        if ($application.HasExited) { throw "Installed app exited during startup: $($application.ExitCode)" }
        if ($application.MainWindowHandle -ne 0) { $windowObserved = $true }
        # Native GUI readiness has no event API; poll the OS window handle with a local deadline.
        Start-Sleep -Milliseconds 200
    }
    if (-not $windowObserved) { throw 'Installed app did not create a window within 20 seconds' }
    & taskkill /PID $application.Id /T /F | Out-Null
    if (-not $application.WaitForExit(5000)) { throw 'Installed app did not terminate' }
    if ((Get-InstallSnapshot) -ne $before) { throw 'Runtime modified the installation directory' }
    Write-Output 'Silent installation, version, GUI launch, cleanup, and installation SHA-256 immutability passed'
} finally {
    foreach ($owned in @($application, $setup, $uninstaller)) {
        if ($null -ne $owned -and -not $owned.HasExited) {
            & taskkill /PID $owned.Id /T /F | Out-Null
            if (-not $owned.WaitForExit(5000)) { throw "Owned process survived cleanup: $($owned.Id)" }
        }
    }
    $uninstallPath = Join-Path $installRoot 'uninstall.exe'
    if (Test-Path -LiteralPath $uninstallPath) {
        $uninstaller = Start-Process -FilePath $uninstallPath -ArgumentList '/S' -WindowStyle Hidden -PassThru
        if (-not $uninstaller.WaitForExit(30000)) {
            & taskkill /PID $uninstaller.Id /T /F | Out-Null
            $uninstaller.WaitForExit(5000) | Out-Null
            throw 'Uninstaller exceeded 30 seconds'
        }
    }
    # The target is the literal directory created above, under the OS temporary directory.
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
