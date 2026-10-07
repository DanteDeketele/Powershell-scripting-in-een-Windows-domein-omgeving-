$ErrorActionPreference = 'Stop'
$Domain = $env:USERDNSDOMAIN
$LocalDC = $env:COMPUTERNAME

# --- Configuratie Variabelen ---
$MemberServer = "WIN00-MS"
$CsvPath = "C:\Users\Administrator\Documents\gebruikers.csv"
$ShareName = "Home"
$ShareLocalPath = "C:\HomeShares"
$DefaultPassword = ConvertTo-SecureString "Welkom123!" -AsPlainText -Force

Write-Host "==================================================="
Write-Host " PHASE 1: CONFIGURING HOME SHARE ON MEMBER SERVER"
Write-Host "==================================================="
Write-Host "Connecting to Member Server: $MemberServer"

try {
    Invoke-Command -ComputerName "$MemberServer" -ArgumentList "$ShareLocalPath", "$ShareName" -ScriptBlock {
        param($Path, $Name)
        
        # 1. Create the physical folder
        if (-not (Test-Path "$Path")) {
            New-Item -Path "$Path" -ItemType Directory -Force | Out-Null
            Write-Host "   [OK] Created directory $Path on remote server." -ForegroundColor Green
        } else {
            Write-Host "   [i] Directory $Path already exists." -ForegroundColor Gray
        }

        # 2. Create the SMB Share (Share permissions: Everyone - Full Control)
        $share = Get-SmbShare -Name "$Name" -ErrorAction SilentlyContinue
        if (-not $share) {
            New-SmbShare -Name "$Name" -Path "$Path" -FullAccess "Everyone" | Out-Null
            Write-Host "   [OK] Created Share '$Name' with Everyone - Full Control." -ForegroundColor Green
        } else {
            Write-Host "   [i] Share '$Name' already exists." -ForegroundColor Gray
        }

        # 3. Configure NTFS Permissions
        $acl = Get-Acl "$Path"
        
        $acl.SetAccessRuleProtection($true, $false)
        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators", "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow")
        $authUserRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Authenticated Users", "ReadAndExecute", "None", "None", "Allow")
        
        $acl.AddAccessRule($adminRule)
        $acl.AddAccessRule($authUserRule)
        
        Set-Acl -Path "$Path" -AclObject $acl
        Write-Host "   [OK] Verified strict NTFS permissions: Admin (Full), Auth Users (Read-only, this folder only)." -ForegroundColor Green
    }
} catch {
    Write-Error "Failed to configure the share on $MemberServer. Error: $_"
    exit
}


Write-Host "`n==================================================="
Write-Host " PHASE 2: READING CSV FILE"
Write-Host "==================================================="
if (-not (Test-Path "$CsvPath")) {
    Write-Warning "Cannot find the file at $CsvPath."
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
Write-Host " PHASE 3: CREATING USERS AND GROUPS IN AD"
Write-Host "==================================================="

foreach ($user in $Users) {
    Write-Host "Processing user: $($user.FirstName) $($user.LastName) ($($user.SamAccountName))..."

    # 1. Check & Create Group if it doesn't exist (Using Filter to avoid crashes)
    try {
        $groupExists = Get-ADGroup -Filter "Name -eq '$($user.Group)'"
        if (-not $groupExists) {
            Write-Host "   -> Group '$($user.Group)' not found. Creating it..." -ForegroundColor Yellow
            New-ADGroup -Name "$($user.Group)" -GroupCategory Security -GroupScope Global -Path "$($user.OU)"
        }
    } catch {
        Write-Warning "   [!] Failed to verify/create group $($user.Group). Ensure the OU exists!"
    }

    # 2. Create the User (Using Filter to avoid crashes)
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
                       -Path "$($user.OU)" `
                       -AccountPassword $DefaultPassword `
                       -Enabled $true `
                       -HomeDirectory "$homeDirectory" `
                       -HomeDrive "H:" `
                       -ChangePasswordAtLogon $true
                       
            Write-Host "   [OK] User created successfully." -ForegroundColor Green
            
            # 3. Add User to Group
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