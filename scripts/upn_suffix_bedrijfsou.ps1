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

Write-Host "Users to update: $($users.Count)" -ForegroundColor Yellow

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

foreach ($user in $users) {
    $newUPN = "$($user.SamAccountName)@$NewUPNSuffix"
    Set-ADUser -Identity $user -UserPrincipalName $newUPN
    Write-Host "[OK] Updated $($user.SamAccountName) to $newUPN" -ForegroundColor Green
}

Write-Host "`nUPN suffix configuration completed." -ForegroundColor Cyan