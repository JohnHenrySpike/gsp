# gsp — per-folder SSH keys and git identities

Declare a root folder (`~/work/mechta`, `~/pet` — anything), and **every** repository
inside it automatically uses its own SSH key and its own `user.name` / `user.email`.

**Clone URLs stay untouched** — you keep typing plain
`git clone git@github.com:acc/repo.git`, and ssh figures out the key on its own.

## Installing and updating

Run either of these — `curl` or `wget`:

```bash
curl -fsSL https://raw.githubusercontent.com/JohnHenrySpike/gsp/master/gsp.sh | bash
```

```bash
wget -qO- https://raw.githubusercontent.com/JohnHenrySpike/gsp/master/gsp.sh | bash
```

The script installs itself into `~/.local/bin/gsp`, writes the completions, prepares
`~/.config/gsp`, `~/.ssh` and `~/.gitconfig`, and asks about `PATH` for each shell it
finds. The questions are read from `/dev/tty`, so they work even though `stdin` is the
pipe. Running the same line again updates an existing install.

To skip the questions and set up every shell found, pass the flag after `--`:

```bash
curl -fsSL https://raw.githubusercontent.com/JohnHenrySpike/gsp/master/gsp.sh | bash -s -- --setup-path
```

**Pipe into `bash`, not into `zsh` or `sh`.** A pipe skips the `#!/usr/bin/env bash`
line, so the shell you name is the one that runs the script — and the script is bash.
`... | zsh` used to die on `BASH_SOURCE[0]: parameter not set`; it now prints a short
"gsp needs bash" message instead. Which shell you *type* in does not matter: zsh and
fish users pipe into `bash` just the same.

## Quick start

From a clone, with no command at all:

```bash
./gsp.sh             # same as ./gsp.sh install
```

```bash
./gsp.sh install     # installs gsp into ~/.local/bin + completions (zsh/fish),
                     # prepares ~/.config/gsp, ~/.ssh and ~/.gitconfig
```

`install` invents no profiles — you create them yourself, from the folder where
the repositories will live:

```bash
cd ~/work
gsp add mechta       # default root is ~/work/mechta
```

`install` finds every installed shell (zsh, bash, fish) and asks about each one
separately before touching its rc file. The shell you are typing in comes first
and defaults to yes (`[Y/n]`); the others default to no (`[y/N]`). Lines are added
between the `# >>> gsp >>>` / `# <<< gsp <<<` markers, idempotently and with a
backup; shells that are already set up are skipped. Afterwards run `exec <shell>`.

The shell is detected from the parent process, not from `$SHELL`: that variable
holds the **login shell from `/etc/passwd`**, which may differ from the one you
actually work in (a common case: login shell fish, daily driver zsh).

With no terminal to ask on (a script, CI, a wrapper without a tty), install asks
nothing and prints the instructions at the end of its output instead.

```bash
./gsp.sh install --setup-path      # set up every shell found, no questions
./gsp.sh install --shell zsh,fish  # ask about these shells only
./gsp.sh install --no-setup-path   # never touch rc files
```

The script always runs under bash (`#!/usr/bin/env bash`), so it behaves the same
whether you call it from zsh, bash or fish.

When it is piped in rather than run from a file there is nothing on disk to copy, so
`install` downloads the script from GitHub instead. Set `GSP_SOURCE_URL` to install
from somewhere else (a fork, a branch, a `file://` path).

Then:

```bash
cd ~/work/mechta
git clone git@github.com:company/service.git   # goes out with the work key
cd ~/pet
git clone git@github.com:myself/toy.git        # goes out with the personal key
```

