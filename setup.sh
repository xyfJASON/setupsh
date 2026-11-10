#!/usr/bin/env bash
#
# Basic environment setup for a new machine (macOS / Linux).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/xyfJASON/setupsh/main/setup.sh | bash
#
# Safe to re-run: config snippets are written into marked blocks that get
# replaced (not duplicated) on every run, and installed tools are skipped.

set -euo pipefail

# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

has() { command -v "$1" >/dev/null 2>&1; }

# Run a command as root (directly if already root, otherwise via sudo).
as_root() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    elif has sudo; then
        sudo "$@"
    else
        die "need root privileges to run '$*' but sudo is not available"
    fi
}

# upsert_block FILE NAME CONTENT [COMMENT_CHAR] [POSITION]
# Write CONTENT into FILE between "# >>> setupsh NAME >>>" / "# <<< setupsh NAME <<<"
# markers, replacing any previous block with the same NAME. POSITION is "bottom"
# (default) or "top".
upsert_block() {
    local file=$1 name=$2 content=$3 c=${4:-#} pos=${5:-bottom}
    local begin="${c} >>> setupsh ${name} >>>"
    local end="${c} <<< setupsh ${name} <<<"
    local tmp

    touch "$file"
    tmp=$(mktemp)
    if [[ $pos == top ]]; then
        printf '%s\n%s\n%s\n' "$begin" "$content" "$end" > "$tmp"
    fi
    awk -v b="$begin" -v e="$end" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip
    ' "$file" >> "$tmp"
    if [[ $pos != top ]]; then
        printf '%s\n%s\n%s\n' "$begin" "$content" "$end" >> "$tmp"
    fi
    # cat instead of mv so symlinks / permissions of FILE are preserved
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

# ----------------------------------------------------------------------------
# OS / package manager detection
# ----------------------------------------------------------------------------

OS=""
PKG=""

detect_os() {
    case "$(uname -s)" in
        Darwin) OS=macos ;;
        Linux)  OS=linux ;;
        *)      die "unsupported OS: $(uname -s)" ;;
    esac

    if [[ $OS == macos ]]; then
        PKG=brew
    elif has apt-get; then
        PKG=apt
    elif has dnf; then
        PKG=dnf
    elif has yum; then
        PKG=yum
    elif has pacman; then
        PKG=pacman
    elif has zypper; then
        PKG=zypper
    else
        die "no supported package manager found (apt/dnf/yum/pacman/zypper)"
    fi
    info "detected OS: $OS, package manager: $PKG"
}

ensure_brew() {
    if ! has brew; then
        info "installing Homebrew"
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    # make brew available in this shell (Apple Silicon / Intel locations)
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
}

APT_UPDATED=0

pkg_install() {
    case $PKG in
        brew)
            brew install "$@" ;;
        apt)
            if [[ $APT_UPDATED -eq 0 ]]; then
                as_root apt-get update
                APT_UPDATED=1
            fi
            as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        dnf)    as_root dnf install -y "$@" ;;
        yum)    as_root yum install -y "$@" ;;
        pacman) as_root pacman -S --noconfirm --needed "$@" ;;
        zypper) as_root zypper --non-interactive install "$@" ;;
    esac
}

# Install each given command's package only if the command is missing.
ensure_pkgs() {
    local missing=() p
    for p in "$@"; do
        has "$p" || missing+=("$p")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        info "installing: ${missing[*]}"
        pkg_install "${missing[@]}"
    fi
}

# ----------------------------------------------------------------------------
# zsh + oh-my-zsh
# ----------------------------------------------------------------------------

ZSH_PLUGINS="git z colored-man-pages safe-paste conda-zsh-completion zsh-autosuggestions zsh-syntax-highlighting zsh-history-substring-search"

