#!/usr/bin/env bash
#
# Copyright (c) 2026 Houssem Ben Ali (https://hbenali.ovh)
# MIT License — see LICENSE in the repository root.
#
# Interactive setup for Git commit signing with SSH keys.
# Supports Linux and macOS. Detects the GitHub CLI (gh) and uses it to
# upload the signing key automatically; falls back to printed manual
# steps if gh is missing, unauthenticated, or the upload fails.
#
# What it does, in order:
#   1. Pre-flight checks (git/ssh-keygen present, git version >= 2.34)
#   2. OS detection (Linux / macOS) for package-manager hints & Keychain
#   3. Detects an existing GPG commit-signing setup and offers migration
#   4. Selects or generates an SSH key
#   5. Detects gh CLI and uploads the signing key to GitHub if possible
#   6. Configures git (gpg.format, user.signingkey, commit.gpgsign)
#   7. Optionally sets up allowed_signers for local verification
#   8. Post-setup verification: config readback + real signed test commit
#
# Usage: ./git-ssh-signing-setup.sh

set -uo pipefail

# ANSI-C quoting ($'...') so these hold real escape bytes and work in both
# printf "%b" and plain echo/cat/heredocs without needing further interpretation.
BOLD=$'\033[1m'; DIM=$'\033[2m'
GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'; CYAN=$'\033[0;36m'; MAGENTA=$'\033[0;35m'; NC=$'\033[0m'

info()  { printf "%b\n" "${CYAN}==>${NC} $*"; }
ok()    { printf "%b\n" "${GREEN}✓${NC} $*"; }
warn()  { printf "%b\n" "${YELLOW}!${NC} $*"; }
err()   { printf "%b\n" "${RED}✗${NC} $*" >&2; }

STEP_CURRENT=0
STEP_TOTAL=6
step() {
  STEP_CURRENT=$((STEP_CURRENT + 1))
  printf "\n%b\n" "${BOLD}${MAGENTA}┏━━ [${STEP_CURRENT}/${STEP_TOTAL}] $* ${NC}"
}

require_cmd() { command -v "$1" >/dev/null 2>&1; }

print_banner() {
  printf "%b" "${CYAN}${BOLD}"
  cat <<'EOF'
╔══════════════════════════════════════════════════════╗
║        Git SSH Commit Signing — Setup Wizard         ║
╚══════════════════════════════════════════════════════╝
EOF
  printf "%b\n" "${NC}"
  printf "%b\n\n" "${DIM}by Houssem Ben Ali — https://hbenali.ovh${NC}"
}

print_success_banner() {
  printf "%b" "${GREEN}${BOLD}"
  cat <<'EOF'
╔══════════════════════════════════════════════════════╗
║        ✓  SSH commit signing setup complete!         ║
╚══════════════════════════════════════════════════════╝
EOF
  printf "%b\n" "${NC}"
}

# Runs a command in the background with a spinner, capturing its output.
# On failure, prints the captured output indented. Returns the command's status.
SPINNER_FRAMES='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
with_spinner() {
  local msg="$1"; shift
  local out status i=0
  out=$(mktemp)
  ("$@") >"$out" 2>&1 &
  local pid=$!
  if [ -t 1 ]; then
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
      i=$(( (i + 1) % ${#SPINNER_FRAMES} ))
      printf "\r${CYAN}%s${NC} %s" "${SPINNER_FRAMES:$i:1}" "$msg"
      sleep 0.08
    done
    tput cnorm 2>/dev/null || true
    printf "\r\033[K"
  fi
  wait "$pid"
  status=$?
  if [ "$status" -eq 0 ]; then
    ok "$msg"
  else
    err "$msg (failed)"
  fi
  if [ -s "$out" ]; then
    sed "s/^/    ${DIM}/;s/\$/${NC}/" "$out"
  fi
  LAST_SPINNER_OUTPUT=$(cat "$out")
  rm -f "$out"
  return "$status"
}

ask() {
  local prompt="$1" default="${2:-}" reply
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " reply
    echo "${reply:-$default}"
  else
    read -r -p "$prompt: " reply
    echo "$reply"
  fi
}

confirm() {
  local reply
  read -r -p "$1 [y/N]: " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

confirm_default_yes() {
  local reply
  read -r -p "$1 [Y/n]: " reply
  [[ ! "$reply" =~ ^[Nn]$ ]]
}

manual_instructions() {
  local pubkey_path="$1"
  cat <<EOF

${BOLD}Manual setup steps${NC}
------------------------------------------------------------
1. Copy your public key:
     cat "$pubkey_path"

2. Go to https://github.com/settings/ssh/new
   - Key type: "Signing Key"
   - Paste the contents above, give it a title, click "Add SSH key"

3. Configure git to sign commits with this key (done automatically
   below if you accept the next prompt):
     git config --global gpg.format ssh
     git config --global user.signingkey "$pubkey_path"
     git config --global commit.gpgsign true

4. (Optional) verify signatures locally with an allowed_signers file:
     echo "\$(git config --global user.email) namespaces=\"git\" \$(cat "$pubkey_path")" >> ~/.ssh/allowed_signers
     git config --global gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers

5. Test it:
     git commit -S -m "test signed commit" --allow-empty
     git log --show-signature -1
------------------------------------------------------------
EOF
}

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------
OS_NAME="other"
detect_os() {
  case "$(uname -s)" in
    Darwin) OS_NAME="mac" ;;
    Linux)  OS_NAME="linux" ;;
    *)      OS_NAME="other" ;;
  esac
  info "Detected OS: $OS_NAME"
}

install_hint() {
  local tool="$1" pkg="$1"
  case "$OS_NAME" in
    mac)
      if require_cmd brew; then
        echo "brew install $tool"
      else
        echo "install Homebrew (https://brew.sh) then run: brew install $tool"
      fi
      ;;
    linux)
      if require_cmd apt; then
        [ "$tool" = "openssh" ] && pkg="openssh-client"
        echo "sudo apt install $pkg"
      elif require_cmd dnf; then
        [ "$tool" = "openssh" ] && pkg="openssh-clients"
        echo "sudo dnf install $pkg"
      elif require_cmd yum; then
        [ "$tool" = "openssh" ] && pkg="openssh-clients"
        echo "sudo yum install $pkg"
      elif require_cmd pacman; then
        echo "sudo pacman -S $tool"
      elif require_cmd zypper; then
        echo "sudo zypper install $tool"
      elif require_cmd apk; then
        [ "$tool" = "openssh" ] && pkg="openssh-client"
        echo "sudo apk add $pkg"
      else
        echo "install '$tool' with your distro's package manager"
      fi
      ;;
    *)
      echo "install '$tool' for your platform"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
check_prereqs() {
  step "Pre-flight checks"

  if ! require_cmd git; then
    err "git is not installed. $(install_hint git)"
    exit 1
  fi
  ok "git found ($(git --version))"

  if ! require_cmd ssh-keygen; then
    err "ssh-keygen not found (part of OpenSSH). $(install_hint openssh)"
    exit 1
  fi
  ok "ssh-keygen found"

  # SSH commit signing requires git >= 2.34
  local gitver major minor
  gitver=$(git --version | awk '{print $3}')
  major=$(echo "$gitver" | cut -d. -f1)
  minor=$(echo "$gitver" | cut -d. -f2)
  if [ "${major:-0}" -lt 2 ] || { [ "$major" -eq 2 ] && [ "${minor:-0}" -lt 34 ]; }; then
    err "Git 2.34+ is required for SSH commit signing (found $gitver)."
    echo "    $(install_hint git)"
    exit 1
  fi
  ok "git version $gitver supports SSH signing"

  if ! require_cmd gh; then
    warn "gh CLI not found — will fall back to manual GitHub steps. To install: $(install_hint gh)"
  fi
}

# ---------------------------------------------------------------------------
# Existing GPG signing detection + migration prompt
# ---------------------------------------------------------------------------
# Sets SKIP_GIT_CONFIG=true if the user opts to leave existing GPG setup alone.
SKIP_GIT_CONFIG=false

check_existing_gpg_signing() {
  step "Checking for existing commit-signing configuration"

  local old_format old_signingkey old_gpgsign old_tagsign
  old_format=$(git config --global --get gpg.format 2>/dev/null || true)
  old_signingkey=$(git config --global --get user.signingkey 2>/dev/null || true)
  old_gpgsign=$(git config --global --get commit.gpgsign 2>/dev/null || true)
  old_tagsign=$(git config --global --get tag.gpgsign 2>/dev/null || true)

  local has_gpg=false
  if [ -z "$old_format" ] || [ "$old_format" = "openpgp" ]; then
    if [ -n "$old_signingkey" ] || [ "$old_gpgsign" = "true" ]; then
      has_gpg=true
    fi
  fi

  if [ "$has_gpg" = false ]; then
    ok "No existing GPG commit-signing configuration found."
    return
  fi

  warn "You already have GPG commit signing configured:"
  echo "    gpg.format      = ${old_format:-openpgp (default)}"
  echo "    user.signingkey = ${old_signingkey:-<none>}"
  echo "    commit.gpgsign  = ${old_gpgsign:-<unset>}"
  echo "    tag.gpgsign     = ${old_tagsign:-<unset>}"
  echo
  echo "Options:"
  echo "  1) Migrate to SSH signing now (recommended) — replaces the above,"
  echo "     with a backup of the current values saved to disk first."
  echo "  2) Keep GPG signing untouched — this script will skip changing"
  echo "     your git config, but can still create/upload an SSH key."
  echo "  3) Abort"
  local choice
  choice=$(ask "Choose an option" "1")

  case "$choice" in
    1)
      local backup_file="$HOME/.gpg-signing-backup-$$.txt"
      {
        echo "# Backup of previous commit-signing git config."
        echo "# Saved by git-ssh-signing-setup.sh before migrating to SSH signing."
        echo "# To restore, run:"
        echo "git config --global gpg.format \"${old_format:-openpgp}\""
        [ -n "$old_signingkey" ] && echo "git config --global user.signingkey \"$old_signingkey\""
        echo "git config --global commit.gpgsign ${old_gpgsign:-true}"
        [ -n "$old_tagsign" ] && echo "git config --global tag.gpgsign $old_tagsign"
      } > "$backup_file"
      ok "Backed up previous config to $backup_file"
      ok "Proceeding with migration to SSH signing."
      ;;
    2)
      warn "Leaving existing GPG configuration untouched. Git config changes will be skipped."
      SKIP_GIT_CONFIG=true
      ;;
    *)
      err "Aborted by user."
      exit 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Key selection / generation