If you would rather set `PATH` by hand:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc   # zsh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc  # bash
```

```fish
fish_add_path ~/.local/bin                                # fish
```

## How it works

Two independent layers:

1. **Key selection** — `~/.ssh/config`:

   ```
   Match host github.com exec "/home/<user>/.local/bin/gsp ssh-match work"
       IdentityFile /home/<user>/.ssh/id_ed25519_work_github_com
       IdentitiesOnly yes
   ```

   `Match exec` asks `gsp` whether the current working directory is inside the
   profile's root folder. This works during `git clone` (no repository exists yet)
   as well as on `fetch`/`push` inside a repository — unlike `includeIf`, which
   does not apply while cloning.

   Two accounts on the same host are told apart by the key that is offered, so the
   hostname stays real and the URL needs no rewriting.

2. **Commit name and email** — `~/.gitconfig`:

   ```
   [includeIf "gitdir:/home/<user>/work/mechta/"]
       path = /home/<user>/.config/gsp/gitconfig.d/work.gitconfig
   ```

Both sections live between `# >>> gsp managed … >>>` / `# <<< gsp managed <<<`
markers and are regenerated wholesale by `gsp apply`. Everything outside the
markers is left alone, and the file is backed up before the first change.

## Commands

| Command | What it does |
|---|---|
| `gsp add [name]` | create a profile: folder + key + `user.name`/`user.email`; default root is `<current folder>/<name>` |
| `gsp host add <profile> <host>` | add a host (`gitlab.com`, …) to a profile |
| `gsp host rm <profile> <host>` | unbind a host |
| `gsp list` | show profiles, hosts, keys and fingerprints |
| `gsp key <profile> [host]` | public key to paste into the service |
| `gsp clone <url> [dir]` | clone inside the profile folder |
| `gsp apply` | regenerate `~/.ssh/config` and `~/.gitconfig` |
| `gsp remove <profile>` | delete a profile (your code folder is never touched) |
| `gsp doctor` | diagnostics: modes, keys, and the **real** key choice via `ssh -G` |
| `gsp install` | install into `~/.local/bin`, prepare `~/.ssh` and `~/.gitconfig`, add zsh/fish completions, ask about `PATH` per shell — **the default when no command is given** |

The global `--dry-run` flag prints what would be written and changes nothing.

Non-interactive usage:

```bash
gsp add work --root ~/work/mechta --name "John Spike" --email john@company.com --host github.com
gsp host add work gitlab.com
gsp host add work git.company.com --reuse gitlab.com   # reuse an existing key
```

## Adding a key to the service

```bash
gsp key work github.com
```

The public key is printed together with a link to the right settings page.

## Checking that it works

```bash
gsp doctor
```

Or by hand — `ssh -G` shows which key will actually be picked:

```bash
cd ~/work/mechta
ssh -G git@github.com | grep identityfile
ssh -T git@github.com          # the reply tells you which account you logged in as
```

## Limits

- **The key is chosen by the current directory.** `git clone <url> ~/work/mechta/x`
  started from `~` will not pick it up — clone from inside the profile folder
  (`gsp clone` does that for you).
- The rule only covers hosts added to the profile. A new service means
  `gsp host add`.
- Outside every profile root no `Match` fires, and ssh falls back to its default
  keys — expected behaviour, and `doctor` says so.
- Profile roots must not nest inside each other; `gsp add` refuses such a folder.
- `root` is resolved through `realpath`, because git resolves symlinks in
  `gitdir:` — a symlinked root would silently skip `includeIf`. `doctor` warns
  about it.

## Files

| Path | Role |
|---|---|
| `~/.config/gsp/profiles/<name>.conf` | source of truth |
| `~/.config/gsp/gitconfig.d/<name>.gitconfig` | git include with `[user]` only |
| `~/.gitconfig` | managed section with `includeIf` |
| `~/.ssh/config` | managed section with `Match` blocks |
| `~/.ssh/id_ed25519_<profile>_<host>` | keys (ed25519, no passphrase) |
| `~/.local/bin/gsp` | the installed script |
| `~/.config/gsp/gsp.zsh`, `~/.config/fish/completions/gsp.fish` | completions |

## Rolling back

```bash
gsp remove <profile>          # drops the profile from the configs, offers to delete keys
```

Full manual rollback: delete the block between the `# >>> gsp managed …` and
`# <<< gsp managed <<<` markers in `~/.ssh/config` and `~/.gitconfig`, remove the
`# >>> gsp >>>` block from your shell rc file, then `rm -rf ~/.config/gsp
~/.local/bin/gsp`. Backups made along the way sit next to the originals as
`<file>.gsp-bak.<timestamp>`.
