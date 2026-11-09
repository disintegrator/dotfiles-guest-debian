#!/usr/bin/env bash

set -euf -o pipefail


log() {
  local level=$1 message=$2
  shift 2
  gum log --structured --level "$level" "$message" "$@"
}

info() {
  log info "$@"
}
warn() {
  log warn "$@"
}
err() {
  log error "$@"
}

pink=212
reboot_needed=0
heading() { gum style --foreground "$pink" --bold "$1"; }
kv()      { printf '  %s  %s\n' "$(gum style --foreground 240 --width 10 "$1")" "$(gum style --bold "$2")"; }

docker_post() {
  if ! getent group docker >/dev/null; then
    sudo groupadd docker
    info "Created docker group"
  fi

  if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
    sudo usermod -aG docker "$USER"
    info "Added $USER to docker group"
  fi
}
docker_post

# Ubuntu mounts /tmp as tmpfs, so temporary files eat RAM. Mask the mount unit
# so /tmp is a plain directory on disk from the next boot. Never unmount it
# live: programs with files in /tmp would lose them.
tmp_on_disk() {
  local state
  state=$(systemctl is-enabled tmp.mount 2>/dev/null || true)
  if [[ $state != masked ]]; then
    sudo systemctl mask tmp.mount >/dev/null 2>&1
    info "Masked tmp.mount; /tmp moves to disk on the next reboot"
  fi
  if findmnt -n -t tmpfs /tmp >/dev/null 2>&1; then
    reboot_needed=1
  fi
}
tmp_on_disk

# Optionally route the machine through the iron-proxy gateway. This relies on
# the host running iron-proxy with a tunnel listener (see dotfiles-host), so it
# is opt-in. Once opted in, re-runs reconcile the files without prompting.
proxy_setup() {
  # 100.64.0.0/10 is the CGNAT range Tailscale assigns from; .ts.net is MagicDNS.
  local no_proxy="localhost,127.0.0.1,::1,.ts.net,100.64.0.0/10"
  local ca_dst="/usr/local/share/ca-certificates/iron-ca.crt"
  local ca_src="$HOME/iron-ca.crt"
  local apt_conf="/etc/apt/apt.conf.d/99-proxy"
  local fqdn host suffix proxy_url=""
  # Prefer the Tailscale MagicDNS name, since scp will go over Tailscale SSH.
  fqdn=$(tailscale status --self --json 2>/dev/null | jq -r '.Self.DNSName | rtrimstr(".")' 2>/dev/null) || true
  if [[ -n ${fqdn:-} && $fqdn != null ]]; then
    host=$fqdn
    suffix=${fqdn#*.}
  else
    host=$(hostname)
    suffix=""
  fi

  # The gateway address is machine-specific, so it is asked for once and then
  # read back from the apt proxy file this function writes.
  if [[ -f $apt_conf ]]; then
    proxy_url=$(sed -n 's/^Acquire::https::Proxy "\(.*\)";$/\1/p' "$apt_conf")
  fi

  if [[ ! -f $ca_dst ]]; then
    if [[ ! -t 0 ]]; then
      info "No TTY; skipping optional proxy setup. Run 'mise run bootstrap' interactively to configure it."
      return
    fi
    {
      heading "Optional: iron-proxy gateway"
      echo
      echo "Routes this machine's HTTP(S) traffic through the host's iron-proxy,"
      echo "which injects real API tokens in place of the placeholder values."
      echo "Requires iron-proxy running on the host with a tunnel listener."
    } | gum style --border rounded --border-foreground "$pink" --padding "1 2"
    if ! gum confirm --default=false --affirmative "Configure" --negative "Skip" "Configure the proxy now?"; then
      info "Skipped proxy setup. Run 'mise run bootstrap' again to configure it later."
      return
    fi
    while [[ ! -f $ca_src ]]; do
      {
        heading "Proxy CA certificate needed"
        echo
        echo "Copy the iron-proxy CA onto this machine. From the Mac, run:"
        echo
        gum style --bold "  scp ~/.local/share/iron-proxy/iron-ca.crt ${USER}@${host}:iron-ca.crt"
      } | gum style --border rounded --border-foreground "$pink" --padding "1 2"
      if ! gum confirm --affirmative "Continue" --negative "Skip proxy setup" "Press enter once the file is in place."; then
        warn "Skipped proxy setup"
        return
      fi
      [[ -f $ca_src ]] || warn "File not found" path "$ca_src"
    done
    sudo install -m 0644 "$ca_src" "$ca_dst"
    sudo update-ca-certificates >/dev/null
    rm -f "$ca_src"
    info "Installed proxy CA" path "$ca_dst"
  fi

  if [[ -z $proxy_url ]]; then
    if [[ ! -t 0 ]]; then
      warn "No TTY to ask for the proxy gateway; skipping proxy setup."
      return
    fi
    local gateway port
    gateway=$(gum input --header "Proxy gateway hostname (the machine running iron-proxy)" \
      --placeholder "gateway${suffix:+.$suffix}") || { warn "Skipped proxy setup"; return; }
    [[ -n $gateway ]] || { warn "No gateway given; skipped proxy setup"; return; }
    # A bare hostname gets this tailnet's MagicDNS suffix.
    [[ $gateway == *.* || -z $suffix ]] || gateway="$gateway.$suffix"
    port=$(gum input --header "iron-proxy tunnel listener port" --value "3128") || { warn "Skipped proxy setup"; return; }
    proxy_url="http://${gateway}:${port}"
    info "Using proxy" url "$proxy_url"
  fi

  # write_root_file PATH CONTENT: write as root only when the content differs.
  # Returns 0 when the file changed, 1 when it was already up to date.
  write_root_file() {
    local path=$1 content=$2
    if [[ -f $path ]] && [[ "$(<"$path")" == "$content" ]]; then
      return 1
    fi
    sudo install -d -m 0755 "$(dirname "$path")"
    printf '%s\n' "$content" | sudo tee "$path" >/dev/null
    sudo chmod 0644 "$path"
    info "Wrote" path "$path"
    return 0
  }

  write_root_file "$apt_conf" "$(cat <<EOF2
Acquire::http::Proxy "${proxy_url}";
Acquire::https::Proxy "${proxy_url}";
EOF2
)" || true

  # Login shells: bash, and zsh via /etc/zsh/zprofile -> /etc/profile.
  write_root_file /etc/profile.d/proxy.sh "$(cat <<EOF2
export HTTP_PROXY="${proxy_url}"
export HTTPS_PROXY="${proxy_url}"
export NO_PROXY="${no_proxy}"
export http_proxy="\$HTTP_PROXY"
export https_proxy="\$HTTPS_PROXY"
export no_proxy="\$NO_PROXY"
export NODE_USE_SYSTEM_CA=1
export NODE_USE_ENV_PROXY=1
export SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt"
export REQUESTS_CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"
EOF2
)" || true

  # systemd user manager, so the dev.mise.* units and what they spawn inherit it.
  if write_root_file /etc/environment.d/50-proxy.conf "$(cat <<EOF2
