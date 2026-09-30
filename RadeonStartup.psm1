Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ShortcutName = 'Radeon Software Startup Fix.lnk'
$script:ShortcutMarker = 'AMDRadeonSoftwareFIX_AR: per-user startup v2'

function Assert-Windows {
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { throw 'This tool requires Windows.' }
}
function Get-Context {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    [pscustomobject]@{ Sid = $identity.User.Value; Session = (Get-Process -Id $PID).SessionId
        Interactive = [Environment]::UserInteractive; Elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
}
function Get-Installations {
    param([string]$ExecutablePath)
    $candidates = @()
    if ($ExecutablePath) { $candidates = @($ExecutablePath) }
    else {
        foreach ($root in @($env:ProgramFiles, ${env:ProgramW6432}, ${env:ProgramFiles(x86)})) {
            if ($root) { $candidates += Join-Path $root 'AMD/CNext/CNext/RadeonSoftware.exe' }
        }
        foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
            Get-ItemProperty $key -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match '^AMD (Software|Radeon)' -and
                    $_.PSObject.Properties['InstallLocation'] -and $_.InstallLocation) {
                    foreach ($relative in @('RadeonSoftware.exe','CNext/RadeonSoftware.exe','CNext/CNext/RadeonSoftware.exe')) {
                        $candidates += Join-Path $_.InstallLocation $relative
                    }
                }
            }
        }
    }
    $seen = @{}
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $file = Get-Item -LiteralPath $candidate
            if ($file.Name -ine 'RadeonSoftware.exe') { continue }
            if (-not $seen.ContainsKey($file.FullName)) {
                $seen[$file.FullName] = $true
                [pscustomobject]@{ Executable = $file.FullName; Directory = $file.DirectoryName; Version = $file.VersionInfo.FileVersion }
            }
        }
    }
}
function Select-Installation {
    param([object[]]$Installations)
    if ($Installations.Count -eq 0) { throw 'RadeonSoftware.exe was not found. Install AMD Software or specify -ExecutablePath. Driver-only installations have no GUI.' }
    if ($Installations.Count -ne 1) { throw 'Multiple installations found. Select one with -ExecutablePath.' }
    $Installations[0]
}
function Get-Signature {
    param([string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $publisher = if ($signature.SignerCertificate) { $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) } else { '' }
    [pscustomobject]@{ Status = [string]$signature.Status; Publisher = $publisher
        Trusted = ($signature.Status -eq 'Valid' -and $publisher -in @('Advanced Micro Devices, Inc.','Advanced Micro Devices Inc.')) }
}
function Assert-TrustedInstallation {
    param($Installation)
    $signature = Get-Signature $Installation.Executable
    if (-not $signature.Trusted) { throw "Executable must have a valid AMD signature. Status: $($signature.Status); publisher: $($signature.Publisher). No changes made." }
}
function Test-OwnedProcess {
    param($Process, $Context, [string]$Executable, [string]$OwnerSid)
    return ($Process.Name -ieq 'RadeonSoftware.exe' -and $Process.SessionId -eq $Context.Session -and
        $OwnerSid -eq $Context.Sid -and $Process.ExecutablePath -and
        [string]::Equals($Process.ExecutablePath, $Executable, [StringComparison]::OrdinalIgnoreCase))
}
function Get-OwnedProcesses {
    param($Context, [string]$Executable)
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='RadeonSoftware.exe'")) {
        # Fail closed on an unreadable process in this session to avoid duplicate launches.
        if ($process.SessionId -ne $Context.Session) { continue }
        $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid
        if ($owner.ReturnValue -ne 0 -or -not $process.ExecutablePath) { throw 'Cannot verify an existing Radeon process. Close AMD Software manually and retry.' }
        if (Test-OwnedProcess $process $Context $Executable $owner.Sid) { $process }
    }
}
function Start-Radeon {
    param($Installation)
    Start-Process -FilePath $Installation.Executable -WorkingDirectory $Installation.Directory -PassThru -ErrorAction Stop
}
function Wait-Radeon {
    param($Context, $Installation, [int]$TimeoutSeconds, $LaunchedProcess)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $stable = 0
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (@(Get-OwnedProcesses $Context $Installation.Executable).Count -gt 0) { $stable++ } else { $stable = 0 }
        if ($stable -ge 3) { return 'Observed' }
        Start-Sleep -Seconds 1
    }
    # The launcher may hand off to another process; check both before permitting a retry.
    if (@(Get-OwnedProcesses $Context $Installation.Executable).Count -gt 0) { return 'Unstable' }
    if (-not $LaunchedProcess -or -not $LaunchedProcess.HasExited) { return 'Unstable' }
    return 'Exited'
}
function Get-ShortcutPath {
    $folder = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup, [Environment+SpecialFolderOption]::DoNotVerify)
    if (-not $folder -or -not [IO.Path]::IsPathRooted($folder)) { throw 'Windows did not provide a valid per-user Startup folder.' }
    Join-Path $folder $script:ShortcutName
}
function Read-Shortcut {
    param([string]$Path)
    $shell = New-Object -ComObject WScript.Shell
    try { $shell.CreateShortcut($Path) } finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
}
function Release-Shortcut { param($Shortcut); [void][Runtime.InteropServices.Marshal]::ReleaseComObject($Shortcut) }
function Set-RadeonStartup {
    param($Installation, [switch]$Remove)
    $path = Get-ShortcutPath
    if (Test-Path -LiteralPath $path) {
        $existing = Read-Shortcut $path
        try {
            if ($existing.Description -ne $script:ShortcutMarker) { throw "Refusing to replace or remove an unowned shortcut: $path" }
        } finally { Release-Shortcut $existing }
    } elseif ($Remove) { return 'NotInstalled' }
    if ($Remove) { Remove-Item -LiteralPath $path -ErrorAction Stop; return 'Removed' }
    $folder = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null }
    # Fresh link prevents inheriting hidden flags (including Run as administrator).
    $temporary = Join-Path (Split-Path -Parent $path) (([guid]::NewGuid().ToString()) + '.lnk')
    try {
        $shortcut = Read-Shortcut $temporary
        try {
            $shortcut.TargetPath = $Installation.Executable
            $shortcut.WorkingDirectory = $Installation.Directory
            $shortcut.Arguments = ''
            $shortcut.Description = $script:ShortcutMarker
            $shortcut.WindowStyle = 1
            $shortcut.Save()
        } finally { Release-Shortcut $shortcut }
        $saved = Read-Shortcut $temporary
        try {
            if ($saved.TargetPath -ine $Installation.Executable -or $saved.WorkingDirectory -ine $Installation.Directory -or
                $saved.Arguments -ne '' -or $saved.Description -ne $script:ShortcutMarker) { throw 'Saved startup shortcut did not match the requested configuration.' }
        } finally { Release-Shortcut $saved }
        if (-not (Test-Path -LiteralPath $temporary)) { throw 'Windows did not save the startup shortcut.' }
        # Recheck ownership before replacement; never overwrite another startup entry.
        if (Test-Path -LiteralPath $path) {
            $existing = Read-Shortcut $path
            try {
                if ($existing.Description -ne $script:ShortcutMarker) { throw 'Startup shortcut changed during setup; refusing replacement.' }
            } finally { Release-Shortcut $existing }
        }
        Move-Item -LiteralPath $temporary -Destination $path -Force -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -ErrorAction Stop }
    }
    return 'Installed'
}
function Get-LegacyTask {
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return [pscustomobject]@{ Status='Unavailable'; Tasks=@() } }
    try {
        # Enumerate first: a missing named task is otherwise a terminating CIM error.
        $tasks = @(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop | Where-Object TaskName -eq 'RadeonSoftwareAutostart')
        return [pscustomobject]@{ Status='Checked'; Tasks=@($tasks | Select-Object TaskName, State, Principal, Actions) }
    } catch { return [pscustomobject]@{ Status='Unknown'; Tasks=@(); Error=$_.Exception.Message } }
}
function Get-Audit {
    param($Context, [object[]]$Installations)
    $warnings = @()
    $drivers = @()
    try { $drivers = @(Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, DriverDate, ConfigManagerErrorCode) }
    catch { $warnings += "Driver query failed: $($_.Exception.Message)" }
    $entries = @()
    foreach ($installation in $Installations) {
        try { $signature = Get-Signature $installation.Executable } catch { $signature = [pscustomobject]@{ Status='Unknown'; Publisher=''; Trusted=$false }; $warnings += $_.Exception.Message }
        $processes = @()
        try { $processes = @(Get-OwnedProcesses $Context $installation.Executable | Select-Object ProcessId, ExecutablePath, SessionId) }
        catch { $warnings += $_.Exception.Message }
        $entries += [pscustomobject]@{ Executable=$installation.Executable; Version=$installation.Version; Signature=$signature; Processes=$processes }
    }
    [pscustomobject]@{ Action='Diagnose'; Elevated=$Context.Elevated; Session=$Context.Session; Installations=$entries
        VideoControllers=$drivers; LegacyTask=(Get-LegacyTask); StartupShortcutPresent=(Test-Path -LiteralPath (Get-ShortcutPath))
        Warnings=$warnings; Health='NotAssessed'
        Note='Process presence does not prove GUI, recording or overlay health. Startup does not repair incompatible drivers (AMD PA-300/205).' }
}
function Invoke-RadeonStartup {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [ValidateSet('Diagnose','Start','InstallStartup','RemoveStartup')][string]$Action='Diagnose',
        [string]$ExecutablePath,
        [ValidateRange(5,120)][int]$TimeoutSeconds=15,
        [ValidateRange(1,3)][int]$Attempts=2
    )
    Assert-Windows
    $context = Get-Context
    if ($Action -eq 'Diagnose') { return Get-Audit $context @(Get-Installations $ExecutablePath) }
    if ($context.Elevated -or $context.Session -eq 0 -or -not $context.Interactive) { throw 'Use a normal, non-administrator PowerShell window in your signed-in desktop session.' }
    if ($Action -eq 'RemoveStartup') {
        if ($PSCmdlet.ShouldProcess((Get-ShortcutPath), 'Remove this tool''s startup shortcut')) {
            return [pscustomobject]@{ Action=$Action; Result=(Set-RadeonStartup -Remove) }
        }
        return
    }
    $installation = Select-Installation @(Get-Installations $ExecutablePath)
    Assert-TrustedInstallation $installation
    if ($Action -eq 'InstallStartup') {
        $legacy = Get-LegacyTask
        if ($legacy.Status -ne 'Checked' -or $legacy.Tasks.Count -gt 0) {
            throw 'Legacy task exists or could not be checked. Run Diagnose and inspect/remove the old RadeonSoftwareAutostart task manually before adding startup.'
        }
        Write-Warning 'Check Task Manager Startup apps for duplicate AMD entries first. This shortcut launches directly at logon, without retries or elevation.'
        if ($PSCmdlet.ShouldProcess((Get-ShortcutPath), "Create current-user startup shortcut for $($installation.Executable)")) {
            return [pscustomobject]@{ Action=$Action; Result=(Set-RadeonStartup $installation) }
        }
        return
    }
    if (@(Get-OwnedProcesses $context $installation.Executable).Count -gt 0) {
        return [pscustomobject]@{ Action=$Action; Result='AlreadyRunning'; Note='Open the existing AMD Software window manually; no process was stopped.' }
    }
    if (-not $PSCmdlet.ShouldProcess($installation.Executable, "Launch Radeon Software (at most $Attempts attempts, $TimeoutSeconds seconds observation each)")) { return }
    for ($attempt=1; $attempt -le $Attempts; $attempt++) {
        # Recheck just before each launch, including retries.
        if (@(Get-OwnedProcesses $context $installation.Executable).Count -gt 0) { throw 'Radeon started concurrently. No additional instance launched.' }
        Assert-TrustedInstallation $installation
        $launched = Start-Radeon $installation
        try { $result = Wait-Radeon $context $installation $TimeoutSeconds $launched }
        finally { if ($launched) { $launched.Dispose() } }
        if ($result -eq 'Observed') {
            return [pscustomobject]@{ Action=$Action; Result='ProcessObserved'; Attempt=$attempt
                Note='Observed in 3 consecutive polls. Verify the window, recording and overlay manually.' }
        }
        if ($result -ne 'Exited') { throw 'Radeon is still running but was not observed stably. No duplicate launch attempted; inspect the UI manually.' }
    }
    throw 'Radeon exited or failed to appear before timeout. Run Diagnose; check AMD PA-300/205 and the installed driver. No driver or service was changed.'
}
Export-ModuleMember -Function Invoke-RadeonStartup
