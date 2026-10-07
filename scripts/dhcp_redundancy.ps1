$ErrorActionPreference = 'Stop'

$LocalDC = $env:COMPUTERNAME
$Domain = $env:USERDNSDOMAIN

Write-Host "==================================================="
Write-Host " PHASE 0: DISCOVERING PARTNER SERVER"
Write-Host "==================================================="
Write-Host "Local Domain Controller detected as: $LocalDC" -ForegroundColor Cyan

# Try to auto-detect the other Domain Controller in the domain
$AutoPartner = ""
try {
    $allDCs = Get-ADDomainController -Filter * | Select-Object -ExpandProperty Name
    $otherDCs = @($allDCs | Where-Object { $_ -ne $LocalDC })
    
    if ($otherDCs.Count -eq 1) {
        $AutoPartner = $otherDCs[0]
        Write-Host "Auto-detected a second Domain Controller in AD: $AutoPartner" -ForegroundColor Green
    }
} catch {
    Write-Warning "Could not query Active Directory for other Domain Controllers."
}

# Loop to ensure we get a valid Partner DC with working DNS
$validDNS = $false
$PartnerDC = $AutoPartner

while (-not $validDNS) {
    if ([string]::IsNullOrWhiteSpace($PartnerDC)) {
        $PartnerDC = Read-Host "Please enter the exact hostname of the Partner DC (e.g., win00-DC2)"
    }

    if ([string]::IsNullOrWhiteSpace($PartnerDC)) {
        Write-Warning "Name cannot be empty. Try again."
        $PartnerDC = ""
        continue
    }

    Write-Host "Checking DNS resolution for '$PartnerDC'..."
    try {
        $PartnerIP = (Resolve-DnsName -Name "$PartnerDC" -Type A).IPAddress | Select-Object -First 1
        $LocalIP = (Resolve-DnsName -Name "$LocalDC" -Type A).IPAddress | Select-Object -First 1
        $validDNS = $true
        Write-Host "[OK] DNS resolved successfully. IP of $PartnerDC is $PartnerIP`n" -ForegroundColor Green
    } catch {
        Write-Warning "[!] Cannot find '$PartnerDC' in DNS. Please check the name or ensure the server is turned on and connected."
        $PartnerDC = "" # Clear the variable to force the prompt in the next loop iteration
    }
}


Write-Host "==================================================="
Write-Host " PHASE 1: TESTING CURRENT CONFIGURATION"
Write-Host "==================================================="

# 1. Test if DHCP role is installed on DC2
try {
    $dhcpRole = Invoke-Command -ComputerName "$PartnerDC" -ScriptBlock { Get-WindowsFeature -Name DHCP }
    if ($dhcpRole.Installed) {
        Write-Host "[OK] DHCP Server Role is already installed on $PartnerDC." -ForegroundColor Green
        $NeedsInstall =$false
    } else {
        Write-Host "[!] DHCP Server Role is missing on $PartnerDC and will be installed." -ForegroundColor Yellow
        $NeedsInstall =$true
    }
} catch {
    Write-Error "Failed to check DHCP Role on $PartnerDC. Error: $_"
    exit
}

# 2. Test if DC2 is already authorized in AD
try {
    $authorizedServers = Get-DhcpServerInDC
    if ($authorizedServers.DnsName -match$PartnerDC) {
        Write-Host "[OK] $PartnerDC is already authorized in Active Directory." -ForegroundColor Green
        $NeedsAuth =$false
    } else {
        Write-Host "[!] $PartnerDC is not yet authorized in Active Directory." -ForegroundColor Yellow
        $NeedsAuth =$true
    }
} catch {
    Write-Error "Failed to check DHCP Authorization. Error: $_"
    exit
}

# 3. Test if Failover already exists
try {
    $failoverName = "$LocalDC-$PartnerDC-Failover"
    $existingFailover = Get-DhcpServerv4Failover -ComputerName "$LocalDC" -ErrorAction SilentlyContinue | Where-Object {$_.Name -eq$failoverName}
    if ($existingFailover) {
        Write-Host "[OK] Failover partnership '$failoverName' already exists." -ForegroundColor Green
        $NeedsFailover =$false
    } else {
        Write-Host "[!] Failover partnership is missing and will be created." -ForegroundColor Yellow
        $NeedsFailover =$true
    }
} catch {
    Write-Error "Failed to check existing Failover relationships. Error: $_"
    exit
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
    try {
        Invoke-Command -ComputerName "$PartnerDC" -ScriptBlock {
            Install-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
        }
    } catch {
        Write-Error "Failed to install DHCP Role on $PartnerDC. Error: $_"
        exit
    }
}

# --- Authorization and clearing Server Manager warning (if needed) ---
if ($NeedsAuth) {
    Write-Host "Authorizing DHCP server in AD..."
    try {
        $fqdn = "$PartnerDC.$Domain"
        Add-DhcpServerInDC -DnsName "$fqdn" -IPAddress "$PartnerIP"
        
        Write-Host "Updating Server Manager post-deployment status on $PartnerDC..."
        Invoke-Command -ComputerName "$PartnerDC" -ScriptBlock {
            Set-ItemProperty -Path "registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\ServerManager\Roles\12" -Name ConfigurationState -Value 2
        }
    } catch {
        Write-Error "Failed to authorize DHCP server or update Server Manager. Error: $_"
        exit
    }
}

# --- Set up Failover Partnership (if needed) ---
if ($NeedsFailover) {
    try {
        $Scopes = Get-DhcpServerv4Scope -ComputerName "$LocalDC" -ErrorAction SilentlyContinue
        if ($Scopes) {
            Write-Host "Setting up Failover partnership ($failoverName) for scope(s): $($Scopes.ScopeId)..."
            Add-DhcpServerv4Failover -ComputerName "$LocalDC" `
                                     -Name "$failoverName" `
                                     -PartnerServer "$PartnerDC" `
                                     -ScopeId $Scopes.ScopeId `
                                     -SharedSecret "Secret123!" `
                                     -Force
        } else {
            Write-Warning "No DHCP scopes found on $LocalDC. Cannot create failover."
            exit
        }
    } catch {
        Write-Error "Failed to create DHCP Failover partnership. Error: $_"
        exit
    }
}

# --- Set DNS Order on DC2 (Always run to be sure) ---
Write-Host "Configuring DNS server options on $PartnerDC (Order: $PartnerIP, $LocalIP)..."
try {
    Set-DhcpServerv4OptionValue -ComputerName "$PartnerDC" -DnsServer "$PartnerIP", "$LocalIP" -Force
} catch {
    Write-Error "Failed to set DNS server options on $PartnerDC. Error: $_"
    exit
}

Write-Host "`nScript successfully completed!" -ForegroundColor Cyan