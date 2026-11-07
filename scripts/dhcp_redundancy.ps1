$ErrorActionPreference = 'Stop'

$LocalDC = $env:COMPUTERNAME
$Domain = $env:USERDNSDOMAIN
$ServerManagerKey = "registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\ServerManager\Roles\12"

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

# 1. Test if DHCP role and management tools are installed on DC2
try {
    $dhcpFeatures = Invoke-Command -ComputerName "$PartnerDC" -ScriptBlock { Get-WindowsFeature -Name DHCP, RSAT-DHCP }
    $missingFeatures = @($dhcpFeatures | Where-Object { -not $_.Installed })
    if ($missingFeatures.Count -eq 0) {
        Write-Host "[OK] DHCP Server Role and management tools are already installed on $PartnerDC." -ForegroundColor Green
        $NeedsInstall = $false
    } else {
        Write-Host "[!] Missing on $PartnerDC and will be installed: $($missingFeatures.Name -join ', ')." -ForegroundColor Yellow
        $NeedsInstall = $true
    }
} catch {
    Write-Error "Failed to check DHCP Role on $PartnerDC. Error: $_"
    exit
}

# 2. Test if DC2 is already authorized in AD
try {
    $authorizedServers = Get-DhcpServerInDC
    if ($authorizedServers.DnsName -match $PartnerDC) {
        Write-Host "[OK] $PartnerDC is already authorized in Active Directory." -ForegroundColor Green
        $NeedsAuth = $false
    } else {
        Write-Host "[!] $PartnerDC is not yet authorized in Active Directory." -ForegroundColor Yellow
        $NeedsAuth = $true
    }
} catch {
    Write-Error "Failed to check DHCP Authorization. Error: $_"
    exit
}

# 3. Test if the Server Manager post-deployment warning is cleared on DC2
try {
    $configState = Invoke-Command -ComputerName "$PartnerDC" -ArgumentList $ServerManagerKey -ScriptBlock {
        param($Key)
        (Get-ItemProperty -Path $Key -Name ConfigurationState -ErrorAction SilentlyContinue).ConfigurationState
    }
    if ($configState -eq 2) {
        Write-Host "[OK] Server Manager post-deployment configuration is complete on $PartnerDC." -ForegroundColor Green
        $NeedsPostInstall = $false
    } else {
        Write-Host "[!] Server Manager post-deployment configuration is not complete on $PartnerDC." -ForegroundColor Yellow
        $NeedsPostInstall = $true
    }
} catch {
    Write-Error "Failed to check Server Manager status on $PartnerDC. Error: $_"
    exit
}

# 4. Test if Failover already exists
try {
    $failoverName = "$LocalDC-$PartnerDC-Failover"
    $existingFailover = Get-DhcpServerv4Failover -ComputerName "$LocalDC" -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $failoverName }
    if ($existingFailover) {
        Write-Host "[OK] Failover partnership '$failoverName' already exists." -ForegroundColor Green
        $NeedsFailover = $false
    } else {
        Write-Host "[!] Failover partnership is missing and will be created." -ForegroundColor Yellow
        $NeedsFailover = $true
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
            Install-WindowsFeature -Name DHCP, RSAT-DHCP -IncludeManagementTools | Out-Null
        }
    } catch {
        Write-Error "Failed to install DHCP Role on $PartnerDC. Error: $_"
        exit
    }
}

# --- Authorization (if needed) ---
if ($NeedsAuth) {
    Write-Host "Authorizing DHCP server in AD..."
    try {
        $fqdn = "$PartnerDC.$Domain"
        Add-DhcpServerInDC -DnsName "$fqdn" -IPAddress "$PartnerIP"
    } catch {
        Write-Error "Failed to authorize DHCP server. Error: $_"
        exit
    }
}

