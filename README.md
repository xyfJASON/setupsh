# setupsh

One-command basic environment setup for a new machine (macOS / Linux).

```bash
curl -fsSL https://raw.githubusercontent.com/xyfJASON/setupsh/main/setup.sh | bash
```

## What it does

| Component | Details |
|-----------|---------|
| **zsh** | Installs zsh, [oh-my-zsh](https://ohmyz.sh), and plugins `zsh-autosuggestions`, `zsh-syntax-highlighting`, `zsh-history-substring-search`; sets `plugins=(git z colored-man-pages safe-paste zsh-autosuggestions zsh-syntax-highlighting zsh-history-substring-search)`; makes zsh the login shell |
| **~/.userrc** | Creates it and sources it from `~/.zshrc`; adds `alias nv="watch -n 0.1 nvidia-smi"` if `nvidia-smi` is present |
| **eza** | Homebrew on macOS, latest release binary on Linux (x86_64 / aarch64); adds `ls`, `l`, `ll`, `lt`, `lt2`, `lt3` aliases |
| **vim** | Writes `~/.vimrc` (line numbers, 4-space indent, syntax on) |
| **tmux** | Installs tmux, writes `~/.tmux.conf` (256 colors, mouse), adds `ta` / `tn` aliases |
| **uv** | Installs [uv](https://docs.astral.sh/uv/) |

Supported package managers: `brew` (installed automatically on macOS if missing), `apt`, `dnf`, `yum`, `pacman`, `zypper`.

## Notes

- **Re-runnable.** Config snippets are written inside marked blocks such as
  `# >>> setupsh eza >>>` … `# <<< setupsh eza <<<`. Re-running replaces those blocks instead of duplicating them, and leaves the rest of your files untouched.
- Installing packages and changing the login shell need `sudo` (unless run as root).
- After it finishes, open a new terminal or run `exec zsh`.
