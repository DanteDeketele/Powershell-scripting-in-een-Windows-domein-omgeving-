$ErrorActionPreference = 'Stop'
$LocalDC =$env:COMPUTERNAME

# Stel hier het juiste pad in naar je CSV-bestand
$CsvPath = "C:\Users\Administrator\Documents\reservaties.csv"

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
    $Reservations = Import-Csv -Path "$CsvPath" -Delimiter ";"
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
        # Maak de reservatie aan op de lokale server (DC1)
        Add-DhcpServerv4Reservation -ComputerName "$LocalDC" `
                                    -ScopeId "$($res.ScopeId)" `
                                    -IPAddress "$($res.IPAddress)" `
                                    -ClientId "$($res.MacAddress)" `
                                    -Name "$($res.ClientName)" `
                                    -Description "$($res.Description)"
                                    
        Write-Host "  -> [OK] Successfully added reservation." -ForegroundColor Green
    } catch {
        # Catch errors if the IP or MAC already exists
        Write-Warning "  -> [!] Failed to add reservation. It might already exist or the parameters are invalid."
    }
}

Write-Host "`n==================================================="
Write-Host " PHASE 3: REPLICATING TO PARTNER SERVER"
Write-Host "==================================================="
Write-Host "Triggering failover replication for all scopes..."

try {
    # Forceer de replicatie van DC1 naar DC2
    Invoke-DhcpServerv4FailoverReplication -ComputerName "$LocalDC" -Force
    Write-Host "[OK] Replication triggered successfully! DC2 is now up to date." -ForegroundColor Cyan
} catch {
    Write-Error "Failed to trigger replication. Error: $_"
}

Write-Host "`nScript successfully completed!" -ForegroundColor Cyan