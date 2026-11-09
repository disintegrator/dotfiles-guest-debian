# Read by every zsh, before .zprofile and .zshrc. Put ~/.local/bin on PATH
# here so the mise activation lines in those files can find mise.
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
