#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sets up Windows OpenSSH Server for Coolify integration.

.DESCRIPTION
    This script automates the Windows-specific SSH configuration required for 
    Coolify to deploy applications. Coolify requires SSH access to the host
    machine, even when running in Docker Desktop.

    On Windows, admin users require SSH keys in a special location:
    C:\ProgramData\ssh\administrators_authorized_keys

.NOTES
    Must be run as Administrator.
    Run this AFTER running the bootstrap script (which generates the SSH key).

.EXAMPLE
    # From Administrator PowerShell:
    .\scripts\setup-windows-ssh.ps1
#>

param(
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [switch]$SkipInstall,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Windows SSH Setup for Coolify" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# Verify running as admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[ERROR] This script must be run as Administrator" -ForegroundColor Red
    Write-Host "        Right-click PowerShell -> Run as Administrator" -ForegroundColor Yellow
    exit 1
}

# Find the Coolify SSH key
$sshKeyPath = Join-Path $ProjectPath "data\coolify-ssh\id_ed25519.pub"
if (-not (Test-Path $sshKeyPath)) {
    Write-Host "[ERROR] Coolify SSH key not found at: $sshKeyPath" -ForegroundColor Red
    Write-Host "        Run 'bash scripts/bootstrap.sh' first to generate the key" -ForegroundColor Yellow
    exit 1
}

Write-Host "[OK] Found Coolify SSH key" -ForegroundColor Green

# Step 1: Install OpenSSH Server
Write-Host ""
Write-Host "[1/5] Checking OpenSSH Server..." -ForegroundColor Cyan

$sshCapability = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'

if ($sshCapability.State -ne 'Installed') {
    if ($SkipInstall) {
        Write-Host "[WARN] OpenSSH Server not installed (skipped due to -SkipInstall)" -ForegroundColor Yellow
    } else {
        Write-Host "       Installing OpenSSH Server..." -ForegroundColor Yellow
        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
        Write-Host "[OK] OpenSSH Server installed" -ForegroundColor Green
    }
} else {
    Write-Host "[OK] OpenSSH Server already installed" -ForegroundColor Green
}

# Step 2: Start and enable sshd service
Write-Host ""
Write-Host "[2/5] Configuring sshd service..." -ForegroundColor Cyan

$sshService = Get-Service -Name sshd -ErrorAction SilentlyContinue
if ($sshService) {
    if ($sshService.Status -ne 'Running') {
        Start-Service sshd
        Write-Host "       Started sshd service" -ForegroundColor Yellow
    }
    Set-Service -Name sshd -StartupType 'Automatic'
    Write-Host "[OK] sshd service running and set to automatic" -ForegroundColor Green
} else {
    Write-Host "[ERROR] sshd service not found - OpenSSH Server may not be installed" -ForegroundColor Red
    exit 1
}

# Step 3: Copy SSH key to administrators_authorized_keys
Write-Host ""
Write-Host "[3/5] Configuring SSH key authentication..." -ForegroundColor Cyan

$sshProgramDataDir = "C:\ProgramData\ssh"
$adminAuthKeysPath = Join-Path $sshProgramDataDir "administrators_authorized_keys"

# Ensure directory exists
if (-not (Test-Path $sshProgramDataDir)) {
    New-Item -ItemType Directory -Path $sshProgramDataDir -Force | Out-Null
}

# Read the Coolify public key
$coolifyKey = Get-Content $sshKeyPath -Raw
$coolifyKey = $coolifyKey.Trim()

# Check if key already exists
$keyExists = $false
if (Test-Path $adminAuthKeysPath) {
    $existingKeys = Get-Content $adminAuthKeysPath -Raw -ErrorAction SilentlyContinue
    if ($existingKeys -and $existingKeys.Contains("coolify@localhost")) {
        $keyExists = $true
    }
}

if ($keyExists -and -not $Force) {
    Write-Host "[OK] Coolify SSH key already in administrators_authorized_keys" -ForegroundColor Green
} else {
    # Remove old coolify key if exists, then add new one
    if (Test-Path $adminAuthKeysPath) {
        $existingKeys = Get-Content $adminAuthKeysPath
        $filteredKeys = $existingKeys | Where-Object { $_ -notmatch "coolify@localhost" }
        if ($filteredKeys) {
            $filteredKeys | Set-Content $adminAuthKeysPath -Encoding UTF8
        } else {
            "" | Set-Content $adminAuthKeysPath -Encoding UTF8
        }
    }
    
    # Append the new key
    Add-Content -Path $adminAuthKeysPath -Value $coolifyKey -Encoding UTF8
    Write-Host "[OK] Added Coolify SSH key to administrators_authorized_keys" -ForegroundColor Green
}

