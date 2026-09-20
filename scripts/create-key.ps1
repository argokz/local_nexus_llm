# Create a virtual API key via LiteLLM (same as Admin UI -> Virtual Keys).
$ErrorActionPreference = "Stop"
$envFile = Join-Path (Split-Path -Parent $PSScriptRoot) ".env"
$master = "sk-localnexus-admin"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*LITELLM_MASTER_KEY=(.+)$') { $master = $Matches[1].Trim() }
    }
}

$alias = if ($args.Count -gt 0) { $args[0] } else { "sandbox-dev" }
$body = @{
    key_alias = $alias
    models    = @("qwen-chat", "qwen-embed")
    max_budget = 10
    rpm_limit  = 4
    duration   = "30d"
} | ConvertTo-Json

$resp = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:4000/key/generate" `
    -Headers @{ Authorization = "Bearer $master" } `
    -ContentType "application/json" `
    -Body $body

Write-Host "alias : $($resp.key_alias)"
Write-Host "key   : $($resp.key)"
Write-Host "Use as: Authorization: Bearer $($resp.key)"
Write-Host "       OpenAI base_url = http://<this-pc>:4000/v1"
$resp | ConvertTo-Json -Depth 6
