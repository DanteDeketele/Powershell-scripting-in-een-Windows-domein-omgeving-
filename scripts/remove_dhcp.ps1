$LocalDC =$env:COMPUTERNAME
$Domain =$env:USERDNSDOMAIN

Write-Host "==================================================="
Write-Host " PHASE 0: DISCOVERING PARTNER SERVER"
Write-Host "==================================================="
Write-Host "Local Domain Controller detected as: $LocalDC" -ForegroundColor Cyan

# Try to auto-detect the other Domain Controller in the domain
$PartnerDC = ""
try {
    $allDCs = Get-ADDomainController -Filter * | Select-Object -ExpandProperty Name
    $otherDCs = @($allDCs | Where-Object { $_ -ne$LocalDC })
    
    if ($otherDCs.Count -eq 1) {
        $PartnerDC =$otherDCs[0]
        Write-Host "Auto-detected Partner DC for cleanup: $PartnerDC" -ForegroundColor Green
    } else {
        Write-Warning "Could not automatically determine a single Partner DC. Found $($otherDCs.Count) other DCs."
        exit
    }
} catch {
    Write-Warning "Could not query Active Directory for other Domain Controllers."
    exit
}

# Resolve IP and FQDN
$PartnerIP = (Resolve-DnsName -Name "$PartnerDC" -Type A -ErrorAction SilentlyContinue).IPAddress | Select-Object -First 1
$fqdn = "$PartnerDC.$Domain"

Write-Host "`n==================================================="
Write-Host " ACTIONS TO BE PERFORMED"
Write-Host "==================================================="
Write-Host "To provide a clean slate for the assignment, this script will:"
Write-Host " 1. Remove all DHCP Failover relationships from $LocalDC." -ForegroundColor Yellow
Write-Host " 2. Force remove any replicated DHCP Scopes from $PartnerDC." -ForegroundColor Yellow
Write-Host " 3. Unauthorize $PartnerDC from Active Directory." -ForegroundColor Yellow
Write-Host " 4. Uninstall the DHCP Server Role and Management Tools from $PartnerDC." -ForegroundColor Yellow
Write-Host " 5. Reset the Server Manager post-deployment warning on $PartnerDC." -ForegroundColor Yellow

Write-Host "`n==================================================="
Write-Host " CONFIRMATION"
Write-Host "==================================================="
$confirmation = Read-Host "Do you want to proceed with this cleanup? (Y/N)"

if ($confirmation -notmatch "^[yY]") {
    Write-Warning "Cleanup cancelled. No changes have been made."
    exit
}

Write-Host "`n==================================================="
Write-Host " EXECUTING CLEANUP"
Write-Host "==================================================="

# 1. Remove Failover Relationships on DC1
Write-Host "1. Removing DHCP Failover relationships on $LocalDC..."
$failovers = Get-DhcpServerv4Failover -ComputerName "$LocalDC" -ErrorAction SilentlyContinue
if ($failovers) {
    $failovers | Remove-DhcpServerv4Failover -ComputerName "$LocalDC" -Force -ErrorAction SilentlyContinue
    Write-Host "   [OK] Failovers removed." -ForegroundColor Green
} else {
    Write-Host "   [-] No failovers found to remove." -ForegroundColor Gray
}

# 2. Remove replicated Scopes on DC2
Write-Host "2. Removing DHCP Scopes on $PartnerDC..."
try {
    $partnerScopes = Get-DhcpServerv4Scope -ComputerName "$PartnerDC" -ErrorAction SilentlyContinue
    if ($partnerScopes) {
        $partnerScopes | Remove-DhcpServerv4Scope -ComputerName "$PartnerDC" -Force -ErrorAction SilentlyContinue
        Write-Host "   [OK] Scopes removed from $PartnerDC." -ForegroundColor Green
    } else {
        Write-Host "   [-] No scopes found on $PartnerDC." -ForegroundColor Gray
    }
} catch {
    Write-Host "   [-] Could not connect to DHCP on $PartnerDC (it might not be running)." -ForegroundColor Gray
}

# 3. Unauthorize DC2 in Active Directory
Write-Host "3. Unauthorizing $PartnerDC from Active Directory..."
$authorizedServers = Get-DhcpServerInDC -ErrorAction SilentlyContinue
if ($authorizedServers.DnsName -match $PartnerDC) {
    Remove-DhcpServerInDC -DnsName "$fqdn" -IPAddress "$PartnerIP" -ErrorAction SilentlyContinue
    Write-Host "   [OK] Server unauthorized." -ForegroundColor Green
} else {
    Write-Host "   [-] Server was not authorized in AD." -ForegroundColor Gray
}

# 4. Uninstall DHCP Role and Tools on DC2
Write-Host "4. Uninstalling DHCP Role and Management Tools on $PartnerDC..."
try {
    $dhcpRole = Invoke-Command -ComputerName "$PartnerDC" -ScriptBlock { Get-WindowsFeature -Name DHCP }
    if ($dhcpRole.Installed) {
        Invoke-Command -ComputerName "$PartnerDC" -ScriptBlock {
            Uninstall-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
            # Remove the registry hack so the warning comes back for a true clean slate
            Remove-ItemProperty -Path "registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\ServerManager\Roles\12" -Name ConfigurationState -ErrorAction SilentlyContinue
        }
        Write-Host "   [OK] DHCP Role and tools uninstalled." -ForegroundColor Green
    } else {
        Write-Host "   [-] DHCP Role is already uninstalled." -ForegroundColor Gray
    }
} catch {
    Write-Warning "   [!] Failed to uninstall roles. Ensure $PartnerDC is online."
}

Write-Host "`nCleanup completed! Everything should now be ready for a fresh execution of script 1." -ForegroundColor Cyan