# ---------------------------------------------------------------------------
select_or_generate_key() {
  step "SSH key selection"

  local default_key="$HOME/.ssh/id_ed25519_signing"
  local existing=()
  for f in "$HOME"/.ssh/id_*.pub; do
    [ -e "$f" ] && existing+=("${f%.pub}")
  done

  KEY_PATH=""
  IS_NEW_KEY=false
  local want_dedicated=true

  if [ "${#existing[@]}" -gt 0 ]; then
    info "Found existing SSH key(s) on this machine:"
    printf '    %s\n' "${existing[@]}"
    echo
    echo "Using a dedicated key just for commit signing (separate from any key you"
    echo "use for SSH authentication) is recommended — it can be rotated or revoked"
    echo "independently without breaking your ability to push/pull over SSH."
    if confirm_default_yes "Generate a new dedicated signing key?"; then
      want_dedicated=true
    else
      want_dedicated=false
    fi
  fi

  if [ "$want_dedicated" = false ] && [ "${#existing[@]}" -gt 0 ]; then
    if [ "${#existing[@]}" -gt 1 ]; then
      warn "Multiple keys found — avoid picking one you already use for Git push/pull authentication as your signing key."
    fi
    info "Choose an existing key to reuse for signing:"
    select opt in "${existing[@]}"; do
      if [ -n "${opt:-}" ]; then
        KEY_PATH="$opt"
        break
      fi
    done
  fi

  if [ -z "$KEY_PATH" ]; then
    KEY_PATH=$(ask "Path for new dedicated signing key" "$default_key")
    if [ -e "$KEY_PATH" ]; then
      warn "Key already exists at $KEY_PATH"
    else
      local default_comment
      default_comment=$(git config --global user.email 2>/dev/null || true)
      local comment
      comment=$(ask "Key comment/email" "${default_comment:+$default_comment (signing)}")
      ssh-keygen -t ed25519 -C "$comment" -f "$KEY_PATH"
      ok "Generated new key at $KEY_PATH"
      IS_NEW_KEY=true
    fi
  fi

  PUBKEY_PATH="${KEY_PATH}.pub"
  if [ ! -f "$PUBKEY_PATH" ]; then
    err "Public key not found at $PUBKEY_PATH"
    exit 1
  fi

  # Does the user have another key (besides this signing key) they could use
  # for Git auth instead, e.g. during 'gh auth login'?
  HAS_OTHER_KEY=false
  for k in "${existing[@]}"; do
    if [ "$k" != "$KEY_PATH" ]; then
      HAS_OTHER_KEY=true
      break
    fi
  done

  # macOS: offer to persist the key's passphrase in the login Keychain via
  # the ssh-agent, so signing doesn't prompt for it on every commit.
  if [ "$OS_NAME" = "mac" ] && [ "$IS_NEW_KEY" = true ]; then
    if confirm "Add this key to ssh-agent and store its passphrase in the macOS Keychain?"; then
      if ssh-add --apple-use-keychain "$KEY_PATH" 2>/dev/null; then
        ok "Key added to ssh-agent with Keychain persistence"
      else
        warn "Could not add key via --apple-use-keychain (ssh-add -K on older macOS). You can retry manually: ssh-add --apple-use-keychain \"$KEY_PATH\""
      fi
    fi
  fi
}

