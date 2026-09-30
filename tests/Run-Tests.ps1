# Isolated boundary tests: never launch AMD, touch startup, or change Task Scheduler.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../RadeonStartup.psm1') -Force
$module = Get-Module RadeonStartup
& $module {
    $script:passed=0
    function Assert($Condition, [string]$Message) {
        if (-not $Condition) { throw "FAIL: $Message" }; $script:passed++; Write-Host "PASS: $Message"
    }
    function Assert-Throws([scriptblock]$Code, [string]$Message) {
        $failed=$false; try { & $Code } catch { $failed=$true }; Assert $failed $Message
    }
    $context=[pscustomobject]@{ Sid='test'; Session=2; Elevated=$false; Interactive=$true }
    $process=[pscustomobject]@{ Name='RadeonSoftware.exe'; SessionId=2; ExecutablePath='C:\AMD\RadeonSoftware.exe' }
    Assert (Test-OwnedProcess $process $context $process.ExecutablePath 'test') 'Exact identity matches'
    Assert (-not (Test-OwnedProcess $process $context $process.ExecutablePath 'other')) 'Other user excluded'
    $process.SessionId=3
    Assert (-not (Test-OwnedProcess $process $context $process.ExecutablePath 'test')) 'Other session excluded'
    $process.SessionId=2
    Assert (-not (Test-OwnedProcess $process $context 'C:\other\RadeonSoftware.exe' 'test')) 'Same name at another path excluded'
    Assert-Throws { Select-Installation @() } 'Missing install rejected'
    Assert-Throws { Select-Installation @(1,2) } 'Ambiguous install rejected'
    Assert ((Select-Installation @('one')) -eq 'one') 'Single install accepted'
    $root=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    try {
        New-Item -ItemType Directory -Path $root | Out-Null
        $exe=Join-Path $root 'RadeonSoftware.exe'
        New-Item -ItemType File -Path $exe | Out-Null
        Assert (@(Get-Installations $exe).Count -eq 1) 'Explicit executable discovered'
        Assert (@(Get-Installations (Join-Path $root 'missing')).Count -eq 0) 'Missing explicit executable not guessed'
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    Assert (@(Get-Installations).Count -ge 0) 'Default discovery tolerates missing registry records'
    # Real legacy-task discovery distinguishes absence, duplicates and access failures.
    function Get-Command { [pscustomobject]@{ Name='Get-ScheduledTask' } }
    function Get-ScheduledTask { @([pscustomobject]@{ TaskName='RadeonSoftwareAutostart'; State='Ready'; Principal='SYSTEM'; Actions='old' }, [pscustomobject]@{ TaskName='other'; State='Ready'; Principal='user'; Actions='other' }) }
    Assert ((Get-LegacyTask).Tasks.Count -eq 1) 'Only the exact legacy task is reported'
    function Get-ScheduledTask { @() }
    Assert ((Get-LegacyTask).Status -eq 'Checked' -and (Get-LegacyTask).Tasks.Count -eq 0) 'No legacy task reported as checked absence'
    function Get-ScheduledTask { throw 'Access denied' }
    Assert ((Get-LegacyTask).Status -eq 'Unknown') 'Task access failure is never called absence'
    function Get-Command { $null }
    Assert ((Get-LegacyTask).Status -eq 'Unavailable') 'Missing task cmdlet reported separately'
    $script:exists=$false
    $script:shortcut=[pscustomobject]@{ TargetPath=''; WorkingDirectory=''; Arguments='old'; Description=''; WindowStyle=0 }
    $script:shortcut | Add-Member ScriptMethod Save { $script:exists=$true }
    function Get-ShortcutPath { Join-Path ([IO.Path]::GetTempPath()) 'fake-startup.lnk' }
    function Read-Shortcut { $script:shortcut }
    function Release-Shortcut {}
    function Test-Path { param([string]$LiteralPath, [string]$PathType); if ($PathType -eq 'Container') { return $true }; $script:exists }
    function Remove-Item { param([string]$LiteralPath); if ((Split-Path -Leaf $LiteralPath) -eq 'fake-startup.lnk') { $script:exists=$false } }
    function Move-Item { param($LiteralPath, $Destination, [switch]$Force); if ($LiteralPath -eq $Destination) { throw 'Expected a fresh staged shortcut' } }
    $install=[pscustomobject]@{ Executable='C:\AMD & Test\RadeonSoftware.exe'; Directory='C:\AMD & Test'; Version='test' }
    Assert ((Set-RadeonStartup $install) -eq 'Installed') 'Owned startup link installed'
    Assert ($script:shortcut.Arguments -eq '' -and $script:shortcut.TargetPath -eq $install.Executable) 'Direct launch without shell parsing'
    Assert ((Set-RadeonStartup $install) -eq 'Installed') 'Repeated install idempotent'
    $script:shortcut.Description='foreign'
    Assert-Throws { Set-RadeonStartup $install } 'Foreign shortcut cannot be overwritten'
    Assert-Throws { Set-RadeonStartup -Remove } 'Foreign shortcut cannot be removed'
    $script:shortcut.Description=$script:ShortcutMarker
    Assert ((Set-RadeonStartup -Remove) -eq 'Removed') 'Owned shortcut removed'
    Assert ((Set-RadeonStartup -Remove) -eq 'NotInstalled') 'Repeated removal idempotent'
    # Failed readback must never reach replacement, and staged cleanup is attempted.
    $script:exists=$false; $script:moves=0; $script:cleanups=0
    function Move-Item { $script:moves++ }
    function Remove-Item { $script:cleanups++; $script:exists=$false }
    $script:shortcut | Add-Member ScriptMethod Save { $script:exists=$true; $this.TargetPath='wrong' } -Force
    Assert-Throws { Set-RadeonStartup $install } 'Invalid shortcut readback fails closed'
    Assert ($script:moves -eq 0 -and $script:cleanups -eq 1) 'Invalid staged link cleaned without replacing destination'
    $script:exists=$false
    function Remove-Item { throw 'Cleanup denied' }
    Assert-Throws { Set-RadeonStartup $install } 'Cleanup failure is surfaced'
    $script:signature=[pscustomobject]@{ Trusted=$false; Status='NotSigned'; Publisher='' }
    function Get-Signature { $script:signature }
    Assert-Throws { Assert-TrustedInstallation $install } 'Untrusted executable blocked'
    $script:signature.Trusted=$true
    Assert-TrustedInstallation $install
    function Assert-Windows {}
    $script:ctx=$context
    function Get-Context { $script:ctx }
    function Get-Installations { $install }
    function Get-LegacyTask { [pscustomobject]@{ Status=$script:legacyStatus; Tasks=$script:legacyTasks } }
    $script:legacyStatus='Checked'; $script:legacyTasks=@()
    $script:owned=@(); $script:starts=0; $script:writes=0; $script:waitResult='Observed'
    function Get-OwnedProcesses { $script:owned }
    function Set-RadeonStartup { $script:writes++; 'Installed' }
    function Start-Radeon { $script:starts++; $null }
    Assert ((Wait-Radeon $context $install 0 $null) -eq 'Unstable') 'Missing launch handle cannot authorize retry'
    Assert ((Wait-Radeon $context $install 0 ([pscustomobject]@{ HasExited=$false })) -eq 'Unstable') 'Running launch handle prevents retry'
    Assert ((Wait-Radeon $context $install 0 ([pscustomobject]@{ HasExited=$true })) -eq 'Exited') 'Confirmed exit allows bounded retry'
    $script:owned=@('handoff')
    Assert ((Wait-Radeon $context $install 0 ([pscustomobject]@{ HasExited=$true })) -eq 'Unstable') 'Handoff process prevents retry'
    $script:owned=@()
    function Wait-Radeon { $script:waitResult }
    function Get-Audit { [pscustomobject]@{ Action='Diagnose' } }
    Assert ((Invoke-RadeonStartup).Action -eq 'Diagnose') 'Default action is read-only diagnosis'
    Invoke-RadeonStartup -Action Start -WhatIf
    Invoke-RadeonStartup -Action InstallStartup -WhatIf
    Invoke-RadeonStartup -Action RemoveStartup -WhatIf
    Assert ($script:starts -eq 0 -and $script:writes -eq 0) 'WhatIf performs no launch or startup writes'
    $script:ctx.Elevated=$true
    Assert-Throws { Invoke-RadeonStartup -Action Start } 'Elevated launch refused'
    $script:ctx.Elevated=$false; $script:ctx.Interactive=$false
    Assert-Throws { Invoke-RadeonStartup -Action Start } 'Noninteractive launch refused'
    $script:ctx.Interactive=$true; $script:ctx.Session=0
    Assert-Throws { Invoke-RadeonStartup -Action InstallStartup } 'Session zero refused'
    $script:ctx.Session=2
    $script:legacyTasks=@('old')
    Assert-Throws { Invoke-RadeonStartup -Action InstallStartup } 'Legacy task prevents duplicate setup'
    $script:legacyTasks=@(); $script:legacyStatus='Unknown'
    Assert-Throws { Invoke-RadeonStartup -Action InstallStartup } 'Unknown legacy task state blocks setup'
    $script:legacyStatus='Checked'
    $script:owned=@('existing')
    Assert ((Invoke-RadeonStartup -Action Start).Result -eq 'AlreadyRunning') 'Existing process not relaunched or stopped'
    Assert ($script:starts -eq 0) 'No launch for existing process'
    $script:owned=@()
    Assert ((Invoke-RadeonStartup -Action Start).Result -eq 'ProcessObserved') 'Stable process observation reported honestly'
    $script:starts=0; $script:waitResult='Exited'
    Assert-Throws { Invoke-RadeonStartup -Action Start -Attempts 3 } 'Exhausted launch attempts fail clearly'
    Assert ($script:starts -eq 3) 'Retries bounded by requested attempt limit'
    $script:starts=0; $script:waitResult='Unstable'
    Assert-Throws { Invoke-RadeonStartup -Action Start -Attempts 3 } 'Unstable running process fails without retry'
    Assert ($script:starts -eq 1) 'Unstable running process never duplicated'
    function Get-Installations { throw 'Discovery should not run' }
    Assert ((Invoke-RadeonStartup -Action RemoveStartup).Result -eq 'Installed') 'Undo independent of application discovery'
    Write-Host "All $script:passed isolated tests passed."
}
