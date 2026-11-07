param (
    [string]$NewUPNSuffix = "bedrijf.local",
    [string]$BusinessOUName = "Bedrijf",
    [switch]$y
)

$ErrorActionPreference = 'Stop'

if ($NewUPNSuffix -match '@|/|\\') {
    throw "The UPN suffix must contain only the domain part, for example bedrijf.local."
}

$Domain = $env:USERDNSDOMAIN
$DomainDN = (Get-ADDomain).DistinguishedName
$Problems = 0

Write-Host "==================================================="
Write-Host " ADDING UPN SUFFIX AND UPDATING BUSINESS USERS"
Write-Host "==================================================="
Write-Host "Domain: $Domain"
Write-Host "New UPN suffix: $NewUPNSuffix"
Write-Host "Business OU: $BusinessOUName"

$businessOUs = @(Get-ADOrganizationalUnit `
    -Filter "Name -eq '$BusinessOUName'" `
    -SearchBase $DomainDN `
    -SearchScope OneLevel)

if ($businessOUs.Count -eq 0) {
    throw "Business OU '$BusinessOUName' was not found directly under $DomainDN."
}

if ($businessOUs.Count -gt 1) {
    throw "More than one business OU named '$BusinessOUName' was found. Use a unique OU name."
}

$businessOU = $businessOUs[0]
$users = @(Get-ADUser -SearchBase $businessOU.DistinguishedName -SearchScope Subtree -Filter *)
$ous = @(Get-ADOrganizationalUnit -SearchBase $businessOU.DistinguishedName -SearchScope Subtree -Filter *)

Write-Host "Users in business OU: $($users.Count)" -ForegroundColor Yellow
Write-Host "OUs in business OU: $($ous.Count)" -ForegroundColor Yellow

if (-not $y) {
    $confirmation = Read-Host "Add the suffix and update these users? (Y/N)"
    if ($confirmation -notmatch '^[yY]') {
        Write-Warning "Execution cancelled. No changes were made."
        exit
    }
}

$forest = Get-ADForest
if ($forest.UPNSuffixes -notcontains $NewUPNSuffix) {
    Set-ADForest -Identity $forest.Name -UPNSuffixes @{Add = $NewUPNSuffix}
    Write-Host "[OK] Added UPN suffix '$NewUPNSuffix' to the forest." -ForegroundColor Green
} else {
    Write-Host "[i] UPN suffix '$NewUPNSuffix' already exists." -ForegroundColor Gray
}

# The uPNSuffixes attribute on an OU sets the suffix offered for new users in that OU
foreach ($ou in $ous) {
    try {
        Set-ADOrganizationalUnit -Identity $ou -Replace @{uPNSuffixes = $NewUPNSuffix}
        Write-Host "[OK] Set default suffix on $($ou.DistinguishedName)" -ForegroundColor Green
    } catch {
        Write-Warning "[!] Failed to set the suffix on $($ou.DistinguishedName). Error: $_"
        $Problems++
    }
}

foreach ($user in $users) {
    $newUPN = "$($user.SamAccountName)@$NewUPNSuffix"

    if ($user.UserPrincipalName -eq $newUPN) {
        Write-Host "[i] $($user.SamAccountName) already uses $newUPN" -ForegroundColor Gray
        continue
    }

    try {
        Set-ADUser -Identity $user -UserPrincipalName $newUPN
        Write-Host "[OK] Updated $($user.SamAccountName) to $newUPN" -ForegroundColor Green
    } catch {
        Write-Warning "[!] Failed to update $($user.SamAccountName). Error: $_"
        $Problems++
    }
}

Write-Host "`n==================================================="
Write-Host " VERIFYING RESULT"
Write-Host "==================================================="

Write-Host "Forest UPN suffixes: $((Get-ADForest).UPNSuffixes -join ', ')"

Write-Host "`nUsers inside OU '$BusinessOUName':"
foreach ($user in (Get-ADUser -SearchBase $businessOU.DistinguishedName -SearchScope Subtree -Filter *)) {
    if ($user.UserPrincipalName -like "*@$NewUPNSuffix") {
        Write-Host "   [OK] $($user.SamAccountName): $($user.UserPrincipalName)" -ForegroundColor Green
    } else {
        Write-Warning "   [!] $($user.SamAccountName): $($user.UserPrincipalName)"
        $Problems++
    }
}

Write-Host "`nUsers outside OU '$BusinessOUName' (must keep their old UPN):"
$outsideUsers = Get-ADUser -Filter * | Where-Object { $_.DistinguishedName -notlike "*,$($businessOU.DistinguishedName)" }
foreach ($user in $outsideUsers) {
    if ($user.UserPrincipalName -like "*@$NewUPNSuffix") {
        Write-Warning "   [!] $($user.SamAccountName): $($user.UserPrincipalName)"
        $Problems++
    } else {
        Write-Host "   [OK] $($user.SamAccountName): $($user.UserPrincipalName)" -ForegroundColor Gray
    }
}

Write-Host "`nDefault suffix per OU:"
foreach ($ou in (Get-ADOrganizationalUnit -SearchBase $businessOU.DistinguishedName -SearchScope Subtree -Filter * -Properties uPNSuffixes)) {
    Write-Host "   $($ou.DistinguishedName): $($ou.uPNSuffixes -join ', ')"
}

if ($Problems -eq 0) {
    Write-Host "`nUPN suffix configuration completed." -ForegroundColor Cyan
} else {
    Write-Warning "Script completed with $Problems problem(s). Check the messages above."
}