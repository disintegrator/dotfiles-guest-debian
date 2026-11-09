ghcd() {
  local repo="$1"
  repo="${repo#https://github.com/}"
  repo="${repo#http://github.com/}"
  repo="${repo%.git}"

  local dir="$HOME/github.com/$repo"

  if [[ ! -d "$dir" ]]; then
    git clone "https://github.com/$repo.git" "$dir" || return 1
  fi

  cd "$dir"
}
