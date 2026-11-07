param (
    [string]$BusinessOUName = "Bedrijf",
    [switch]$y
)

$ErrorActionPreference = 'Stop'
$DomainDN = (Get-ADDomain).DistinguishedName

# --- Configuratie Variabelen ---
$CsvPath = "C:\Users\Administrator\Documents\ou_structuur.csv"
$BusinessOUPath = "OU=$BusinessOUName,$DomainDN"

$Problems = 0

Write-Host "==================================================="
Write-Host " PHASE 1: READING EXCEL/CSV DATA"
Write-Host "==================================================="
if (-not (Test-Path "$CsvPath")) {
    Write-Warning "Cannot find the file at $CsvPath. Please ensure it exists."
    exit
}

try {
    $OUs = @(Import-Csv -Path "$CsvPath" -Delimiter ";")
    Write-Host "[OK] Loaded $($OUs.Count) OUs from CSV." -ForegroundColor Green
} catch {
    Write-Error "Failed to read CSV. Error: $_"
    exit
}

Write-Host "`n==================================================="
Write-Host " ACTIONS TO BE PERFORMED"
Write-Host "==================================================="
Write-Host " 1. Create the company OU '$BusinessOUName' if it is missing." -ForegroundColor Yellow
Write-Host " 2. Create the missing OUs from the CSV under '$BusinessOUName'." -ForegroundColor Yellow

if (-not $y) {
    Write-Host "`n==================================================="
    Write-Host " CONFIRMATION"
    Write-Host "==================================================="
    $confirmation = Read-Host "Do you want to apply these changes now? (Y/N)"

    if ($confirmation -notmatch "^[yY]") {
        Write-Warning "Execution cancelled."
        exit
    }
} else {
    Write-Host "`n[i] Auto-confirm flag (-y) detected. Proceeding..." -ForegroundColor Cyan
}

Write-Host "`n==================================================="
Write-Host " PHASE 2: CREATING OU STRUCTURE"
Write-Host "==================================================="

try {
    $businessOU = Get-ADOrganizationalUnit -Filter "Name -eq '$BusinessOUName'" -SearchBase "$DomainDN" -SearchScope OneLevel
    if (-not $businessOU) {
        New-ADOrganizationalUnit -Name "$BusinessOUName" -Path "$DomainDN"
        Write-Host "[OK] Created company OU '$BusinessOUName'." -ForegroundColor Green
    } else {
        Write-Host "[i] Company OU '$BusinessOUName' already exists." -ForegroundColor Gray
    }
} catch {
    Write-Error "Failed to verify/create company OU $BusinessOUName. Error: $_"
    exit
}

foreach ($row in $OUs) {
    # The Path column holds the levels below the company OU, for example IT/Helpdesk
    $parentPath = $BusinessOUPath
    $levels = @($row.Path -split '/')

    try {
        foreach ($level in $levels) {
            $ouExists = Get-ADOrganizationalUnit -Filter "Name -eq '$level'" -SearchBase "$parentPath" -SearchScope OneLevel
            if (-not $ouExists) {
                New-ADOrganizationalUnit -Name "$level" -Path "$parentPath" -Description "$($row.Description)"
                Write-Host "[OK] Created OU=$level,$parentPath" -ForegroundColor Green
            } else {
                Write-Host "[i] OU=$level,$parentPath already exists." -ForegroundColor Gray
            }
            $parentPath = "OU=$level,$parentPath"
        }
    } catch {
        Write-Warning "[!] Failed to create OU path $($row.Path). Error: $_"
        $Problems++
    }
}

Write-Host "`n==================================================="
Write-Host " PHASE 3: VERIFYING RESULT"
Write-Host "==================================================="

$tree = Get-ADOrganizationalUnit -SearchBase "$BusinessOUPath" -SearchScope Subtree -Filter * -Properties CanonicalName | Sort-Object CanonicalName
foreach ($ou in $tree) {
    $depth = ($ou.CanonicalName -split '/').Count - 2
    $userCount = @(Get-ADUser -SearchBase $ou.DistinguishedName -SearchScope OneLevel -Filter *).Count
    Write-Host "$('   ' * $depth)$($ou.Name) ($userCount users)"
}

foreach ($row in $OUs) {
    $levels = @($row.Path -split '/')
    [array]::Reverse($levels)
    $expectedDN = "OU=$($levels -join ',OU='),$BusinessOUPath"

    if ($tree.DistinguishedName -notcontains $expectedDN) {
        Write-Warning "[!] $($row.Path) NOT found in AD."
        $Problems++
    }
}

if ($Problems -eq 0) {
    Write-Host "`nScript successfully completed!" -ForegroundColor Cyan
} else {
    Write-Warning "Script completed with $Problems problem(s). Check the messages above."
}