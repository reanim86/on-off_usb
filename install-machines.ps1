# ============================================================================
#  install-machines.ps1
#  Run ONCE as administrator.
#  Creates scheduled tasks Machine_A / Machine_B that run as SYSTEM (elevated)
#  and grants the given normal user the right to START them.
#  Result: machine-A.bat / machine-B.bat run without admin password / UAC.
# ============================================================================
param(
    [string]$UserName = "User"
)

$ErrorActionPreference = "Stop"

$ps1 = "C:\Users\User\Documents\Machines\usb-block.ps1"
$dir = "C:\Users\User\Documents\Machines"

if (-not (Test-Path -LiteralPath $ps1)) {
    Write-Host "[ERROR] Script file not found: $ps1"
    exit 1
}

# Resolve SID of the normal user account (e.g. DESKTOP-B0OU46Q\User)
try {
    $account = New-Object System.Security.Principal.NTAccount($env:COMPUTERNAME, $UserName)
    $userSid = $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
} catch {
    Write-Host "[ERROR] Cannot resolve user '$UserName': $($_.Exception.Message)"
    exit 1
}
Write-Host "User SID: $userSid"

# SDDL: Administrators full, SYSTEM full, Users full, Authenticated Users full,
#       and explicit full access for the normal user account.
$sddl = "D:(A;;GA;;;BA)(A;;GA;;;SY)(A;;GA;;;BU)(A;;GA;;;AU)(A;;GA;;;$userSid)"

$svc = New-Object -ComObject "Schedule.Service"
$svc.Connect()
$folder = $svc.GetFolder("\")

foreach ($m in @("A", "B")) {
    $name = "Machine_$m"

    # Delete existing task so the new security descriptor is applied cleanly
    try { $folder.DeleteTask($name, 0) } catch {}

    $td = $svc.NewTask(0)

    $td.RegistrationInfo.Description = "Switch to machine $m (USB key controller)"
    $td.Principal.RunLevel = 1          # highest
    $td.Principal.LogonType = 5         # service account (SYSTEM)

    $td.Settings.Enabled = $true
    $td.Settings.AllowDemandStart = $true
    $td.Settings.StartWhenAvailable = $true
    $td.Settings.ExecutionTimeLimit = "PT5M"
    $td.Settings.DisallowStartIfOnBatteries = $false
    $td.Settings.StopIfGoingOnBatteries = $false

    $act = $td.Actions.Create(0)        # exec
    $act.Path = "powershell.exe"
    $act.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $ps1 + '" machine ' + $m
    $act.WorkingDirectory = $dir

    # flags 6 = create-or-update ; run as SYSTEM ; apply SDDL
    $folder.RegisterTaskDefinition($name, $td, 6, "SYSTEM", $null, 5, $sddl) | Out-Null
    Write-Host "[OK] Task created: $name"
}

Write-Host ""
Write-Host "Done. machine-A.bat and machine-B.bat now run without admin password."