# ---------------------------------------------------------------------------
# gh CLI detection + upload
# ---------------------------------------------------------------------------
UPLOADED_VIA_GH=false

# If more than one GitHub account is logged in via gh, ask which one should
# receive the signing key and switch to it (gh auth switch).
check_gh_multi_user() {
  local accounts count chosen
  accounts=$(gh auth status 2>&1 | grep -oE "account [A-Za-z0-9_-]+" | awk '{print $2}' | sort -u)
  count=$(printf '%s\n' "$accounts" | grep -c .)

  if [ "$count" -le 1 ]; then
    return
  fi

  warn "Multiple GitHub accounts are logged in via gh:"
  printf '%s\n' "$accounts" | sed 's/^/    - /'
  info "Select which account should own the signing key:"
  select chosen in $accounts; do
    [ -n "${chosen:-}" ] && break
  done

  if gh auth switch --hostname github.com --user "$chosen" >/dev/null 2>&1; then
    ok "Switched active gh account to $chosen"
  else
    warn "Could not switch automatically (gh auth switch failed) — continuing with the currently active account."
  fi
}

detect_and_upload_gh() {
  step "GitHub CLI detection"

  local gh_ready=false
  if require_cmd gh; then
    ok "gh CLI detected ($(gh --version | head -1))"
    if gh auth status >/dev/null 2>&1; then
      ok "gh is authenticated"
      gh_ready=true
    else
      warn "gh CLI found but not authenticated."
      echo
      echo "'gh auth login' can ask you to select or upload an SSH key for Git operations"
      echo "(push/pull). Using the same key ($PUBKEY_PATH) for both signing and push"
      echo "authentication is not recommended — compromising or rotating one key then"
      echo "breaks both."
      echo
      local opt3_label
      if [ "$HAS_OTHER_KEY" = true ]; then
        opt3_label="Proceed — I'll pick a different (non-signing) SSH key for Git auth"
      else
        opt3_label="Proceed anyway (discouraged) — normal login, may reuse this signing key for push auth"
      fi

      echo "How would you like to log in?"
      echo "  1) Use GitHub token/HTTPS auth for Git operations (recommended — skips the SSH key question)"
      echo "  2) Abort for now — generate or import a separate SSH key for Git auth first"
      echo "  3) $opt3_label"
      local gh_login_choice
      gh_login_choice=$(ask "Choose an option" "1")

      case "$gh_login_choice" in
        2)
          warn "Skipping 'gh auth login'. To set up a separate key for Git authentication:"
          echo "    ssh-keygen -t ed25519 -C \"your_email@example.com\" -f ~/.ssh/id_ed25519"
          echo "    gh auth login"
          echo "  (or, if you already have a separate key, just run: gh auth login)"
          ;;
        3)
          if [ "$HAS_OTHER_KEY" = true ]; then
            warn "Proceeding — remember to pick a different key than $PUBKEY_PATH when asked."
          else
            warn "Proceeding — avoid selecting $PUBKEY_PATH if asked for a Git auth key."
          fi
          gh auth login
          gh auth status >/dev/null 2>&1 && gh_ready=true
          ;;
        *)
          gh auth login --git-protocol https
          gh auth status >/dev/null 2>&1 && gh_ready=true
          ;;
      esac
    fi
  else
    warn "gh CLI not found."
  fi

  if [ "$gh_ready" = true ]; then
    check_gh_multi_user

    if confirm_default_yes "Upload $PUBKEY_PATH to GitHub as a signing key via gh?"; then
      local title
      title=$(ask "Title for this key on GitHub" "$(hostname)-$(basename "$KEY_PATH")")
      if with_spinner "Uploading signing key to GitHub..." gh ssh-key add "$PUBKEY_PATH" --type signing --title "$title"; then
        UPLOADED_VIA_GH=true
      elif [[ "$LAST_SPINNER_OUTPUT" == *"admin:ssh_signing_key"* ]]; then
        warn "Your gh token is missing the 'admin:ssh_signing_key' scope needed to manage signing keys."
        if confirm_default_yes "Run 'gh auth refresh -h github.com -s admin:ssh_signing_key' now and retry?"; then
          if gh auth refresh -h github.com -s admin:ssh_signing_key; then
            if with_spinner "Retrying upload..." gh ssh-key add "$PUBKEY_PATH" --type signing --title "$title"; then
              UPLOADED_VIA_GH=true
            fi
          else
            err "Failed to refresh gh auth scope."
          fi
        fi
      fi
    fi
  fi

  if [ "$UPLOADED_VIA_GH" = false ]; then
    manual_instructions "$PUBKEY_PATH"
  fi
}

