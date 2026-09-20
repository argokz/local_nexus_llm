# End-to-end sandbox check: LiteLLM health, models, chat, embeddings, RAG.
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Get-DotEnv([string]$name, [string]$default) {
    $file = Join-Path $Root ".env"
    if (Test-Path $file) {
        foreach ($line in Get-Content $file) {
            if ($line -match "^\s*$([regex]::Escape($name))=(.+)$") {
                return $Matches[1].Trim()
            }
        }
    }
    return $default
}

function Invoke-Psql([string]$sql) {
    $sql | docker compose exec -T db psql -U nexus -d nexus -v ON_ERROR_STOP=1
}

function Get-Embedding([string]$text) {
    $body = @{ model = "qwen-embed"; input = $text } | ConvertTo-Json
    $emb = Invoke-RestMethod -Method Post -Uri "$base/v1/embeddings" `
        -Headers $headers -ContentType "application/json" -Body $body -TimeoutSec 90
    return $emb.data[0].embedding
}

function Format-Vector($values) {
    return "[" + (($values | ForEach-Object { $_.ToString("G9", [cultureinfo]::InvariantCulture) }) -join ",") + "]"
}

$master = Get-DotEnv "LITELLM_MASTER_KEY" "sk-localnexus-admin"
$headers = @{ Authorization = "Bearer $master" }
$base = "http://127.0.0.1:4000"

Write-Host "== wait for LiteLLM =="
$ready = $false
foreach ($i in 1..60) {
    try {
        Invoke-RestMethod -Uri "$base/health/liveliness" -TimeoutSec 5 | Out-Null
        $ready = $true
        break
    } catch {
        Start-Sleep -Seconds 5
    }
}
if (-not $ready) { throw "LiteLLM is not up on $base" }

Write-Host "== /v1/models =="
$models = Invoke-RestMethod -Uri "$base/v1/models" -Headers $headers
$models.data | ForEach-Object { $_.id }

Write-Host "== chat (may take 1-2 min on this CPU) =="
$chatBody = @{
    model       = "qwen-chat"
    max_tokens  = 32
    temperature = 0
    messages    = @(
        @{ role = "user"; content = "Reply with exactly one word: pong" }
    )
} | ConvertTo-Json -Depth 6
$chat = Invoke-RestMethod -Method Post -Uri "$base/v1/chat/completions" `
    -Headers $headers -ContentType "application/json" -Body $chatBody -TimeoutSec 180
Write-Host $chat.choices[0].message.content
Write-Host ""

Write-Host "== embeddings =="
$probe = Get-Embedding "localNexus sandbox"
Write-Host ("dim={0}" -f $probe.Count)

Write-Host "== RAG ingest/query =="
Invoke-Psql "TRUNCATE chunks;"
$docs = @(
    "localNexus is a local AI sandbox: LiteLLM proxy in front of llama.cpp, embeddings, and Postgres pgvector.",
    "Clients call a single OpenAI-compatible endpoint at port 4000. Virtual API keys are created in the LiteLLM admin UI.",
    "This sandbox runs on CPU. Whisper and HuggingFace TEI are optional compose profiles for later hardware."
)
foreach ($doc in $docs) {
    $vec = Format-Vector (Get-Embedding $doc)
    $escaped = $doc.Replace("'", "''")
    Invoke-Psql "INSERT INTO chunks (content, embedding, metadata) VALUES ('$escaped', '$vec'::vector, '{""source"":""smoke""}'::jsonb);"
}

$question = "What is localNexus and which port do clients use?"
$qvec = Format-Vector (Get-Embedding $question)
$retrieved = docker compose exec -T db psql -U nexus -d nexus -At -c @"
SELECT content FROM chunks ORDER BY embedding <=> '$qvec'::vector LIMIT 3;
"@
Write-Host "retrieved:"
Write-Host $retrieved

$context = ($retrieved -split "`n" | Where-Object { $_.Trim() -ne "" } | ForEach-Object { "- $_" }) -join "`n"
$ragBody = @{
    model       = "qwen-chat"
    max_tokens  = 120
    temperature = 0.2
    messages    = @(
        @{ role = "system"; content = "Answer only from the context. If it is missing, say you do not know." }
        @{ role = "user"; content = "Context:`n$context`n`nQuestion: $question" }
    )
} | ConvertTo-Json -Depth 6
$rag = Invoke-RestMethod -Method Post -Uri "$base/v1/chat/completions" `
    -Headers $headers -ContentType "application/json" -Body $ragBody -TimeoutSec 180
Write-Host "answer:"
Write-Host $rag.choices[0].message.content

Write-Host ""
Write-Host "Admin UI:   $base/ui"
Write-Host "Login:      admin"
Write-Host "Password:   $master"
Write-Host "API:        $base/v1"
Write-Host "Create key: .\scripts\create-key.ps1"
