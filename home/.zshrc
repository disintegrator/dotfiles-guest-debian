# Line editing
autoload edit-command-line
zle -N edit-command-line
bindkey '^x^e' edit-command-line

# History
HISTSIZE=10000
SAVEHIST=10000
HISTFILE=${HISTFILE:-$HOME/.zsh_history}
setopt share_history
setopt hist_ignore_dups
setopt hist_ignore_space

# Editor
export EDITOR=nvim
export VISUAL=nvim

# Helpers
cmd_exists() {
    command -v -- "$1" >/dev/null 2>&1
}

add_to_path() {
  local dir="$1"
  [ -d "$dir" ] || return          # skip if directory doesn't exist
  case ":$PATH:" in
    *":$dir:"*) ;;                  # already present, do nothing
    *) export PATH="$dir:$PATH" ;;  # otherwise prepend
  esac
}

# XDG directories and PATH
xdg_data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
xdg_config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
xdg_bin_home="${XDG_BIN_HOME:-$HOME/.local/bin}"

add_to_path "$xdg_bin_home"
add_to_path "$HOME/go/bin"

# mise activation, before the tool hooks below so they can find the tools
# >>> mise:activate >>> managed by mise — do not edit between markers
eval "$(mise activate zsh)"
# <<< mise:activate <<<

# Local extras
[ -f ~/functions.zsh ] && source ~/functions.zsh
[ -f ~/.profile ] && source ~/.profile
[ -f ~/.aliases.sh ] && source ~/.aliases.sh
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

# Tool hooks
cmd_exists starship && eval "$(starship init zsh)"
cmd_exists zoxide && eval "$(zoxide init zsh)"
cmd_exists atuin && eval "$(atuin init zsh)"
cmd_exists wt && eval "$(command wt config shell init zsh)"
