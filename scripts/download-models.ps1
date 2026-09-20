# Download GGUF weights into .\models (not committed).
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Models = Join-Path $Root "models"
New-Item -ItemType Directory -Force -Path $Models | Out-Null

function Get-HfFile {
    param(
        [string]$Repo,
        [string]$File,
        [string]$DestName
    )
    $dest = Join-Path $Models $DestName
    if ((Test-Path $dest) -and ((Get-Item $dest).Length -gt 1MB)) {
        Write-Host "Already present: $DestName"
        return
    }
    $url = "https://huggingface.co/$Repo/resolve/main/$File"
    Write-Host "Downloading $File ..."
    $tmp = "$dest.part"
    curl.exe -L --retry 5 --retry-all-errors -C - -o $tmp $url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: $url" }
    Move-Item -Force $tmp $dest
    Write-Host "Saved $dest"
}

Get-HfFile -Repo "unsloth/Qwen3-4B-GGUF" -File "Qwen3-4B-Q4_K_M.gguf" -DestName "qwen-chat.gguf"
Get-HfFile -Repo "Qwen/Qwen3-Embedding-0.6B-GGUF" -File "Qwen3-Embedding-0.6B-Q8_0.gguf" -DestName "qwen-embed.gguf"

Write-Host "Models ready in $Models"
Get-ChildItem $Models | Format-Table Name, @{N="MB";E={[math]::Round($_.Length/1MB,1)}}
