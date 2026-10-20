# Commit signing

Commits for your GitHub identity are signed with an SSH key, so GitHub shows
"Verified". Only that identity is signed: with `personal_git_email` set, the
personal `includeIf` identity signs and the default (work) identity does not;
without it, every commit is signed.

## Setup

`install.sh` asks for the **public** key path (default `~/.ssh/id_ed25519.pub`
when the pair exists) and writes it to `ansible/local.yml`:

```yaml
signing_key: "~/.ssh/id_ed25519.pub"
```

A value that doesn't end in `.pub` is ignored (never read, so a private key
can't leak into `allowed_signers`) and `scripts/doctor.sh` fails on it. Blank
means no signing. Generate a key if you have none:
`ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519`.

Re-run `./install.sh` (or the playbook) to render the git config and
`~/.config/git/allowed_signers`.

## The manual step

GitHub must know the key as a **signing** key (separate from an auth key).
Once per machine:

```sh
gh ssh-key add ~/.ssh/id_ed25519.pub --type signing --title "$(hostname -s)"
```

## Verify

```sh
scripts/doctor.sh          # key file present; registered on GitHub (WARN if not)
git commit --allow-empty -m test && git log --show-signature -1
```

`Good "git" signature` locally, and "Verified" on GitHub after a push, mean it
works.
