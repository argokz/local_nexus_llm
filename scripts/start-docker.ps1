# Full Docker stack for GTX 1660 Ti 6GB + 32GB RAM (env/gpu-1660ti.env).
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
$EnvFile = Join-Path $Root "env\gpu-1660ti.env"

if ($args -contains "stop") {
    docker compose --env-file $EnvFile -f docker-compose.yml -f docker-compose.gpu.yml --profile stt down
    Write-Host "docker stack stopped (volumes kept)"
    exit 0
}

if (-not (Test-Path $EnvFile)) { throw "missing $EnvFile" }

& (Join-Path $PSScriptRoot "gpu-check.ps1")
if ($LASTEXITCODE -ne 0) { throw "GPU/Docker check failed" }

function Import-NexusEnv([string]$path) {
    if (-not (Test-Path $path)) { return }
    Get-Content $path | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq "" -or $line.StartsWith("#") -or $line -notmatch "=") { return }
        $k, $v = $line.Split("=", 2)
        Set-Item -Path "Env:$($k.Trim())" -Value $v.Trim()
    }
}
Import-NexusEnv (Join-Path $Root ".env")
$env:NEXUS_ENV_FILE = $EnvFile
Import-NexusEnv $EnvFile

& (Join-Path $PSScriptRoot "download-models.ps1")

Write-Host "Starting GPU compose (first CUDA llama.cpp build is 10-20 min) ..."
docker compose --env-file $EnvFile -f docker-compose.yml -f docker-compose.gpu.yml --profile stt up --build -d

Write-Host ""
Write-Host "=== docker stack up ==="
Write-Host "API      http://127.0.0.1:4000/v1"
Write-Host "Admin UI http://127.0.0.1:4000/ui"
Write-Host "Logs     docker compose -f docker-compose.yml -f docker-compose.gpu.yml logs -f llm"
Write-Host "Smoke    .\scripts\smoke-test.ps1"
Write-Host "Stop     .\scripts\start-docker.ps1 stop"