HTTP_PROXY=${proxy_url}
HTTPS_PROXY=${proxy_url}
NO_PROXY=${no_proxy}
http_proxy=${proxy_url}
https_proxy=${proxy_url}
no_proxy=${no_proxy}
NODE_USE_SYSTEM_CA=1
NODE_USE_ENV_PROXY=1
SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
EOF2
)"; then
    systemctl --user daemon-reload
  fi

  # Docker daemon pulls images itself, so it needs the proxy too.
  if write_root_file /etc/systemd/system/docker.service.d/http-proxy.conf "$(cat <<EOF2
[Service]
Environment="HTTP_PROXY=${proxy_url}"
Environment="HTTPS_PROXY=${proxy_url}"
Environment="NO_PROXY=${no_proxy}"
EOF2
)"; then
    sudo systemctl daemon-reload
    sudo systemctl restart docker
    info "Restarted docker with proxy settings"
  fi
}
proxy_setup

paseo_post() {
  if ! status=$(tailscale status --self --json 2>/dev/null); then
    err "Expected Tailscale to be running but it was not. Boostrap script may be broken."
    return
  fi

  status=$(tailscale status --self --json)
  fqdn=$(jq -r '.Self.DNSName | rtrimstr(".")' <<<"$status")
  host=${fqdn%%.*}
  
  hostnames=$(jq -cn --arg h "$host" --arg f "$fqdn" '[$h, $f]')
  origins=$(jq -cn --arg f "$fqdn" '["https://app.paseo.sh", "https://\($f)"]')
  
  paseo daemon config set daemon.hostnames "$hostnames" >/dev/null
  paseo daemon config set daemon.cors.allowedOrigins "$origins" >/dev/null
  paseo daemon config set features.webUi.enabled true >/dev/null
  paseo daemon restart >/dev/null 2>&1 || true
}
paseo_post

# Units are declared with `start = false` because their binaries come from
# [tools], which mise installs after it writes the units. Start them here.
start_services() {
  local units=(
    dev.mise.opencode.service
    dev.mise.paseo.service
    dev.mise.opencode-tailscale.service
    dev.mise.paseo-tailscale.service
    dev.mise.pitchfork-tailscale.service
  )
  if systemctl --user start "${units[@]}"; then
    info "Started systemd user units" units "${units[*]}"
  else
    err "Failed to start systemd user units" units "${units[*]}"
  fi
}
start_services

print_tailscale() {
  if ! status=$(tailscale status --self --json 2>/dev/null); then
    err "Expected Tailscale to be running but it was not. Boostrap script may be broken."
    return
  fi

  fqdn=$(jq -r '.Self.DNSName | rtrimstr(".")' <<<"$status")
  ipv4=$(jq -r '.TailscaleIPs[] | select(test("^[0-9.]+$"))' <<<"$status")
  host=${fqdn%%.*}

  {
    heading "Tailscale node"
    kv "name" "$fqdn"
    kv "ipv4" "$ipv4"
    echo
    heading "Bookmark these"
    kv "Paseo"    "https://${fqdn}"
    kv "OpenCode" "https://${fqdn}:49374"
    kv "Pitchfork" "https://${fqdn}:3120"
    echo
    heading "SSH (Tailscale SSH, no keys needed)"
    kv "" "ssh ${USER}@${host}"
  } | gum style --border rounded --border-foreground "$pink" --padding "1 2"
}
print_tailscale

# Last step: reboot if something above set reboot_needed, but only with
# approval. Today the only trigger is tmp_on_disk: masking tmp.mount takes
# effect at boot, and /tmp cannot be unmounted live. Keep the user-facing
# message generic so other steps can set the flag without changing it.
maybe_reboot() {
  [[ $reboot_needed == 1 ]] || return 0
  if [[ ! -t 0 ]]; then
    warn "A reboot is required to finish setup. Reboot when convenient."
    return 0
  fi
  echo
  if gum confirm --default=false --affirmative "Reboot now" --negative "Later" \
      "A reboot is required to finish setup. Reboot now?"; then
    info "Rebooting"
    sudo systemctl reboot
  else
    warn "Skipped reboot. Setup finishes after the next reboot."
  fi
}
maybe_reboot
