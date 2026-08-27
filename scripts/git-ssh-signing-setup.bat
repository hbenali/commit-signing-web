@echo off
rem Copyright (c) 2026 Houssem Ben Ali (https://hbenali.ovh)
rem MIT License -- see LICENSE in the repository root.
setlocal enabledelayedexpansion

rem ---- ANSI colors (Windows 10 1511+ / Windows Terminal support VT codes) ----
for /F %%a in ('echo prompt $E^|cmd') do set "ESC=%%a"
set "BOLD=%ESC%[1m"
set "DIM=%ESC%[2m"
set "GREEN=%ESC%[32m"
set "YELLOW=%ESC%[33m"
set "RED=%ESC%[31m"
set "CYAN=%ESC%[36m"
set "MAGENTA=%ESC%[35m"
set "NC=%ESC%[0m"

set /a STEPCUR=0
set /a STEPTOTAL=6

call :banner
goto :main

:banner
echo %CYAN%%BOLD%
echo ============================================================
echo    Git SSH Commit Signing - Setup Wizard  (Windows)
echo ============================================================
echo %NC%
echo %DIM%by Houssem Ben Ali - https://hbenali.ovh%NC%
echo.
exit /b 0

:success_banner
echo %GREEN%%BOLD%
echo ============================================================
echo    [OK] SSH commit signing setup complete!
echo ============================================================
echo %NC%
exit /b 0

:step
set /a STEPCUR+=1
echo.
echo %MAGENTA%%BOLD%--- [%STEPCUR%/%STEPTOTAL%] %~1 ---%NC%
exit /b 0

:info
echo %CYAN%==^>%NC% %~1
exit /b 0

:ok
echo %GREEN%[OK]%NC% %~1
exit /b 0

:warn
echo %YELLOW%[WARN]%NC% %~1
exit /b 0

:err
echo %RED%[ERROR]%NC% %~1
exit /b 0

:main

rem ============================================================
rem 1. Pre-flight checks
rem ============================================================
call :step "Pre-flight checks"

where git >nul 2>nul
if errorlevel 1 (
    call :err "git not found in PATH. Install Git for Windows first."
    exit /b 1
)
call :ok "git found"

where ssh-keygen >nul 2>nul
if errorlevel 1 (
    call :err "ssh-keygen not found. Install the OpenSSH Client feature or Git for Windows."
    exit /b 1
)
call :ok "ssh-keygen found"

rem SSH commit signing requires git >= 2.34
for /f "tokens=3" %%v in ('git --version') do set "GITVER=%%v"
for /f "tokens=1,2 delims=." %%a in ("%GITVER%") do (
    set "GITMAJOR=%%a"
    set "GITMINOR=%%b"
)
set "VEROK=1"
if %GITMAJOR% LSS 2 set "VEROK=0"
if %GITMAJOR%==2 if %GITMINOR% LSS 34 set "VEROK=0"
if "%VEROK%"=="0" (
    call :err "Git 2.34+ is required for SSH commit signing (found %GITVER%)."
    exit /b 1
)
call :ok "git version %GITVER% supports SSH signing"

set "HAVEGH=0"
where gh >nul 2>nul
if not errorlevel 1 set "HAVEGH=1"
if "%HAVEGH%"=="0" call :warn "gh CLI not found - will offer to install it or fall back to manual GitHub steps."

set "SSHDIR=%USERPROFILE%\.ssh"
if not exist "%SSHDIR%" mkdir "%SSHDIR%"

rem ============================================================
rem 2. Existing GPG signing detection + migration prompt
rem ============================================================
call :step "Checking for existing commit-signing configuration"

set "OLDFORMAT="
for /f "delims=" %%F in ('git config --global --get gpg.format 2^>nul') do set "OLDFORMAT=%%F"
set "OLDSIGNKEY="
for /f "delims=" %%K in ('git config --global --get user.signingkey 2^>nul') do set "OLDSIGNKEY=%%K"
set "OLDGPGSIGN="
for /f "delims=" %%G in ('git config --global --get commit.gpgsign 2^>nul') do set "OLDGPGSIGN=%%G"
set "OLDTAGSIGN="
for /f "delims=" %%T in ('git config --global --get tag.gpgsign 2^>nul') do set "OLDTAGSIGN=%%T"

set "HASGPG=0"
if /i "%OLDFORMAT%"=="openpgp" set "HASGPG=1"
if "%OLDFORMAT%"=="" if not "%OLDSIGNKEY%"=="" set "HASGPG=1"
if "%OLDFORMAT%"=="" if /i "%OLDGPGSIGN%"=="true" set "HASGPG=1"

set "SKIPGITCONFIG=0"

if "%HASGPG%"=="0" (
    call :ok "No existing GPG commit-signing configuration found."
) else (
    call :warn "You already have GPG commit signing configured:"
    echo     gpg.format      = %OLDFORMAT%
    echo     user.signingkey = %OLDSIGNKEY%
    echo     commit.gpgsign  = %OLDGPGSIGN%
    echo     tag.gpgsign     = %OLDTAGSIGN%
    echo.
    echo Options:
    echo   1^) Migrate to SSH signing now ^(recommended^) - backs up the above first.
    echo   2^) Keep GPG signing untouched - skip git config changes, key can still be uploaded.
    echo   3^) Abort
    set "GPGCHOICE="
    set /p "GPGCHOICE=Choose an option [1]: "
    if "!GPGCHOICE!"=="" set "GPGCHOICE=1"

    if "!GPGCHOICE!"=="3" (
        call :err "Aborted by user."
        exit /b 1
    )
    if "!GPGCHOICE!"=="2" (
        call :warn "Leaving existing GPG configuration untouched. Git config changes will be skipped."
        set "SKIPGITCONFIG=1"
    )
    if "!GPGCHOICE!"=="1" (
        set "BACKUPFILE=%USERPROFILE%\gpg-signing-backup-%RANDOM%.txt"
        (
            echo # Backup of previous commit-signing git config.
            echo # Saved by git-ssh-signing-setup.bat before migrating to SSH signing.
            echo # To restore, run:
            echo git config --global gpg.format "%OLDFORMAT%"
            if not "%OLDSIGNKEY%"=="" echo git config --global user.signingkey "%OLDSIGNKEY%"
            echo git config --global commit.gpgsign %OLDGPGSIGN%
            if not "%OLDTAGSIGN%"=="" echo git config --global tag.gpgsign %OLDTAGSIGN%
        ) > "!BACKUPFILE!"
        call :ok "Backed up previous config to !BACKUPFILE!"
        call :ok "Proceeding with migration to SSH signing."
    )
)