# ---------------------------------------------------------------------------
# Git configuration
# ---------------------------------------------------------------------------
ALLOWED_SIGNERS_FILE=""

configure_git() {
  step "Git configuration"

  if [ "$SKIP_GIT_CONFIG" = true ]; then
    warn "Skipping git config changes as requested (existing GPG setup preserved)."
    return
  fi

  if [ "$UPLOADED_VIA_GH" = false ]; then
    warn "This key has NOT been uploaded to GitHub yet."
    echo "    Commits will sign successfully on this machine, but GitHub will show them"
    echo "    as 'Unverified' until you add this key at https://github.com/settings/ssh/new"
    echo "    (as a Signing Key)."
    if ! confirm_default_yes "Continue configuring git to sign with this un-uploaded key anyway?"; then
      warn "Skipping git config changes. Upload the key to GitHub, then re-run this script."
      return
    fi
  fi

  if ! confirm_default_yes "Configure git for SSH signing (gpg.format=ssh, signingkey) globally now?"; then
    warn "Skipping git config changes."
    return
  fi

  git config --global gpg.format ssh
  git config --global user.signingkey "$PUBKEY_PATH"
  ok "gpg.format and user.signingkey configured"

  if confirm_default_yes "Automatically sign every commit (commit.gpgsign=true)?"; then
    git config --global commit.gpgsign true
    ok "commit.gpgsign enabled"
  else
    git config --global commit.gpgsign false
    warn "commit.gpgsign left disabled — sign individual commits with 'git commit -S'"
  fi

  if confirm "Automatically sign every tag (tag.gpgsign=true)?"; then
    git config --global tag.gpgsign true
    ok "tag.gpgsign enabled"
  else
    warn "tag.gpgsign left disabled — sign individual tags with 'git tag -s'"
  fi

  # macOS + 1Password SSH agent hint
  if [ "$OS_NAME" = "mac" ] && [ -d "/Applications/1Password.app" ]; then
    local op_sign_bin="/Applications/1Password.app/Contents/MacOS/op-ssh-sign"
    if [ -x "$op_sign_bin" ]; then
      if confirm "1Password detected — use its SSH agent for signing (gpg.ssh.program)?"; then
        git config --global gpg.ssh.program "$op_sign_bin"
        ok "gpg.ssh.program set to 1Password's op-ssh-sign"
      fi
    fi
  fi

  if confirm "Set up local signature verification (allowed_signers)?"; then
    local email
    email=$(git config --global user.email 2>/dev/null || true)
    [ -z "$email" ] && email=$(ask "Your git email")
    ALLOWED_SIGNERS_FILE="$HOME/.ssh/allowed_signers"
    echo "$email namespaces=\"git\" $(cat "$PUBKEY_PATH")" >> "$ALLOWED_SIGNERS_FILE"
    git config --global gpg.ssh.allowedSignersFile "$ALLOWED_SIGNERS_FILE"
    ok "allowed_signers configured at $ALLOWED_SIGNERS_FILE"
  fi
}

