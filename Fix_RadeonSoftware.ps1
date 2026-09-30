#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Diagnose','Start','InstallStartup','RemoveStartup')][string]$Action='Diagnose',
    [string]$ExecutablePath,
    [ValidateRange(5,120)][int]$TimeoutSeconds=15,
    [ValidateRange(1,3)][int]$Attempts=2
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RadeonStartup.psm1') -Force
Invoke-RadeonStartup @PSBoundParameters
