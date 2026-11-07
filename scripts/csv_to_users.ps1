param (
    [switch]$y
)

$ErrorActionPreference = 'Stop'
$ADDomain = Get-ADDomain
$Domain = $ADDomain.DNSRoot
$DomainDN = $ADDomain.DistinguishedName

# --- Configuratie Variabelen ---
$MemberServer = "WIN00-MS"
$CsvPath = "C:\Users\Administrator\Documents\gebruikers.csv"
$ShareName = "Home"
$ShareLocalPath = "C:\HomeShares"
$BusinessOUName = "Bedrijf"
$BusinessOUPath = "OU=$BusinessOUName,$DomainDN"
$DefaultPassword = ConvertTo-SecureString "Welkom123!" -AsPlainText -Force

$Problems = 0

Write-Host "==================================================="
Write-Host " PHASE 1: PREPARATION & READING CSV"
Write-Host "==================================================="
if (-not (Test-Path "$CsvPath")) {
    Write-Warning "Cannot find the file at $CsvPath. Please ensure it exists."
    exit
}

try {
    $Users = @(Import-Csv -Path "$CsvPath" -Delimiter ";")
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
Write-Host " 3. Automatically create missing OUs and Groups under OU '$BusinessOUName'." -ForegroundColor Yellow
Write-Host " 4. Create or update $($Users.Count) users in Active Directory." -ForegroundColor Yellow
Write-Host " 5. Create a home folder for each user and give the user access to it." -ForegroundColor Yellow

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
            Grant-SmbShareAccess -Name "$Name" -AccountName "Everyone" -AccessRight Full -Force | Out-Null
            Write-Host "   [i] Share '$Name' already exists. Verified Everyone - Full Control." -ForegroundColor Gray
        }

        $acl = Get-Acl "$Path"
        $acl.SetAccessRuleProtection($true, $false)
        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators", "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow")
        $authUserRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Authenticated Users", "Read", "None", "None", "Allow")
        $acl.SetAccessRule($adminRule)
        $acl.SetAccessRule($authUserRule)
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

# The company OU is the parent of all department OUs
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