setup_zsh() {
    info "setting up zsh"
    ensure_pkgs zsh

    local omz="$HOME/.oh-my-zsh"
    if [[ ! -d $omz ]]; then
        info "installing oh-my-zsh"
        RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
            sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    else
        info "oh-my-zsh already installed"
    fi

    local custom="${ZSH_CUSTOM:-$omz/custom}"
    local repo name
    for repo in \
        https://github.com/conda-incubator/conda-zsh-completion \
        https://github.com/zsh-users/zsh-autosuggestions \
        https://github.com/zsh-users/zsh-syntax-highlighting \
        https://github.com/zsh-users/zsh-history-substring-search
    do
        name=$(basename "$repo")
        if [[ ! -d $custom/plugins/$name ]]; then
            info "cloning plugin $name"
            git clone --depth=1 "$repo" "$custom/plugins/$name"
        fi
    done

    # set plugins=(...) in ~/.zshrc (replaces the single-line default from the template)
    local zshrc="$HOME/.zshrc" tmp
    touch "$zshrc"
    if grep -q '^plugins=(.*)' "$zshrc"; then
        tmp=$(mktemp)
        awk -v p="plugins=(${ZSH_PLUGINS})" '/^plugins=\(.*\)/ { print p; next } { print }' "$zshrc" > "$tmp"
        cat "$tmp" > "$zshrc"
        rm -f "$tmp"
    else
        warn "no single-line 'plugins=(...)' found in $zshrc; please set manually: plugins=(${ZSH_PLUGINS})"
    fi

    # make zsh the login shell
    local zsh_path
    zsh_path=$(command -v zsh)
    if [[ "$(basename "${SHELL:-}")" != zsh ]]; then
        if ! grep -qx "$zsh_path" /etc/shells 2>/dev/null; then
            echo "$zsh_path" | as_root tee -a /etc/shells >/dev/null || true
        fi
        if ! has chsh; then
            # chsh lives in a different package depending on the distro
            local chsh_pkg=""
            case $PKG in
                apt)     chsh_pkg=passwd ;;
                dnf|yum) chsh_pkg=util-linux-user ;;
                pacman)  chsh_pkg=util-linux ;;
                zypper)  chsh_pkg=shadow ;;
            esac
            if [[ -n $chsh_pkg ]]; then
                info "chsh not found, installing $chsh_pkg"
                pkg_install "$chsh_pkg" || warn "failed to install $chsh_pkg"
            fi
        fi
        info "changing login shell to $zsh_path"
        if [[ $EUID -eq 0 ]]; then
            chsh -s "$zsh_path" || warn "chsh failed; run manually: chsh -s $zsh_path"
        else
            as_root chsh -s "$zsh_path" "$(id -un)" || warn "chsh failed; run manually: chsh -s $zsh_path"
        fi
    fi
}

# ----------------------------------------------------------------------------
# powerlevel10k
# ----------------------------------------------------------------------------

P10K_CONFIG_URL="https://raw.githubusercontent.com/xyfJASON/setupsh/main/p10k.zsh"

setup_p10k() {
    info "setting up powerlevel10k"

    local custom="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
    if [[ ! -d $custom/themes/powerlevel10k ]]; then
        info "cloning powerlevel10k"
        git clone --depth=1 https://github.com/romkatv/powerlevel10k "$custom/themes/powerlevel10k"
    else
        info "powerlevel10k already installed"
    fi

    # set ZSH_THEME in ~/.zshrc (must stay before oh-my-zsh.sh is sourced)
    local zshrc="$HOME/.zshrc" tmp
    if grep -q '^ZSH_THEME=' "$zshrc"; then
        tmp=$(mktemp)
        awk '/^ZSH_THEME=/ { print "ZSH_THEME=\"powerlevel10k/powerlevel10k\""; next } { print }' "$zshrc" > "$tmp"
        cat "$tmp" > "$zshrc"
        rm -f "$tmp"
    else
        warn "no 'ZSH_THEME=' line found in $zshrc; please set manually: ZSH_THEME=\"powerlevel10k/powerlevel10k\""
    fi

    # install the saved config: prefer a p10k.zsh next to this script (local
    # checkout), otherwise download it (curl | bash)
    local src="" dir
    dir=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd) || true
    tmp=$(mktemp)
    if [[ -n $dir && -f $dir/p10k.zsh ]]; then
        src="$dir/p10k.zsh"
        cp "$src" "$tmp"
    elif curl -fsSL "$P10K_CONFIG_URL" -o "$tmp"; then
        src="$P10K_CONFIG_URL"
    fi
    if [[ -n $src ]]; then
        if [[ -f $HOME/.p10k.zsh ]] && ! cmp -s "$tmp" "$HOME/.p10k.zsh"; then
            info "backing up existing ~/.p10k.zsh to ~/.p10k.zsh.bak"
            cp "$HOME/.p10k.zsh" "$HOME/.p10k.zsh.bak"
        fi
        info "installing ~/.p10k.zsh from $src"
        cat "$tmp" > "$HOME/.p10k.zsh"
    else
        warn "could not fetch p10k config; run 'p10k configure' to create one"
    fi
    rm -f "$tmp"

    upsert_block "$zshrc" p10k-instant-prompt "$(cat <<'EOF'
# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi
EOF
)" '#' top
    upsert_block "$zshrc" p10k '[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh'
}

# ----------------------------------------------------------------------------
# ~/.userrc
# ----------------------------------------------------------------------------

setup_userrc() {
    info "setting up ~/.userrc"
    touch "$HOME/.userrc"
    upsert_block "$HOME/.zshrc" userrc '[ -f ~/.userrc ] && source ~/.userrc'

    if has nvidia-smi; then
        info "GPU machine detected, adding nvidia-smi alias"
        upsert_block "$HOME/.userrc" gpu 'alias nv="watch -n 0.1 nvidia-smi"'
    fi
}

# ----------------------------------------------------------------------------
# eza
# ----------------------------------------------------------------------------