rem ============================================================
rem 3. SSH key selection (existing vs. dedicated new key)
rem ============================================================
call :step "SSH key selection"

set "DEFAULTKEY=%SSHDIR%\id_ed25519_signing"
set "KEYPATH="

if exist "%SSHDIR%\id_ed25519.pub" (
    call :info "Found an existing SSH key: %SSHDIR%\id_ed25519"
    echo Using a dedicated key just for commit signing ^(separate from any key you
    echo use for SSH authentication^) is recommended, so it can be rotated or
    echo revoked independently without breaking SSH push/pull.
    set "WANTDEDICATED="
    set /p "WANTDEDICATED=Generate a new dedicated signing key? [Y/n]: "
    if /i "!WANTDEDICATED!"=="n" (
        set "KEYPATH=%SSHDIR%\id_ed25519"
        set /a EXISTINGKEYCOUNT=0
        for %%F in ("%SSHDIR%\id_*.pub") do set /a EXISTINGKEYCOUNT+=1
        if !EXISTINGKEYCOUNT! GTR 1 (
            call :warn "Multiple keys found - avoid picking one you already use for Git push/pull authentication as your signing key."
        )
    )
)

if "%KEYPATH%"=="" (
    set "INPUTPATH="
    set /p "INPUTPATH=Path for new dedicated signing key [%DEFAULTKEY%]: "
    if "!INPUTPATH!"=="" (set "KEYPATH=%DEFAULTKEY%") else (set "KEYPATH=!INPUTPATH!")

    if not exist "!KEYPATH!.pub" (
        set "KEYCOMMENT="
        set /p "KEYCOMMENT=Key comment/email: "
        ssh-keygen -t ed25519 -C "!KEYCOMMENT!" -f "!KEYPATH!"
        if errorlevel 1 (
            call :err "Key generation failed."
            exit /b 1
        )
        call :ok "Generated new key at !KEYPATH!"
    ) else (
        call :warn "Key already exists at !KEYPATH!"
    )
)