foreach ($user in $Users) {
    Write-Host "Processing user: $($user.FirstName) $($user.LastName) ($($user.SamAccountName))..."

    # 1. Check & Create OU automatically!
    $ouPath = "OU=$($user.OU),$BusinessOUPath"
    try {
        $ouExists = Get-ADOrganizationalUnit -Filter "Name -eq '$($user.OU)'" -SearchBase "$BusinessOUPath" -SearchScope OneLevel
        if (-not $ouExists) {
            Write-Host "   -> OU '$($user.OU)' not found. Creating it automatically..." -ForegroundColor Yellow
            New-ADOrganizationalUnit -Name "$($user.OU)" -Path "$BusinessOUPath"
        }
    } catch {
        Write-Warning "   [!] Failed to verify/create OU $($user.OU). Error: $_"
        $Problems++
        continue
    }

    # 2. Check & Create Group, or move it if it is in the wrong OU
    try {
        $group = Get-ADGroup -Filter "Name -eq '$($user.Group)'"
        if (-not $group) {
            Write-Host "   -> Group '$($user.Group)' not found. Creating it..." -ForegroundColor Yellow
            New-ADGroup -Name "$($user.Group)" -GroupCategory Security -GroupScope Global -Path "$ouPath"
        } elseif ($group.DistinguishedName -notlike "*,$ouPath") {
            Move-ADObject -Identity $group.ObjectGUID -TargetPath "$ouPath"
            Write-Host "   [OK] Moved group '$($user.Group)' to $ouPath." -ForegroundColor Green
        }
    } catch {
        Write-Warning "   [!] Failed to verify/create group $($user.Group). Error: $_"
        $Problems++
        continue
    }

    # 3. Create or update User
    try {
        $homeDirectory = "\\$MemberServer\$ShareName\$($user.SamAccountName)"
        $adUser = Get-ADUser -Filter "SamAccountName -eq '$($user.SamAccountName)'"

        if (-not $adUser) {
            $upn = "$($user.SamAccountName)@$Domain"
            
            $adUser = New-ADUser -Name "$($user.FirstName) $($user.LastName)" `
                                 -GivenName "$($user.FirstName)" `
                                 -Surname "$($user.LastName)" `
                                 -SamAccountName "$($user.SamAccountName)" `
                                 -UserPrincipalName "$upn" `
                                 -Path "$ouPath" `
                                 -AccountPassword $DefaultPassword `
                                 -Enabled $true `
                                 -HomeDirectory "$homeDirectory" `
                                 -HomeDrive "H:" `
                                 -ChangePasswordAtLogon $true `
                                 -PassThru
                       
            Write-Host "   [OK] User created successfully in $ouPath." -ForegroundColor Green
        } else {
            Write-Host "   [i] User already exists in AD." -ForegroundColor Gray
            Set-ADUser -Identity $adUser.ObjectGUID -HomeDirectory "$homeDirectory" -HomeDrive "H:"

            if ($adUser.DistinguishedName -notlike "*,$ouPath") {
                Move-ADObject -Identity $adUser.ObjectGUID -TargetPath "$ouPath"
                Write-Host "   [OK] Moved user to $ouPath." -ForegroundColor Green
            }
        }

        # 4. Group membership, also for users that already existed
        $isMember = Get-ADGroupMember -Identity "$($user.Group)" | Where-Object { $_.SamAccountName -eq $user.SamAccountName }
        if (-not $isMember) {
            Add-ADGroupMember -Identity "$($user.Group)" -Members "$($user.SamAccountName)"
            Write-Host "   [OK] User added to group '$($user.Group)'." -ForegroundColor Green
        } else {
            Write-Host "   [i] User is already a member of group '$($user.Group)'." -ForegroundColor Gray
        }

        # 5. Home folder: the parent only gives Administrators inherited access, so the user needs an own rule.
        # The SID is used because the member server may not know the new account name yet.
        $userHomeLocalPath = Join-Path $ShareLocalPath $user.SamAccountName
        Invoke-Command -ComputerName $MemberServer -ArgumentList $userHomeLocalPath, $adUser.SID.Value -ScriptBlock {
            param($Path,$Sid)

            if (-not (Test-Path -Path $Path)) {
                New-Item -Path $Path -ItemType Directory -Force | Out-Null
                Write-Host "   [OK] Created home directory $Path on remote server." -ForegroundColor Green
            } else {
                Write-Host "   [i] Home directory $Path already exists." -ForegroundColor Gray
            }

            $userSid = New-Object System.Security.Principal.SecurityIdentifier($Sid)
            $userRule = New-Object System.Security.AccessControl.FileSystemAccessRule($userSid, "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow")
            $acl = Get-Acl -Path $Path
            $acl.SetAccessRule($userRule)
            Set-Acl -Path $Path -AclObject $acl
            Write-Host "   [OK] Gave the user Full Control on $Path." -ForegroundColor Green
        }
    } catch {
        Write-Warning "   [!] Failed to process user $($user.SamAccountName). Error: $_"
        $Problems++
    }
}

Write-Host "`n==================================================="
Write-Host " PHASE 4: VERIFYING RESULT"
Write-Host "==================================================="

foreach ($user in $Users) {
    $adUser = Get-ADUser -Filter "SamAccountName -eq '$($user.SamAccountName)'" -Properties HomeDirectory, HomeDrive
    if (-not $adUser) {
        Write-Warning "[!] User $($user.SamAccountName) NOT found in AD."
        $Problems++
        continue
    }

    $groups = (Get-ADPrincipalGroupMembership -Identity $adUser.ObjectGUID).Name -join ', '
    Write-Host "$($adUser.SamAccountName)"
    Write-Host "   DN:     $($adUser.DistinguishedName)"
    Write-Host "   UPN:    $($adUser.UserPrincipalName)"
    Write-Host "   Home:   $($adUser.HomeDrive) $($adUser.HomeDirectory)"
    Write-Host "   Groups: $groups"
}

Invoke-Command -ComputerName "$MemberServer" -ArgumentList "$ShareLocalPath", "$ShareName" -ScriptBlock {
    param($Path,$Name)

    Write-Host "`nShare permissions on \\$env:COMPUTERNAME\${Name}:"
    foreach ($entry in (Get-SmbShareAccess -Name "$Name")) {
        Write-Host "   $($entry.AccountName): $($entry.AccessControlType) $($entry.AccessRight)"
    }

    foreach ($folder in @(Get-Item -Path "$Path") + @(Get-ChildItem -Path "$Path" -Directory)) {
        Write-Host "`nNTFS permissions on $($folder.FullName):"
        foreach ($entry in (Get-Acl -Path $folder.FullName).Access) {
            Write-Host "   $($entry.IdentityReference): $($entry.FileSystemRights) | Inherited: $($entry.IsInherited) | Applies to subfolders/files: $($entry.InheritanceFlags)"
        }
    }
}

if ($Problems -eq 0) {
    Write-Host "`nScript successfully completed!" -ForegroundColor Cyan
} else {
    Write-Warning "Script completed with $Problems problem(s). Check the messages above."
}