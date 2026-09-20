# Open TCP 4000 for LAN clients of LiteLLM. Run once as Administrator.
$ErrorActionPreference = "Stop"
$rule = "localNexus LiteLLM 4000"
if (Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue) {
    Write-Host "Firewall rule already exists: $rule"
} else {
    New-NetFirewallRule -DisplayName $rule -Direction Inbound -Protocol TCP -LocalPort 4000 -Action Allow | Out-Null
    Write-Host "Opened inbound TCP 4000 ($rule)"
}

Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike "127.*" -and $_.PrefixOrigin -ne "WellKnown" } |
    Select-Object InterfaceAlias, IPAddress |
    Format-Table -AutoSize

Write-Host "Clients: http://<IP>:4000/v1   Admin UI: http://<IP>:4000/ui"