setup_eza() {
    info "setting up eza"
    if ! has eza; then
        if [[ $OS == macos ]]; then
            brew install eza
        else
            local arch
            case "$(uname -m)" in
                x86_64)        arch=x86_64 ;;
                aarch64|arm64) arch=aarch64 ;;
                *) die "unsupported architecture for eza: $(uname -m)" ;;
            esac
            local tmpdir
            tmpdir=$(mktemp -d)
            curl -fsSL "https://github.com/eza-community/eza/releases/latest/download/eza_${arch}-unknown-linux-gnu.tar.gz" \
                | tar xz -C "$tmpdir"
            as_root install -m 0755 "$tmpdir/eza" /usr/local/bin/eza
            rm -rf "$tmpdir"
        fi
    else
        info "eza already installed"
    fi

    upsert_block "$HOME/.userrc" eza "$(cat <<'EOF'
alias ls="eza"
alias l="eza -lah"
alias ll="eza -lh"
alias lt="eza -lah --tree"
alias lt2="eza -lah --tree --level=2"
alias lt3="eza -lah --tree --level=3"
EOF
)"
}

# ----------------------------------------------------------------------------
# vim
# ----------------------------------------------------------------------------

setup_vim() {
    info "setting up ~/.vimrc"
    upsert_block "$HOME/.vimrc" vim "$(cat <<'EOF'
set nu
set autoindent
set tabstop=4
set shiftwidth=4
set expandtab
syntax on
EOF
)" '"'
}

# ----------------------------------------------------------------------------
# tmux
# ----------------------------------------------------------------------------

setup_tmux() {
    info "setting up tmux"
    ensure_pkgs tmux

    upsert_block "$HOME/.tmux.conf" tmux "$(cat <<'EOF'
set -g default-terminal "screen-256color"
set -g mouse on
set-option -s set-clipboard on
EOF
)"

    upsert_block "$HOME/.userrc" tmux "$(cat <<'EOF'
alias ta="tmux a -t"
alias tn="tmux new -s"
EOF
)"
}

# ----------------------------------------------------------------------------
# uv
# ----------------------------------------------------------------------------

setup_uv() {
    info "setting up uv"
    if ! has uv && [[ ! -x $HOME/.local/bin/uv ]]; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
    else
        info "uv already installed"
    fi
}

# ----------------------------------------------------------------------------
# nvitop (GPU machines only)
# ----------------------------------------------------------------------------

setup_nvitop() {
    has nvidia-smi || return 0
    info "setting up nvitop"
    local uv
    uv=$(command -v uv || echo "$HOME/.local/bin/uv")
    if [[ ! -x $uv ]]; then
        warn "uv not found; skipping nvitop"
        return 0
    fi
    if "$uv" tool list 2>/dev/null | grep -q '^nvitop '; then
        info "nvitop already installed"
    else
        "$uv" tool install nvitop
    fi
}

# ----------------------------------------------------------------------------
# conda
# ----------------------------------------------------------------------------

# Print the path of an existing conda executable, if any. conda is usually a
# shell function set up by `conda init`, so it's not on PATH in this script.
find_conda() {
    local c
    for c in "${CONDA_EXE:-}" "$(command -v conda || true)" \
        "$HOME"/{miniconda3,anaconda3,miniforge3}/bin/conda /opt/conda/bin/conda; do
        if [[ -n $c && -x $c ]]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

setup_conda() {
    info "setting up conda"
    local conda
    if conda=$(find_conda); then
        info "conda already installed at $conda"
    else
        local os arch
        case $OS in
            macos) os=MacOSX ;;
            linux) os=Linux ;;
        esac
        case "$(uname -m)" in
            x86_64)  arch=x86_64 ;;
            aarch64) arch=aarch64 ;;
            arm64)   arch=arm64 ;;
            *) die "unsupported architecture for miniconda: $(uname -m)" ;;
        esac
        local tmp
        tmp=$(mktemp)
        info "installing miniconda to ~/miniconda3"
        curl -fsSL "https://repo.anaconda.com/miniconda/Miniconda3-latest-${os}-${arch}.sh" -o "$tmp"
        bash "$tmp" -b -p "$HOME/miniconda3"
        rm -f "$tmp"
        conda="$HOME/miniconda3/bin/conda"
    fi

    # run even if conda was already installed: it may only have been
    # initialized for bash. conda init is a no-op if ~/.zshrc is already set up.
    "$conda" init zsh

    # newer conda renamed auto_activate_base to auto_activate
    "$conda" config --set auto_activate false 2>/dev/null \
        || "$conda" config --set auto_activate_base false

    upsert_block "$HOME/.userrc" conda "$(cat <<'EOF'
alias act="conda activate"
alias deact="conda deactivate"
EOF
)"
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

main() {
    detect_os
    [[ $OS == macos ]] && ensure_brew
    ensure_pkgs git curl

    setup_zsh
    setup_p10k
    setup_userrc
    setup_eza
    setup_vim
    setup_tmux
    setup_uv
    setup_nvitop
    setup_conda

    info "done! start a new shell (or run 'exec zsh') to pick up the changes."
}

# Everything is wrapped in functions so a partially-downloaded script never runs;
# the guard also lets the file be sourced (e.g. for testing) without side effects.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
