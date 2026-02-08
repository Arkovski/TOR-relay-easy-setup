# One-time: create disk and boot the Ubuntu *Server* ISO using TCG (stable).
$ErrorActionPreference = 'Stop'

$Base = "C:\Users\User\Desktop\QEMU_Ubuntu"
$QEMU = "C:\QEMU"
$ISO  = "$Base\ubuntu-24.04.3-live-server-amd64.iso"   # <-- server ISO
$Disk = "$Base\ubuntu.qcow2"

$QemuExe = @("$QEMU\qemu-system-x86_64.exe","$QEMU\qemu-system-x86_64w.exe") |
  Where-Object { Test-Path $_ } | Select-Object -First 1
$QemuImg = "$QEMU\qemu-img.exe"
if (-not $QemuExe) { throw "qemu-system-x86_64(.exe/w.exe) not found in $QEMU" }
if (-not (Test-Path $QemuImg)) { throw "qemu-img.exe not found in $QEMU" }
if (-not (Test-Path $ISO)) { throw "Ubuntu Server ISO not found: $ISO" }

$LogDir = Join-Path $Base "logs"; New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Log = Join-Path $LogDir ("first-run-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

if (-not (Test-Path $Disk)) {
  & $QemuImg create -f qcow2 "$Disk" 40G *>&1 | Tee-Object -FilePath $Log -Append
  if ($LASTEXITCODE -ne 0) { throw "qemu-img failed: $LASTEXITCODE (see $Log)" }
}

$CPUs  = 4
$RAMMB = 4096
$driveNode = "if=none,id=vdisk,file=$Disk,format=qcow2,cache=writeback,discard=unmap,aio=threads"

# TCG (software), CPU=max so it boots without hypervisor
$tcgArgs = @(
  "-machine","q35",
  "-accel","tcg,thread=multi",
  "-cpu","max",
  "-smp",$CPUs.ToString(),"-m",$RAMMB.ToString(),
  "-display","sdl",                        # keep a simple install window
  "-drive",$driveNode,
  "-device","virtio-blk-pci,drive=vdisk",  # fast disk
  "-netdev","user,id=n1,hostfwd=tcp::2222-:22",
  "-device","virtio-net-pci,netdev=n1",    # virtio NIC is fine on TCG
  "-cdrom",$ISO,"-boot","d"
) | Where-Object { $_ }

& $QemuExe @tcgArgs *>&1 | Tee-Object -FilePath $Log -Append
Write-Host "Log: $Log"
Read-Host "Press Enter to close"
