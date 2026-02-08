# Run existing Ubuntu Server VM with WHPX (safe CPU) -> TCG fallback
$ErrorActionPreference = 'Stop'

# --- Paths
$Base  = "C:\Users\User\Desktop\QEMU_Ubuntu"
$QEMU  = "C:\QEMU"
$Disk  = "$Base\ubuntu.qcow2"
$Share = "$Base\share"   # optional host folder

# --- Binaries
$QemuExe = @("$QEMU\qemu-system-x86_64.exe","$QEMU\qemu-system-x86_64w.exe") |
  Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $QemuExe) { throw "qemu-system-x86_64(.exe/.w.exe) not found in $QEMU" }
if (-not (Test-Path $Disk)) { throw "Disk not found: $Disk" }

# --- VM resources
$CPUs  = 4
$RAMMB = 4096
$driveNode = "if=none,id=vdisk,file=$Disk,format=qcow2,cache=writeback,discard=unmap,aio=threads"

# --- Logging
$LogDir = Join-Path $Base "logs"; New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Log    = Join-Path $LogDir ("run-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

# --- Core args (no share here)
$argsCommon = @(
  "-machine","q35",
  "-smp",$CPUs.ToString(),"-m",$RAMMB.ToString(),
  "-display","sdl",
  "-drive",$driveNode,
  "-device","virtio-blk-pci,drive=vdisk",
  "-netdev","user,id=n1,hostfwd=tcp::2222-:22",
  "-device","virtio-net-pci,netdev=n1"
)

# --- Prepare share args (we'll try once and disable if unsupported)
$ShareEnabled = $false
$ShareArgs = @()
if (Test-Path $Share) {
  $ShareEnabled = $true
  $SharePath = ($Share -replace '\\','/')  # forward slashes avoid parsing quirks
  $ShareArgs = @(
    "-fsdev","local,id=fsdev0,path=$SharePath,security_model=none,readonly=off",
    "-device","virtio-9p-pci,fsdev=fsdev0,mount_tag=hostshare"
  )
}

function Start-Qemu([string]$Accel, [string]$Cpu, [switch]$IrqchipOff, [switch]$WithShare) {
  # Treat native stderr as non-terminating during the QEMU call
  $oldEA = $ErrorActionPreference
  if ($PSVersionTable.PSEdition -ne 'Core') { $ErrorActionPreference = 'Continue' }
  try {
    $accelArg = if ($IrqchipOff) { "$Accel,kernel-irqchip=off" } else { $Accel }
    $args = @("-accel",$accelArg,"-cpu",$Cpu) + $argsCommon
    if ($WithShare -and $ShareEnabled) { $args += $ShareArgs }

    Write-Host ">>> qemu $Accel / cpu=$Cpu / share=$($WithShare -and $ShareEnabled)"
    "CMD: $QemuExe`nARGS: $($args -join ' ')" | Add-Content -Path $Log

    $qemuOut = & $QemuExe @args 2>&1 | Tee-Object -FilePath $Log -Append
    $outText = ($qemuOut | Out-String)
    return @{ Code = $LASTEXITCODE; Output = $outText }
  } finally {
    if ($PSVersionTable.PSEdition -ne 'Core') { $ErrorActionPreference = $oldEA }
  }
}

function Should-RetryWithoutShare($text) {
  # Be robust to weird spacing by stripping all whitespace and case-normalizing
  $s = ($text -replace '\s+', '').ToLowerInvariant()
  return ($s -like '*thereisnooptiongroup''fsdev''*') -or
         ($s -like '*unknownoption-fsdev*') -or
         ($s -like '*fsdevsupportisdisabled*') -or
         ($s -like '*thereisnooptiongroup''virtfs''*') -or
         ( ($s -like '*virtio-9p-pci*') -and ( ($s -like '*notfound*') -or ($s -like '*unknown*') -or ($s -like '*invalid*') ) )
}

# --- Attempts: WHPX (safer CPUs) then TCG
$attempts = @(
  @{ Accel="whpx"; Cpu="qemu64";   IrqOff=$true  },
  @{ Accel="whpx"; Cpu="Westmere"; IrqOff=$true  },
  @{ Accel="whpx"; Cpu="host";     IrqOff=$true  },
  @{ Accel="tcg,thread=multi"; Cpu="max"; IrqOff=$false }
)

$exit = 1
foreach ($a in $attempts) {
  $run = Start-Qemu -Accel $a.Accel -Cpu $a.Cpu -IrqchipOff:([bool]$a.IrqOff) -WithShare:([bool]$ShareEnabled)
  if ($run.Code -ne 0 -and $ShareEnabled -and (Should-RetryWithoutShare $run.Output)) {
    Write-Warning "9p/virtfs is not available in this QEMU build. Disabling the host share and retrying..."
    $script:ShareEnabled = $false   # <- important: disable for all subsequent attempts
    # Retry same accel/cpu immediately, without share
    $run = Start-Qemu -Accel $a.Accel -Cpu $a.Cpu -IrqchipOff:([bool]$a.IrqOff)
  }
  $exit = $run.Code
  if ($exit -eq 0) { break }
}

Write-Host "QEMU exited with code $exit. Log: $Log"
