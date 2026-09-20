# Probe NVIDIA GPU + Docker GPU passthrough. Exit 1 if the GPU stack cannot run.
$ErrorActionPreference = "Continue"
$failed = $false

Write-Host "=== CPU / RAM ==="
Get-CimInstance Win32_Processor | Select-Object -First 1 Name, NumberOfCores, NumberOfLogicalProcessors | Format-List
Get-CimInstance Win32_ComputerSystem | Select-Object @{N="RAM_GB";E={[math]::Round($_.TotalPhysicalMemory/1GB,1)}} | Format-List

Write-Host "=== NVIDIA driver ==="
$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if (-not $smi) {
    Write-Host "nvidia-smi: NOT FOUND"
    Write-Host "Install Game Ready / Studio driver for GTX 1660 Ti."
    $failed = $true
} else {
    nvidia-smi
    if ($LASTEXITCODE -ne 0) { $failed = $true }
}

Write-Host "=== Docker ==="
$docker = Get-Command docker -ErrorAction SilentlyContinue
if (-not $docker) {
    Write-Host "docker: NOT FOUND — install Docker Desktop (WSL2 backend) and enable GPU."
    exit 1
}
docker version
docker compose version
if ($LASTEXITCODE -ne 0) { $failed = $true }

if ($failed) { exit 1 }

Write-Host "=== Docker GPU passthrough ==="
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
if ($LASTEXITCODE -ne 0) {
    Write-Host "Docker cannot see the 1660 Ti. Docker Desktop → Settings → Resources → WSL integration,"
    Write-Host "and use the WSL2 engine (not Hyper-V isolation without GPU)."
    exit 1
}
Write-Host "GPU is visible inside Docker."
