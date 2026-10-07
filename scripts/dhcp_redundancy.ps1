param (
    [string]$PartnerDC = "MCT-DC2"
)

$LocalDC =$env:COMPUTERNAME
$Domain =$env:USERDNSDOMAIN

# Variabelen in dubbele aanhalingstekens om copy-paste fouten (ontbrekende spaties) te voorkomen
$PartnerIP = (Resolve-DnsName -Name "$PartnerDC" -Type A -ErrorAction Stop).IPAddress | Select-Object -First 1
$LocalIP = (Resolve-DnsName -Name "$LocalDC" -Type A -ErrorAction Stop).IPAddress | Select-Object -First 1

Write-Host "==================================================="
Write-Host " PHASE 1: TESTING CURRENT CONFIGURATION"
Write-Host "==================================================="

# 1. Test if DHCP role is installed on DC2
$dhcpRole = Invoke-Command -ComputerName "$PartnerDC" -ScriptBlock { Get-WindowsFeature -Name DHCP }
if ($dhcpRole.Installed) {
    Write-Host "[OK] DHCP Server Role is already installed on $PartnerDC." -ForegroundColor Green
    $NeedsInstall =$false
} else {
    Write-Host "[!] DHCP Server Role is missing on $PartnerDC and will be installed." -ForegroundColor Yellow
    $NeedsInstall =$true
}

# 2. Test if DC2 is already authorized in AD
$authorizedServers = Get-DhcpServerInDC
if ($authorizedServers.DnsName -match$PartnerDC) {
    Write-Host "[OK] $PartnerDC is already authorized in Active Directory." -ForegroundColor Green
    $NeedsAuth =$false
} else {
    Write-Host "[!] $PartnerDC is not yet authorized in Active Directory." -ForegroundColor Yellow
    $NeedsAuth =$true
}

# 3. Test if Failover already exists
$failoverName = "$LocalDC-$PartnerDC-Failover"
$existingFailover = Get-DhcpServerv4Failover -ComputerName "$LocalDC" -ErrorAction SilentlyContinue | Where-Object {$_.Name -eq$failoverName}
if ($existingFailover) {
    Write-Host "[OK] Failover partnership '$failoverName' already exists." -ForegroundColor Green
    $NeedsFailover =$false
} else {
    Write-Host "[!] Failover partnership is missing and will be created." -ForegroundColor Yellow
    $NeedsFailover =$true
}

# --- REQUEST CONFIRMATION ---
Write-Host "`n==================================================="
Write-Host " CONFIRMATION"
Write-Host "==================================================="
$confirmation = Read-Host "Do you want to apply the required changes (Phase 2) now? (Y/N)"

if ($confirmation -notmatch "^[yY]") {
    Write-Warning "Execution cancelled. No changes have been made."
    exit
}

Write-Host "`n==================================================="
Write-Host " PHASE 2: APPLYING MISSING CONFIGURATION"
Write-Host "==================================================="

# --- Installation (if needed) ---
if ($NeedsInstall) {
    Write-Host "Installing DHCP Role including Management Tools on $PartnerDC..."
    Invoke-Command -ComputerName "$PartnerDC" -ScriptBlock {
        Install-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
    }
}

# --- Authorization and clearing Server Manager warning (if needed) ---
if ($NeedsAuth) {
    Write-Host "Authorizing DHCP server in AD..."
    $fqdn = "$PartnerDC.$Domain"
    Add-DhcpServerInDC -DnsName "$fqdn" -IPAddress "$PartnerIP"
    
    # Registry hack to hide the post-deployment warning in Server Manager
    Write-Host "Updating Server Manager post-deployment status on $PartnerDC..."
    Invoke-Command -ComputerName "$PartnerDC" -ScriptBlock {
        Set-ItemProperty -Path "registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\ServerManager\Roles\12" -Name ConfigurationState -Value 2
    }
}

# --- Set up Failover Partnership (if needed) ---
if ($NeedsFailover) {
    $Scopes = Get-DhcpServerv4Scope -ComputerName "$LocalDC"
    if ($Scopes) {
        Write-Host "Setting up Failover partnership ($failoverName) for scope(s): $($Scopes.ScopeId)..."
        Add-DhcpServerv4Failover -ComputerName "$LocalDC" `
                                 -Name "$failoverName" `
                                 -PartnerDownDelayTime 00:01:00 `
                                 -ServerRole LoadBalance `
                                 -PartnerServer "$PartnerDC" `
                                 -ScopeId $Scopes.ScopeId `
                                 -SharedSecret "Secret123!" `
                                 -Force
    } else {
        Write-Warning "No DHCP scopes found on $LocalDC. Cannot create failover."
    }
}

# --- Set DNS Order on DC2 (Always run to be sure) ---
Write-Host "Configuring DNS server options on $PartnerDC (Order: $PartnerIP, $LocalIP)..."
Set-DhcpServerv4OptionValue -ComputerName "$PartnerDC" -DnsServer "$PartnerIP", "$LocalIP" -Force

Write-Host "`nScript successfully completed!" -ForegroundColor Cyan