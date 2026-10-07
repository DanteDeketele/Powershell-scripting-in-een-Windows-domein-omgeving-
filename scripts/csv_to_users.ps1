param (
    [switch]$y
)

$ErrorActionPreference = 'Stop'$Domain = $env:USERDNSDOMAIN$LocalDC = $env:COMPUTERNAME$DomainDN = (Get-ADDomain).DistinguishedName # Zoekt automatisch jouw DC=...,DC=... op!

# --- Configuratie Variabelen ---
$MemberServer = "WIN00-MS"
$CsvPath = "C:\Users\Administrator\Documents\gebruikers.csv"
$ShareName = "Home"
$ShareLocalPath = "C:\HomeShares"
$DefaultPassword = ConvertTo-SecureString "Welkom123!" -AsPlainText -Force

Write-Host "==================================================="
Write-Host " PHASE 1: PREPARATION & READING CSV"
Write-Host "==================================================="
if (-not (Test-Path "$CsvPath")) {
    Write-Warning "Cannot find the file at $CsvPath. Please ensure it exists."
    exit
}

try {
    $Users = Import-Csv -Path "$CsvPath" -Delimiter ";"
    Write-Host "[OK] Loaded $($Users.Count) users from CSV." -ForegroundColor Green
} catch {
    Write-Error "Failed to read CSV. Error: $_"
    exit
}

Write-Host "`n==================================================="
Write-Host " ACTIONS TO BE PERFORMED"
Write-Host "==================================================="
Write-Host " 1. Connect to $MemberServer and configure the '$ShareName' share." -ForegroundColor Yellow
Write-Host " 2. Set strict NTFS permissions." -ForegroundColor Yellow
Write-Host " 3. Automatically create missing OUs and Groups based on CSV." -ForegroundColor Yellow
Write-Host " 4. Create $($Users.Count) users in Active Directory." -ForegroundColor Yellow

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
Write-Host " PHASE 2: CONFIGURING HOME SHARE ON MEMBER SERVER"
Write-Host "==================================================="
try {
    Invoke-Command -ComputerName "$MemberServer" -ArgumentList "$ShareLocalPath", "$ShareName" -ScriptBlock {
        param($Path,$Name)
        
        if (-not (Test-Path "$Path")) {
            New-Item -Path "$Path" -ItemType Directory -Force | Out-Null
            Write-Host "   [OK] Created directory $Path on remote server." -ForegroundColor Green
        } else {
            Write-Host "   [i] Directory $Path already exists." -ForegroundColor Gray
        }

        $share = Get-SmbShare -Name "$Name" -ErrorAction SilentlyContinue
        if (-not $share) {
            New-SmbShare -Name "$Name" -Path "$Path" -FullAccess "Everyone" | Out-Null
            Write-Host "   [OK] Created Share '$Name' with Everyone - Full Control." -ForegroundColor Green
        } else {
            Write-Host "   [i] Share '$Name' already exists." -ForegroundColor Gray
        }

        $acl = Get-Acl "$Path"
        $acl.SetAccessRuleProtection($true, $false)$adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators", "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow")
        $authUserRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Authenticated Users", "ReadAndExecute", "None", "None", "Allow")
        $acl.AddAccessRule($adminRule)
        $acl.AddAccessRule($authUserRule)
        Set-Acl -Path "$Path" -AclObject $acl
        Write-Host "   [OK] Verified strict NTFS permissions." -ForegroundColor Green
    }
} catch {
    Write-Error "Failed to configure the share on $MemberServer. Error: $_"
    exit
}

Write-Host "`n==================================================="
Write-Host " PHASE 3: CREATING OUS, GROUPS AND USERS IN AD"
Write-Host "==================================================="

foreach ($user in $Users) {
    Write-Host "Processing user: $($user.FirstName) $($user.LastName) ($($user.SamAccountName))..."

    # 1. Check & Create OU automatically!
    $ouPath = "OU=$($user.OU),$DomainDN"
    try {
        $ouExists = Get-ADOrganizationalUnit -Filter "Name -eq '$($user.OU)'" -SearchBase "$DomainDN" -SearchScope OneLevel
        if (-not $ouExists) {
            Write-Host "   -> OU '$($user.OU)' not found. Creating it automatically..." -ForegroundColor Yellow
            New-ADOrganizationalUnit -Name "$($user.OU)" -Path "$DomainDN"
        }
    } catch {
        Write-Warning "   [!] Failed to verify/create OU $($user.OU)."
    }

    # 2. Check & Create Group
    try {
        $groupExists = Get-ADGroup -Filter "Name -eq '$($user.Group)'"
        if (-not $groupExists) {
            Write-Host "   -> Group '$($user.Group)' not found. Creating it..." -ForegroundColor Yellow
            New-ADGroup -Name "$($user.Group)" -GroupCategory Security -GroupScope Global -Path "$ouPath"
        }
    } catch {
        Write-Warning "   [!] Failed to verify/create group $($user.Group)."
    }

    # 3. Create User
    try {
        $userExists = Get-ADUser -Filter "SamAccountName -eq '$($user.SamAccountName)'"
        if (-not $userExists) {
            $upn = "$($user.SamAccountName)@$Domain"
            $homeDirectory = "\\$MemberServer\$ShareName\$($user.SamAccountName)"
            
            New-ADUser -Name "$($user.FirstName) $($user.LastName)" `
                       -GivenName "$($user.FirstName)" `
                       -Surname "$($user.LastName)" `
                       -SamAccountName "$($user.SamAccountName)" `
                       -UserPrincipalName "$upn" `
                       -Path "$ouPath" `
                       -AccountPassword $DefaultPassword `
                       -Enabled $true `
                       -HomeDirectory "$homeDirectory" `
                       -HomeDrive "H:" `
                       -ChangePasswordAtLogon $true
                       
            Write-Host "   [OK] User created successfully in $ouPath." -ForegroundColor Green
            
            Add-ADGroupMember -Identity "$($user.Group)" -Members "$($user.SamAccountName)"
            Write-Host "   [OK] User added to group '$($user.Group)'." -ForegroundColor Green
        } else {
            Write-Host "   [i] User already exists in AD." -ForegroundColor Gray
        }
    } catch {
        Write-Error "   [!] Failed to create user $($user.SamAccountName). Error: $_"
    }
}

Write-Host "`nScript successfully completed!" -ForegroundColor Cyan