set "PUBKEY=%KEYPATH%.pub"
if not exist "%PUBKEY%" (
    call :err "Public key not found at %PUBKEY%"
    exit /b 1
)

rem Does the user have another key (besides this signing key) they could use
rem for Git auth instead, e.g. during 'gh auth login'?
set "HASOTHERKEY=0"
for %%F in ("%SSHDIR%\*.pub") do (
    if not "%%~fF"=="%PUBKEY%" set "HASOTHERKEY=1"
)

rem ============================================================
rem 4. gh CLI detection, multi-account check, upload
rem ============================================================
call :step "GitHub CLI detection"

set "GHREADY=0"
set "UPLOADED=0"

if "%HAVEGH%"=="0" (
    where winget >nul 2>nul
    if not errorlevel 1 (
        set "DOINSTALLGH="
        set /p "DOINSTALLGH=Install gh CLI now via winget (winget install --id GitHub.cli)? [y/N]: "
        if /i "!DOINSTALLGH!"=="y" (
            winget install --id GitHub.cli
            where gh >nul 2>nul
            if not errorlevel 1 (
                set "HAVEGH=1"
                call :ok "gh CLI installed."
            ) else (
                call :warn "gh still not found on PATH - you may need to open a new terminal window."
            )
        )
    ) else (
        call :warn "winget not found either. Install gh manually: https://cli.github.com"
    )
)

if "%HAVEGH%"=="0" goto :manual

call :ok "gh CLI detected"
gh auth status >nul 2>nul
if errorlevel 1 (
    call :warn "gh CLI found but not authenticated."
    echo.
    echo 'gh auth login' can ask you to select or upload an SSH key for Git operations
    echo ^(push/pull^). Using the same key ^(%PUBKEY%^) for both signing and push
    echo authentication is not recommended - compromising or rotating one key then
    echo breaks both.
    echo.
    if "%HASOTHERKEY%"=="1" (
        set "OPT3LABEL=Proceed - I'll pick a different ^(non-signing^) SSH key for Git auth"
    ) else (
        set "OPT3LABEL=Proceed anyway ^(discouraged^) - normal login, may reuse this signing key for push auth"
    )

    echo How would you like to log in?
    echo   1^) Use GitHub token/HTTPS auth for Git operations ^(recommended - skips the SSH key question^)
    echo   2^) Abort for now - generate or import a separate SSH key for Git auth first
    echo   3^) !OPT3LABEL!
    set "GHLOGINCHOICE="
    set /p "GHLOGINCHOICE=Choose an option [1]: "
    if "!GHLOGINCHOICE!"=="" set "GHLOGINCHOICE=1"

    if "!GHLOGINCHOICE!"=="2" (
        call :warn "Skipping 'gh auth login'. To set up a separate key for Git authentication:"
        echo     ssh-keygen -t ed25519 -C "your_email@example.com" -f %USERPROFILE%\.ssh\id_ed25519
        echo     gh auth login
        echo   ^(or, if you already have a separate key, just run: gh auth login^)
    ) else (
        if "!GHLOGINCHOICE!"=="3" (
            if "%HASOTHERKEY%"=="1" (
                call :warn "Proceeding - remember to pick a different key than %PUBKEY% when asked."
            ) else (
                call :warn "Proceeding - avoid selecting %PUBKEY% if asked for a Git auth key."
            )
            gh auth login
        ) else (
            gh auth login --git-protocol https
        )
        gh auth status >nul 2>nul
        if not errorlevel 1 set "GHREADY=1"
    )
) else (
    set "GHREADY=1"
)