# ---------------------------------------------------------------------------
# Post-setup verification
# ---------------------------------------------------------------------------
verify_setup() {
  step "Post-setup verification"

  if [ "$SKIP_GIT_CONFIG" = true ]; then
    warn "Git config was left untouched; skipping local signing verification."
  else
    info "Effective git config:"
    echo "    gpg.format               = $(git config --global --get gpg.format 2>/dev/null || echo '<unset>')"
    echo "    user.signingkey          = $(git config --global --get user.signingkey 2>/dev/null || echo '<unset>')"
    echo "    commit.gpgsign           = $(git config --global --get commit.gpgsign 2>/dev/null || echo '<unset>')"
    echo "    tag.gpgsign              = $(git config --global --get tag.gpgsign 2>/dev/null || echo '<unset>')"
    echo "    gpg.ssh.program          = $(git config --global --get gpg.ssh.program 2>/dev/null || echo '<default>')"
    echo "    gpg.ssh.allowedSignersFile = $(git config --global --get gpg.ssh.allowedSignersFile 2>/dev/null || echo '<unset>')"

    info "Making a real test commit to confirm signing actually works..."
    local tmpdir
    tmpdir=$(mktemp -d)
    trap '[ -n "${tmpdir:-}" ] && rm -rf "$tmpdir"' RETURN

    (
      cd "$tmpdir" || exit 1
      git init -q
      git config user.email "$(git config --global user.email 2>/dev/null || echo test@example.com)"
      git config user.name "$(git config --global user.name 2>/dev/null || echo "Test User")"
      git commit -S -m "ssh signing verification" --allow-empty -q
    )
    local commit_status=$?

    if [ "$commit_status" -eq 0 ]; then
      ok "Test commit signed successfully"
      if [ -n "$ALLOWED_SIGNERS_FILE" ]; then
        local sig_output
        sig_output=$(cd "$tmpdir" && git log --show-signature -1 2>&1)
        if echo "$sig_output" | grep -qi "Good"; then
          ok "Signature verified against allowed_signers (Good signature)"
        else
          warn "Signature could not be verified locally. Output:"
          echo "$sig_output" | sed 's/^/    /'
        fi
      fi
    else
      err "Test commit failed to sign. Common causes:"
      echo "    - Passphrase-protected key not loaded in ssh-agent"
      echo "    - user.signingkey path is wrong or unreadable"
      [ "$OS_NAME" = "mac" ] && echo "    - Try: ssh-add --apple-use-keychain \"$KEY_PATH\""
    fi
  fi

  if [ "$UPLOADED_VIA_GH" = true ]; then
    info "Confirming the key is registered on GitHub..."
    local key_blob
    key_blob=$(awk '{print $2}' "$PUBKEY_PATH")
    if gh ssh-key list --type signing 2>/dev/null | grep -q "$key_blob"; then
      ok "Verified: key is registered on GitHub as a signing key"
    else
      warn "Could not confirm the key via 'gh ssh-key list' (it may take a moment to appear)."
    fi
  fi
}

main() {
  print_banner
  detect_os
  check_prereqs
  check_existing_gpg_signing
  select_or_generate_key
  detect_and_upload_gh
  configure_git
  verify_setup

  print_success_banner
  echo "Manual test any time with:"
  echo "  git commit -S -m \"test\" --allow-empty && git log --show-signature -1"

  if [ "$UPLOADED_VIA_GH" = false ] && [ "$SKIP_GIT_CONFIG" = false ]; then
    warn "Reminder: this key is not yet on GitHub — commits will show as 'Unverified' until you add it at https://github.com/settings/ssh/new"
  fi
}

main "$@"
