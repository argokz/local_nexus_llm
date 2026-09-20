# Download GGUF weights into .\models (not committed).
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Models = Join-Path $Root "models"
New-Item -ItemType Directory -Force -Path $Models | Out-Null

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
Import-NexusEnv (Join-Path $Root "host.auto.env")
if ($env:NEXUS_ENV_FILE -and (Test-Path $env:NEXUS_ENV_FILE)) {
    Import-NexusEnv $env:NEXUS_ENV_FILE
}

$ChatRepo = if ($env:CHAT_HF_REPO) { $env:CHAT_HF_REPO } else { "unsloth/Qwen3-4B-GGUF" }
$ChatFile = if ($env:CHAT_HF_FILE) { $env:CHAT_HF_FILE } else { "Qwen3-4B-Q4_K_M.gguf" }
$ChatDest = if ($env:CHAT_GGUF) { $env:CHAT_GGUF } else { "qwen-chat.gguf" }
$EmbedRepo = if ($env:EMBED_HF_REPO) { $env:EMBED_HF_REPO } else { "Qwen/Qwen3-Embedding-0.6B-GGUF" }
$EmbedFile = if ($env:EMBED_HF_FILE) { $env:EMBED_HF_FILE } else { "Qwen3-Embedding-0.6B-Q8_0.gguf" }
$EmbedDest = if ($env:EMBED_GGUF) { $env:EMBED_GGUF } else { "qwen-embed.gguf" }

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

Get-HfFile -Repo $ChatRepo -File $ChatFile -DestName $ChatDest
Get-HfFile -Repo $EmbedRepo -File $EmbedFile -DestName $EmbedDest

Write-Host "Models ready in $Models"
Get-ChildItem $Models | Format-Table Name, @{N="MB";E={[math]::Round($_.Length/1MB,1)}}