if "%GHREADY%"=="0" goto :manual

rem ---- multi-account check ----
set "GHSTATUSFILE=%TEMP%\ghstatus_%RANDOM%.txt"
gh auth status >"%GHSTATUSFILE%" 2>&1
set "ACCOUNTLIST="
for /f "usebackq delims=" %%L in ("%GHSTATUSFILE%") do (
    set "LINE=%%L"
    echo !LINE!|findstr /C:"account " >nul
    if not errorlevel 1 (
        set "REST=!LINE:*account =!"
        for /f "tokens=1" %%N in ("!REST!") do (
            echo !ACCOUNTLIST! | findstr /C:"%%N" >nul
            if errorlevel 1 set "ACCOUNTLIST=!ACCOUNTLIST! %%N"
        )
    )
)
del "%GHSTATUSFILE%" 2>nul

set /a ACCTCOUNT=0
for %%A in (!ACCOUNTLIST!) do set /a ACCTCOUNT+=1

if %ACCTCOUNT% GTR 1 (
    call :warn "Multiple GitHub accounts are logged in via gh:"
    set /a N=0
    for %%A in (!ACCOUNTLIST!) do (
        set /a N+=1
        echo     !N!^) %%A
        set "ACCT_!N!=%%A"
    )
    set "ACCTCHOICE="
    set /p "ACCTCHOICE=Select account number to use for the signing key: "
    call set "CHOSENACCT=%%ACCT_!ACCTCHOICE!%%"
    if not "!CHOSENACCT!"=="" (
        gh auth switch --hostname github.com --user "!CHOSENACCT!" >nul 2>nul
        if errorlevel 1 (
            call :warn "Could not switch automatically - continuing with the currently active account."
        ) else (
            call :ok "Switched active gh account to !CHOSENACCT!"
        )
    )
)

rem ---- upload ----
set "DOUPLOAD="
set /p "DOUPLOAD=Upload %PUBKEY% to GitHub as a signing key via gh? [Y/n]: "
if /i "!DOUPLOAD!"=="n" goto :manual

set "KEYTITLE="
set /p "KEYTITLE=Title for this key on GitHub [%COMPUTERNAME%]: "
if "!KEYTITLE!"=="" set "KEYTITLE=%COMPUTERNAME%"

set "UPLOADOUT=%TEMP%\gh_upload_out_%RANDOM%.txt"
echo %CYAN%...uploading signing key to GitHub, please wait...%NC%
gh ssh-key add "%PUBKEY%" --type signing --title "!KEYTITLE!" >"!UPLOADOUT!" 2>&1
type "!UPLOADOUT!"
if not errorlevel 1 (
    call :ok "Uploaded signing key to GitHub."
    set "UPLOADED=1"
    del "!UPLOADOUT!" 2>nul
    goto :configure
)

findstr /C:"admin:ssh_signing_key" "!UPLOADOUT!" >nul
if errorlevel 1 (
    call :err "gh failed to upload the key."
    del "!UPLOADOUT!" 2>nul
    goto :manual
)

del "!UPLOADOUT!" 2>nul
call :warn "Your gh token is missing the 'admin:ssh_signing_key' scope needed to manage signing keys."
set "DOREFRESH="
set /p "DOREFRESH=Run 'gh auth refresh -h github.com -s admin:ssh_signing_key' now and retry? [Y/n]: "
if /i "!DOREFRESH!"=="n" goto :manual

gh auth refresh -h github.com -s admin:ssh_signing_key
if errorlevel 1 (
    call :err "Failed to refresh gh auth scope."
    goto :manual
)

