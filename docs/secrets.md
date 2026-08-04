# Secrets

Two layers, use the lightest one that fits:

1. **`~/.config/zsh/local.zsh`** (existing) — machine-local, never committed,
  sourced last by `90-local.zsh`. Fine for tokens that belong to exactly one
  machine and can be re-issued if the disk dies.
2. **age-encrypted chezmoi files** (opt-in, this doc) — secrets that should
  *sync* across machines through the public repo, stored encrypted at rest
  in git. Declarative: a fresh machine gets them from `chezmoi apply` alone.

## Enabling age encryption

The toolchain already provisions `age` + `age-keygen`. One-time setup:

```sh
# 1. Generate a keypair (per person, not per machine).
mkdir -p ~/.config/chezmoi
age-keygen -o ~/.config/chezmoi/key.txt   # prints the public key (age1...)

# 2. Record the PUBLIC key in ansible/local.yml (never committed):
#      age_recipient: "age1..."
#    Re-run install.sh (or the playbook) to regenerate ~/.config/chezmoi/chezmoi.toml
#    with the encryption block. Manual-config machines: uncomment the block in
#    chezmoi.toml.example instead.

# 3. Copy key.txt to your other machines OUT-OF-BAND (scp, password manager).
#    chmod 600 it. The public repo only ever sees ciphertext.
```

## Using it

```sh
chezmoi add --encrypt ~/.config/some-tool/credentials   # commit the encrypted_ file
chezmoi cat ~/.config/some-tool/credentials             # decrypt to stdout
chezmoi edit ~/.config/some-tool/credentials            # edit through the encryption
```

Machines **without** `key.txt` fail to apply encrypted files — enable
encryption everywhere (step 3) before committing the first `encrypted_` file.

## Notes

- The identity file (`key.txt`) is the root of trust: back it up in a password
  manager. Lose it and the ciphertext in git is unrecoverable.
- macOS-only alternative for individual values: chezmoi's `keyring` template
  function stores secrets in the system keychain. Not used here because it
  doesn't cover the no-sudo Linux machines.
- gitleaks (pre-commit + CI) still scans everything; age ciphertext is
  armored binary and does not trip it.
