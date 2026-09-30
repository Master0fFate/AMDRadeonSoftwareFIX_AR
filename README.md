# Radeon Software startup helper

A conservative replacement for this repository's old administrator/SYSTEM scheduled-task script. It helps start the **Radeon Software desktop application** for the signed-in user. It does not repair drivers, bypass permissions, or guarantee recording/overlay support in elevated games.

## Requirements

- Windows 10/11, Windows PowerShell 5.1 or PowerShell 7
- AMD Software installed with `RadeonSoftware.exe` and a valid AMD signature
- A **normal, non-administrator** PowerShell window in your desktop session
- Download both `Fix_RadeonSoftware.ps1` and `RadeonStartup.psm1` together (or clone this repository)

Review the scripts before running. If Windows blocks downloaded scripts, follow your organization's policy or review/unblock the downloaded files yourself. This helper never changes execution policy or requests elevation.

## Diagnose first (no changes)

```powershell
.\Fix_RadeonSoftware.ps1 | ConvertTo-Json -Depth 8
```

Reports discovered executable versions/signatures, matching processes, display-adapter driver versions/error codes, the old task, and whether this helper's startup link exists. Unknown/inaccessible task state is reported separately from absence. Driver version numbers are evidence, not an automatic compatibility verdict. No telemetry or automatic upload is performed; inspect diagnosis output before sharing paths or hardware details.

Discovery checks native/32-bit Program Files and AMD uninstall registration. For a custom location, pass the full executable path to Diagnose, Start or InstallStartup:

```powershell
.\Fix_RadeonSoftware.ps1 -ExecutablePath 'D:\AMD\CNext\CNext\RadeonSoftware.exe'
```

Multiple installations require explicit selection. No arbitrary registry command lines are executed.

## Try a manual launch

```powershell
.\Fix_RadeonSoftware.ps1 -Action Start -WhatIf
.\Fix_RadeonSoftware.ps1 -Action Start -Attempts 2 -TimeoutSeconds 15
```

Existing matching processes are left alone. This never kills applications or restarts drivers/services. Launch retries happen only after the launched process has exited and no matching process remains. Each attempt has a bounded observation window (5–120 seconds; 1–3 attempts). Process presence in three polls is reported as **ProcessObserved**, not healthy UI. CIM/Windows calls themselves can still take longer if Windows is unresponsive. Check the actual window, recording, overlay and games yourself. A running but invisible/unresponsive GUI is deliberately not killed or endlessly relaunched.

## Install or undo startup

First inspect Task Manager → Startup apps for existing AMD entries. Prefer the application's own startup option if it works. To add this helper's startup link:

```powershell
.\Fix_RadeonSoftware.ps1 -Action InstallStartup -WhatIf
.\Fix_RadeonSoftware.ps1 -Action InstallStartup
```

This creates `Radeon Software Startup Fix.lnk` in your Windows per-user Startup known folder. It launches the executable directly, with no stored credentials, SYSTEM account, shell arguments, administrator flag, script dependency, hidden task or execution-policy bypass. It may open the full application window; tray-only behavior is not promised. Retries apply to manual `Start`, **not** future logon launches. The AMD signature is validated at setup/manual launch time, not at every future logon.

Repeated installation replaces only this tool's marked link with a freshly generated link. A same-name unowned link is never overwritten or deleted. A failed save/validation raises an error. Uninstall AMD or move its folder? Remove the link or rerun setup with the new path.

```powershell
.\Fix_RadeonSoftware.ps1 -Action RemoveStartup -WhatIf
.\Fix_RadeonSoftware.ps1 -Action RemoveStartup
```

Undo removes only the marked startup link and works even if AMD Software is gone. It does not stop the app, restore an old legacy task, or remove AMD's own startup entries. Repeated removal is harmless. You can also inspect/remove this link yourself using `shell:startup` in Run.

### Migration from the old script

The old `RadeonSoftwareAutostart` task remains untouched. If it exists, or its presence cannot be checked, new startup setup is blocked to avoid duplicates. Open Task Scheduler, inspect that exact task and its action, export it if you want a backup, then remove it yourself only if it is the task created by this repository. Administrative rights may be needed for this old SYSTEM task. Return to a normal PowerShell window and rerun Diagnose before setup. Do not remove unrelated AMD tasks. This helper never silently elevates or changes existing tasks.

## What this cannot fix

- **Driver/software mismatch (PA-300 / error 205):** follow [AMD's compatibility guidance](https://www.amd.com/en/resources/support-articles/faqs/PA-300.html) and [error 205 guidance](https://www.amd.com/en/resources/support-articles/faqs/gpu-kb205.html). Windows Update can replace a driver; a startup shortcut does not repair that mismatch
- **No Radeon application:** AMD's Driver Only installation intentionally excludes its UI. Minimal lacks recording/capture features; current Default/full installation includes more features. See [AMD installation options](https://www.amd.com/en/resources/support-articles/faqs/RSX2-INSTALL.html)
- **Missing tray icon:** inspect AMD Software's System Tray Menu setting where available; see [AMD tray-icon guidance](https://www.amd.com/en/resources/support-articles/faqs/DH2-001.html)
- **Elevated-game capture/overlay:** the old README promised administrator behavior. This version intentionally uses your ordinary interactive token and cannot promise those features in elevated applications
- **Signature validation fails:** verify your AMD/OEM installation and Windows certificate trust. The helper does not bypass signature checks or download replacement executables

Microsoft documents [per-user startup shortcuts](https://support.microsoft.com/en-us/windows/experience/startup-boot/configure-startup-applications-in-windows) and why [services/SYSTEM are not an ordinary interactive desktop](https://learn.microsoft.com/en-us/windows/win32/services/interactive-services).

## Development and validation

```powershell
.\tests\Run-Tests.ps1
```

Dependency-free isolated tests cover discovery/selection, exact process ownership/session/path checks, shortcut ownership and reversibility, safe default/WhatIf, elevation/noninteractive rejection, legacy conflicts, bounded retries and duplicate avoidance. OS mutation boundaries are mocked. CI parses source and runs tests on Windows PowerShell 5.1 and PowerShell 7. CI has no AMD hardware and does not install startup links or launch Radeon.

Before calling a release hardware-validated, check on a real supported AMD Windows machine: Diagnose, missing/custom paths, normal manual launch, duplicate launch, logoff/logon startup, saved-link properties, old-task migration, enabled/disabled Windows startup entry, multi-user sessions, driver upgrade, removal with/without AMD installed, and recording/overlay behavior in the actual games. These are **manual validation requirements, not tests claimed to pass**.
