# Run once in the Windows guest as Administrator:
#   powershell -ExecutionPolicy Bypass -File setup-gpu-tasks.ps1
#
# Makes Windows release the passed-through iGPU cleanly, because the iGPU has no usable reset:
#  - turns off Fast Startup / hibernation (a "hybrid" shutdown skips the driver teardown)
#  - on shutdown/restart (System event 1074): disables the AMD GPU, so the driver tears down cleanly
#  - at boot: enables it again; if it comes up in an error state (e.g. Code 43), disable/enable it once
$ErrorActionPreference = 'Stop'

$dir = 'C:\ProgramData\t14s-gpu'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

@'
param([ValidateSet('disable','enable')] [string]$Action)
$log = 'C:\ProgramData\t14s-gpu\gpu.log'
function Log($m) { "$(Get-Date -Format s) $m" | Out-File -Append -FilePath $log }
$gpu = Get-PnpDevice -PresentOnly | Where-Object InstanceId -like 'PCI\VEN_1002&DEV_1638*' | Select-Object -First 1
if (-not $gpu) { Log "no AMD 1002:1638 device present"; exit 0 }
Log "$Action requested; current status=$($gpu.Status) problem=$($gpu.Problem)"
if ($Action -eq 'disable') {
    if ($gpu.Status -ne 'Error' -or $gpu.Problem -ne 'CM_PROB_DISABLED') {
        pnputil /disable-device "$($gpu.InstanceId)" | Out-Null
    }
} else {
    pnputil /enable-device "$($gpu.InstanceId)" | Out-Null
    Start-Sleep -Seconds 5
    $gpu = Get-PnpDevice -InstanceId $gpu.InstanceId
    if ($gpu.Status -eq 'Error') {
        Log "still in error ($($gpu.Problem)) -> disable, wait, enable"
        pnputil /disable-device "$($gpu.InstanceId)" | Out-Null
        Start-Sleep -Seconds 5
        pnputil /enable-device "$($gpu.InstanceId)" | Out-Null
    }
}
Log "done; status=$((Get-PnpDevice -InstanceId $gpu.InstanceId).Status)"
'@ | Set-Content -Encoding UTF8 -Path "$dir\gpu.ps1"

powercfg /hibernate off
New-ItemProperty -Force -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
    -Name HiberbootEnabled -PropertyType DWord -Value 0 | Out-Null

$ps = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dir\gpu.ps1"
schtasks /Create /F /TN 't14s-gpu\Disable on shutdown' /RU SYSTEM /RL HIGHEST `
    /SC ONEVENT /EC System /MO "*[System[Provider[@Name='User32'] and EventID=1074]]" `
    /TR "$ps -Action disable" | Out-Null
schtasks /Create /F /TN 't14s-gpu\Enable at boot' /RU SYSTEM /RL HIGHEST /SC ONSTART `
    /TR "$ps -Action enable" | Out-Null

Write-Host "Installed. Log: $dir\gpu.log. Always shut down from Start > Power (not a forced stop)."
