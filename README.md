# CommitSign

Interactive setup scripts for Git SSH commit signing, plus a doc site with manual SSH and GPG guides. Live at [commitsign.hbenali.ovh](https://commitsign.hbenali.ovh).

## What's here

- `scripts/git-ssh-signing-setup.sh` — Linux/macOS setup script
- `scripts/git-ssh-signing-setup.bat` — Windows setup script
- `index.html` — the doc site (single static file, no build step, no dependencies)

Both scripts: detect an existing GPG signing setup and offer to migrate, generate (or reuse) a key dedicated to signing only, detect the GitHub CLI and upload the key (recovering from a missing `admin:ssh_signing_key` token scope automatically), configure `commit.gpgsign`/`tag.gpgsign` separately, and finish with a real signed test commit to verify everything actually works.

## Quick use

```bash
curl -fsSL https://raw.githubusercontent.com/hbenali/commit-signing-web/main/scripts/git-ssh-signing-setup.sh -o git-ssh-signing-setup.sh
chmod +x git-ssh-signing-setup.sh
./git-ssh-signing-setup.sh
```

Windows:

```
curl -fsSL https://raw.githubusercontent.com/hbenali/commit-signing-web/main/scripts/git-ssh-signing-setup.bat -o git-ssh-signing-setup.bat
git-ssh-signing-setup.bat
```

Both scripts are interactive and confirm before making any change.

## Running the site locally

No build step — just serve the directory:

```bash
python3 -m http.server 8080
# open http://localhost:8080
```

## Deployment

Deployed automatically to GitHub Pages on every push to `main` (see `.github/workflows/`).

## License

MIT — see [LICENSE](LICENSE).
