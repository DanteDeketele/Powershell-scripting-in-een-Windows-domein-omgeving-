$ErrorActionPreference = 'Stop'
$LocalDC = $env:COMPUTERNAME

# Stel hier het juiste pad in naar je CSV-bestand
$CsvPath = "C:\Users\Administrator\Documents\reservaties.csv"

$Problems = 0

Write-Host "==================================================="
Write-Host " PHASE 1: READING EXCEL/CSV DATA"
Write-Host "==================================================="

# Controleer of het bestand bestaat
if (-not (Test-Path "$CsvPath")) {
    Write-Warning "Cannot find the file at $CsvPath. Please check the path and try again."
    exit
}

# Lees de data in met aanhalingstekens om spatie-fouten te voorkomen
try {
    $Reservations = @(Import-Csv -Path "$CsvPath" -Delimiter ";")
    Write-Host "[OK] Successfully loaded $($Reservations.Count) reservations from the file." -ForegroundColor Green
} catch {
    Write-Error "Failed to read the CSV file. Error: $_"
    exit
}

Write-Host "`n==================================================="
Write-Host " PHASE 2: CREATING DHCP RESERVATIONS"
Write-Host "==================================================="

foreach ($res in $Reservations) {
    Write-Host "Processing reservation for '$($res.ClientName)' with IP $($res.IPAddress)..."
    
    try {
        # Zoek bestaande reservaties met hetzelfde IP-adres of MAC-adres
        $existing = @(Get-DhcpServerv4Reservation -ComputerName "$LocalDC" -ScopeId "$($res.ScopeId)" | Where-Object {
            "$($_.IPAddress)" -eq $res.IPAddress -or $_.ClientId -eq $res.MacAddress
        })

        if ($existing.Count -eq 0) {
            # Maak de reservatie aan op de lokale server (DC1)
            Add-DhcpServerv4Reservation -ComputerName "$LocalDC" `
                                        -ScopeId "$($res.ScopeId)" `
                                        -IPAddress "$($res.IPAddress)" `
                                        -ClientId "$($res.MacAddress)" `
                                        -Name "$($res.ClientName)" `
                                        -Description "$($res.Description)"

            Write-Host "  -> [OK] Successfully added reservation." -ForegroundColor Green
        } elseif ($existing.Count -eq 1 -and "$($existing[0].IPAddress)" -eq $res.IPAddress -and $existing[0].ClientId -eq $res.MacAddress) {
            Write-Host "  -> [i] Reservation already exists." -ForegroundColor Gray
        } else {
            # Hetzelfde IP of MAC is al gebruikt door een andere reservatie
            foreach ($conflict in $existing) {
                Write-Warning "  -> [!] Conflict with '$($conflict.Name)' ($($conflict.IPAddress), $($conflict.ClientId))."
            }
            $Problems++
        }
    } catch {
        Write-Warning "  -> [!] Failed to add reservation. Error: $_"
        $Problems++
    }
}

Write-Host "`n==================================================="
Write-Host " PHASE 3: REPLICATING TO PARTNER SERVER"
Write-Host "==================================================="
Write-Host "Triggering failover replication for all scopes..."

try {
    # Forceer de replicatie van DC1 naar DC2
    $replicatedScopes = Invoke-DhcpServerv4FailoverReplication -ComputerName "$LocalDC" -Force
    Write-Host "[OK] Replication triggered for scope(s): $($replicatedScopes -join ', ')" -ForegroundColor Green
} catch {
    Write-Error "Failed to trigger replication. Error: $_"
    exit
}

Write-Host "`n==================================================="
Write-Host " PHASE 4: VERIFYING RESERVATIONS ON PARTNER SERVER"
Write-Host "==================================================="

foreach ($res in $Reservations) {
    try {
        # De partner verschilt per scope, dus vraag de failover van deze scope op
        $PartnerDC = (Get-DhcpServerv4Failover -ComputerName "$LocalDC" -ScopeId "$($res.ScopeId)").PartnerServer

        $replicated = Get-DhcpServerv4Reservation -ComputerName "$PartnerDC" -ScopeId "$($res.ScopeId)" | Where-Object {
            "$($_.IPAddress)" -eq $res.IPAddress -and $_.ClientId -eq $res.MacAddress
        }

        if ($replicated) {
            Write-Host "[OK] $($res.ClientName) ($($res.IPAddress)) found on $PartnerDC." -ForegroundColor Green
        } else {
            Write-Warning "[!] $($res.ClientName) ($($res.IPAddress)) NOT found on $PartnerDC."
            $Problems++
        }
    } catch {
        Write-Warning "[!] Could not verify $($res.ClientName) on the partner server. Error: $_"
        $Problems++
    }
}

if ($Problems -eq 0) {
    Write-Host "`nScript successfully completed!" -ForegroundColor Cyan
} else {
    Write-Warning "Script completed with $Problems problem(s). Check the messages above."
}