echo %CYAN%...retrying upload...%NC%
gh ssh-key add "%PUBKEY%" --type signing --title "!KEYTITLE!"
if errorlevel 1 (
    call :err "gh failed to upload the key even after refreshing scope."
    goto :manual
) else (
    call :ok "Uploaded signing key to GitHub."
    set "UPLOADED=1"
    goto :configure
)

:manual
if "%UPLOADED%"=="1" goto :configure
echo.
echo %BOLD%Manual setup steps%NC%
echo ------------------------------------------------------------
echo 1. Copy your public key:
echo      type "%PUBKEY%"
echo.
echo 2. Go to https://github.com/settings/ssh/new
echo      - Key type: "Signing Key"
echo      - Paste the key, give it a title, click "Add SSH key"
echo.
echo 3. Continue below to configure git locally.
echo ------------------------------------------------------------
echo.

rem ============================================================
rem 5. Git configuration
rem ============================================================
:configure
call :step "Git configuration"

if "%SKIPGITCONFIG%"=="1" (
    call :warn "Skipping git config changes as requested (existing GPG setup preserved)."
    goto :verify
)

if "%UPLOADED%"=="0" (
    call :warn "This key has NOT been uploaded to GitHub yet."
    echo     Commits will sign successfully on this machine, but GitHub will show them
    echo     as 'Unverified' until you add this key at https://github.com/settings/ssh/new
    echo     ^(as a Signing Key^).
    set "CONTINUEANYWAY="
    set /p "CONTINUEANYWAY=Continue configuring git to sign with this un-uploaded key anyway? [Y/n]: "
    if /i "!CONTINUEANYWAY!"=="n" (
        call :warn "Skipping git config changes. Upload the key to GitHub, then re-run this script."
        goto :verify
    )
)

set "DOCONFIG="
set /p "DOCONFIG=Configure git for SSH signing (gpg.format=ssh, signingkey) now? [Y/n]: "
if /i "!DOCONFIG!"=="n" goto :verify

git config --global gpg.format ssh
git config --global user.signingkey "%PUBKEY%"
call :ok "gpg.format and user.signingkey configured."

set "DOCOMMITSIGN="
set /p "DOCOMMITSIGN=Automatically sign every commit (commit.gpgsign=true)? [Y/n]: "
if /i "!DOCOMMITSIGN!"=="n" (
    git config --global commit.gpgsign false
    call :warn "commit.gpgsign left disabled - sign individual commits with 'git commit -S'"
) else (
    git config --global commit.gpgsign true
    call :ok "commit.gpgsign enabled."
)

set "DOTAGSIGN="
set /p "DOTAGSIGN=Automatically sign every tag (tag.gpgsign=true)? [y/N]: "
if /i "!DOTAGSIGN!"=="y" (
    git config --global tag.gpgsign true
    call :ok "tag.gpgsign enabled."
) else (
    call :warn "tag.gpgsign left disabled - sign individual tags with 'git tag -s'"
)

rem 1Password SSH agent hint (Windows path)
set "OP_SIGN_BIN=%LOCALAPPDATA%\1Password\app\8\op-ssh-sign.exe"
if exist "%OP_SIGN_BIN%" (
    set "USEOP="
    set /p "USEOP=1Password detected - use its SSH agent for signing (gpg.ssh.program)? [y/N]: "
    if /i "!USEOP!"=="y" (
        git config --global gpg.ssh.program "%OP_SIGN_BIN%"
        call :ok "gpg.ssh.program set to 1Password's op-ssh-sign."
    )
)

set "ALLOWEDFILE="
set "DOVERIFY="
set /p "DOVERIFY=Set up local signature verification (allowed_signers)? [y/N]: "
if /i "!DOVERIFY!"=="y" (
    set "GITEMAIL="
    for /f "delims=" %%E in ('git config --global user.email 2^>nul') do set "GITEMAIL=%%E"
    if "!GITEMAIL!"=="" set /p "GITEMAIL=Your git email: "
    set "ALLOWEDFILE=%SSHDIR%\allowed_signers"
    for /f "usebackq tokens=1,2" %%A in ("%PUBKEY%") do (
        echo !GITEMAIL! namespaces="git" %%A %%B>>"!ALLOWEDFILE!"
    )
    git config --global gpg.ssh.allowedSignersFile "!ALLOWEDFILE!"
    call :ok "allowed_signers configured at !ALLOWEDFILE!"
)