# Step 4: Fix permissions on administrators_authorized_keys
Write-Host ""
Write-Host "[4/5] Setting file permissions..." -ForegroundColor Cyan

# Windows OpenSSH requires specific ACLs on this file
$acl = Get-Acl $adminAuthKeysPath
$acl.SetAccessRuleProtection($true, $false)  # Disable inheritance

# Clear existing rules
$acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) } | Out-Null

# Add only Administrators and SYSTEM with Full Control
$adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators", "FullControl", "Allow")
$systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM", "FullControl", "Allow")

$acl.AddAccessRule($adminRule)
$acl.AddAccessRule($systemRule)

Set-Acl -Path $adminAuthKeysPath -AclObject $acl
Write-Host "[OK] Permissions set (Administrators + SYSTEM only)" -ForegroundColor Green

# Step 5: Configure Git Bash as default SSH shell (for Coolify bash scripts)
Write-Host ""
Write-Host "[5/5] Configuring default shell..." -ForegroundColor Cyan

$gitBashPath = "C:\Program Files\Git\bin\bash.exe"
if (Test-Path $gitBashPath) {
    $currentShell = Get-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -ErrorAction SilentlyContinue
    
    if ($currentShell.DefaultShell -ne $gitBashPath) {
        New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value $gitBashPath -PropertyType String -Force | Out-Null
        Write-Host "[OK] Set Git Bash as default SSH shell" -ForegroundColor Green
        Write-Host "       Coolify runs bash scripts, so Git Bash is required" -ForegroundColor Gray
    } else {
        Write-Host "[OK] Git Bash already set as default SSH shell" -ForegroundColor Green
    }
} else {
    Write-Host "[WARN] Git Bash not found at $gitBashPath" -ForegroundColor Yellow
    Write-Host "       Coolify may fail to execute bash scripts via SSH" -ForegroundColor Yellow
    Write-Host "       Install Git for Windows: https://git-scm.com/download/win" -ForegroundColor Yellow
}

# Restart sshd to apply changes
Write-Host ""
Write-Host "Restarting sshd service..." -ForegroundColor Cyan
Restart-Service sshd
Write-Host "[OK] sshd service restarted" -ForegroundColor Green

# Fix permissions on private key (Windows SSH requires this)
Write-Host ""
Write-Host "Fixing private key permissions..." -ForegroundColor Cyan

$privateKeyPath = Join-Path $ProjectPath "data\coolify-ssh\id_ed25519"
$currentUser = $env:USERNAME

if (Test-Path $privateKeyPath) {
    # Windows SSH requires the private key to have restrictive permissions
    # Only the current user should have access
    $keyAcl = Get-Acl $privateKeyPath
    $keyAcl.SetAccessRuleProtection($true, $false)  # Disable inheritance
    
    # Clear existing rules
    $keyAcl.Access | ForEach-Object { $keyAcl.RemoveAccessRule($_) } | Out-Null
    
    # Add only current user with Full Control
    $userRule = New-Object System.Security.AccessControl.FileSystemAccessRule($env:USERNAME, "FullControl", "Allow")
    $keyAcl.AddAccessRule($userRule)
    
    Set-Acl -Path $privateKeyPath -AclObject $keyAcl
    Write-Host "[OK] Private key permissions fixed (user-only access)" -ForegroundColor Green
}

# Test SSH connection
Write-Host ""
Write-Host "Testing SSH connection..." -ForegroundColor Cyan

$sshTest = & ssh -i $privateKeyPath -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 "$currentUser@localhost" "echo SSH_OK" 2>&1

if ($sshTest -match "SSH_OK") {
    Write-Host "[OK] SSH connection test PASSED" -ForegroundColor Green
} else {
    Write-Host "[WARN] SSH connection test failed" -ForegroundColor Yellow
    Write-Host "       Error: $sshTest" -ForegroundColor Gray
    Write-Host "       You may need to manually verify the SSH configuration" -ForegroundColor Yellow
}

# Summary
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Setup Complete" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor White
Write-Host "  1. Go to Coolify: https://coolify.digpulsepi.com/servers" -ForegroundColor Gray
Write-Host "  2. Click on 'localhost' server" -ForegroundColor Gray
Write-Host "  3. Click 'Validate Server' button" -ForegroundColor Gray
Write-Host "  4. If successful, start the Proxy from the Proxy tab" -ForegroundColor Gray
Write-Host ""
Write-Host "If validation still fails, check:" -ForegroundColor Yellow
Write-Host "  - Server port is set to 22 (not 2375)" -ForegroundColor Gray
Write-Host "  - User is set to: $currentUser" -ForegroundColor Gray
Write-Host "  - IP Address is: host.docker.internal" -ForegroundColor Gray
Write-Host ""