# --- Post-install steps and clearing Server Manager warning (if needed) ---
if ($NeedsPostInstall) {
    Write-Host "Completing post-install configuration on $PartnerDC..."
    try {
        Invoke-Command -ComputerName "$PartnerDC" -ArgumentList $ServerManagerKey -ScriptBlock {
            param($Key)

            try {
                Add-DhcpServerSecurityGroup -ErrorAction Stop
            } catch {
                Write-Warning "Could not add the DHCP security groups: $_"
            }

            Restart-Service -Name DHCPServer
            Set-ItemProperty -Path $Key -Name ConfigurationState -Value 2
        }
    } catch {
        Write-Error "Failed to complete post-install configuration on $PartnerDC. Error: $_"
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

# --- Copy server options to DC2 and swap the DNS order (Always run to be sure) ---
Write-Host "Copying DHCP server options from $LocalDC to $PartnerDC..."
try {
    $ServerOptions = @(Get-DhcpServerv4OptionValue -ComputerName "$LocalDC")

    foreach ($option in ($ServerOptions | Where-Object { $_.OptionId -ne 6 })) {
        try {
            Set-DhcpServerv4OptionValue -ComputerName "$PartnerDC" -OptionId $option.OptionId -Value $option.Value
            Write-Host "   [OK] Option $($option.OptionId) ($($option.Name)): $($option.Value -join ', ')" -ForegroundColor Green
        } catch {
            Write-Warning "   [!] Could not copy option $($option.OptionId) ($($option.Name)). Error: $_"
        }
    }

    # Option 6 = DNS servers: same servers as DC1, in reverse order
    $LocalDns = @(($ServerOptions | Where-Object { $_.OptionId -eq 6 }).Value)
    if ($LocalDns.Count -ge 2) {
        $PartnerDns = @($LocalDns[($LocalDns.Count - 1)..0])
    } else {
        $PartnerDns = @("$PartnerIP", "$LocalIP")
    }

    Write-Host "Configuring DNS server options on $PartnerDC (Order: $($PartnerDns -join ', '))..."
    Set-DhcpServerv4OptionValue -ComputerName "$PartnerDC" -DnsServer $PartnerDns -Force
} catch {
    Write-Error "Failed to set server options on $PartnerDC. Error: $_"
    exit
}


Write-Host "`n==================================================="
Write-Host " PHASE 3: VERIFYING RESULT"
Write-Host "==================================================="

$dhcpFeatures = Invoke-Command -ComputerName "$PartnerDC" -ScriptBlock { Get-WindowsFeature -Name DHCP, RSAT-DHCP }
foreach ($feature in $dhcpFeatures) {
    Write-Host "Feature $($feature.Name) installed: $($feature.Installed)"
}

$authorizedPartner = @(Get-DhcpServerInDC | Where-Object { $_.DnsName -match $PartnerDC })
Write-Host "Authorized in AD: $($authorizedPartner.DnsName -join ', ')"

$configState = Invoke-Command -ComputerName "$PartnerDC" -ArgumentList $ServerManagerKey -ScriptBlock {
    param($Key)
    (Get-ItemProperty -Path $Key -Name ConfigurationState -ErrorAction SilentlyContinue).ConfigurationState
}
Write-Host "Server Manager ConfigurationState on ${PartnerDC}: $configState (2 = complete)"

$failover = Get-DhcpServerv4Failover -ComputerName "$LocalDC" | Where-Object { $_.Name -eq $failoverName }
Write-Host "Failover: $($failover.Name) | Partner: $($failover.PartnerServer) | Mode: $($failover.Mode) | State: $($failover.State) | Scopes: $($failover.ScopeId -join ', ')"

foreach ($server in @($LocalDC, $PartnerDC)) {
    $dnsServers = (Get-DhcpServerv4OptionValue -ComputerName "$server" -OptionId 6).Value
    Write-Host "DNS servers (server option) on ${server}: $($dnsServers -join ', ')"
}

# Scope options win over server options and are replicated by the failover
foreach ($scopeId in $failover.ScopeId) {
    $scopeDns = Get-DhcpServerv4OptionValue -ComputerName "$PartnerDC" -ScopeId $scopeId -ErrorAction SilentlyContinue | Where-Object { $_.OptionId -eq 6 }
    if ($scopeDns) {
        Write-Warning "Scope $scopeId has its own DNS option ($($scopeDns.Value -join ', ')). It overrides the swapped server option on $PartnerDC."
    }
}

Write-Host "`nScript successfully completed!" -ForegroundColor Cyan