rem ============================================================
rem 6. Post-setup verification
rem ============================================================
:verify
call :step "Post-setup verification"

if "%SKIPGITCONFIG%"=="1" (
    call :warn "Git config was left untouched; skipping local signing verification."
    goto :verifygh
)

call :info "Effective git config:"
for /f "delims=" %%V in ('git config --global --get gpg.format 2^>nul') do echo     gpg.format      = %%V
for /f "delims=" %%V in ('git config --global --get user.signingkey 2^>nul') do echo     user.signingkey = %%V
for /f "delims=" %%V in ('git config --global --get commit.gpgsign 2^>nul') do echo     commit.gpgsign  = %%V
for /f "delims=" %%V in ('git config --global --get tag.gpgsign 2^>nul') do echo     tag.gpgsign     = %%V

call :info "Making a real test commit to confirm signing actually works..."
set "TMPDIR=%TEMP%\gh-ssh-sign-test-%RANDOM%"
mkdir "%TMPDIR%"
pushd "%TMPDIR%"
git init -q
for /f "delims=" %%E in ('git config --global user.email 2^>nul') do set "TESTEMAIL=%%E"
for /f "delims=" %%N in ('git config --global user.name 2^>nul') do set "TESTNAME=%%N"
if "%TESTEMAIL%"=="" set "TESTEMAIL=test@example.com"
if "%TESTNAME%"=="" set "TESTNAME=Test User"
git config user.email "%TESTEMAIL%"
git config user.name "%TESTNAME%"
git commit -S -m "ssh signing verification" --allow-empty -q
set "COMMITSTATUS=%ERRORLEVEL%"

if "%COMMITSTATUS%"=="0" (
    call :ok "Test commit signed successfully."
    if not "%ALLOWEDFILE%"=="" (
        set "SIGCHECKFILE=%TEMP%\sigcheck_%RANDOM%.txt"
        git log --show-signature -1 > "!SIGCHECKFILE!" 2>&1
        findstr /C:"Good" "!SIGCHECKFILE!" >nul
        if errorlevel 1 (
            call :warn "Signature could not be verified locally against allowed_signers."
        ) else (
            call :ok "Signature verified against allowed_signers (Good signature)."
        )
        del "!SIGCHECKFILE!" 2>nul
    )
) else (
    call :err "Test commit failed to sign. Common causes:"
    echo     - Passphrase-protected key needs to be loaded in an ssh-agent
    echo     - user.signingkey path is wrong or unreadable
)
popd
rd /s /q "%TMPDIR%" 2>nul

:verifygh
if "%UPLOADED%"=="1" (
    call :info "Confirming the key is registered on GitHub..."
    for /f "usebackq tokens=2" %%B in ("%PUBKEY%") do set "KEYBLOB=%%B"
    set "GHKEYSFILE=%TEMP%\ghkeys_%RANDOM%.txt"
    gh ssh-key list --type signing > "!GHKEYSFILE!" 2>nul
    findstr /C:"!KEYBLOB!" "!GHKEYSFILE!" >nul
    if errorlevel 1 (
        call :warn "Could not confirm the key via 'gh ssh-key list' (it may take a moment to appear)."
    ) else (
        call :ok "Verified: key is registered on GitHub as a signing key."
    )
    del "!GHKEYSFILE!" 2>nul
)

call :success_banner
echo Manual test any time with:
echo   git commit -S -m "test" --allow-empty ^&^& git log --show-signature -1

if "%UPLOADED%"=="0" if "%SKIPGITCONFIG%"=="0" (
    call :warn "Reminder: this key is not yet on GitHub - commits will show as 'Unverified' until you add it at https://github.com/settings/ssh/new"
)

endlocal
