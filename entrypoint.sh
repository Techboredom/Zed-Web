#!/usr/bin/env bash
set -euo pipefail

# Where Zed opens on launch - see sway-config. Defaulting to /workspace
# keeps this exactly matching prior behavior when unset (Docker Compose's
# own bind mount); a deployment that already has a single /home/zed volume
# (e.g. Kubernetes) can point this inside it instead and skip a second
# volume/mount entirely.
WORKSPACE_DIR="${ZED_WORKSPACE_DIR:-/workspace}"

mkdir -p "$XDG_RUNTIME_DIR" "$WORKSPACE_DIR" /home/zed/.config/zed /home/zed/.local/share/zed
chown zed:zed "$XDG_RUNTIME_DIR" "$WORKSPACE_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# The zed-config/zed-data named volumes mount over .config/zed and
# .local/share/zed. Docker creates a new named volume's initial contents
# root:root when there's nothing in the image at that exact path to copy
# ownership from (there isn't, until Zed itself runs once), which shadows
# the build-time `chown -R zed:zed /home/zed/.config` and leaves Zed unable
# to write there.
chown -R zed:zed /home/zed/.config/zed /home/zed/.local/share/zed

# k8s (or anything mounting a volume over the *whole* of $HOME, rather than
# compose's narrower .config/zed + .local/share/zed above): a fresh/empty
# volume there shadows everything the image baked in - Zed itself, rustup,
# uv, npm-global tools, and critically ~/.config/sway/config (the one line
# that launches Zed at all). Restore from the golden backup built at image
# build time. .provisioned (itself part of that backup) makes this a no-op
# once already done - including for the compose deployment, which never
# empties $HOME in the first place and so already has it from the image
# directly, never touching this branch at all.
if [ ! -e "$HOME/.provisioned" ]; then
  echo "First boot on this \$HOME - restoring zed/rustup/uv/npm-global tools and config from the image..."
  rsync -a /opt/zed-home-seed/ "$HOME/"
fi
# Re-assert after a possible reseed above, in case ZED_WORKSPACE_DIR points
# somewhere under $HOME that the golden backup wouldn't itself contain
# (it's a backup of $HOME, taken before any workspace files existed there).
mkdir -p "$WORKSPACE_DIR"
chown zed:zed "$WORKSPACE_DIR"

# Opt-in: re-fetch latest zed/rustup/uv/npm-global tools on every start.
# Off by default because it needs network access and adds real time (a
# fresh Zed download alone is ~150MB) to every single pod restart, not just
# the first. Only covers what actually lives under $HOME and so is at risk
# from the volume-shadowing issue above - go/node/asdf's own binary/Chrome/
# sway etc. are all system packages baked into the image itself; refresh
# those by rebuilding the image, not from here. Failures here are
# non-fatal: better to start with whatever's already installed than not
# start at all over a transient network blip.
if [ "${UPDATE_ON_START:-false}" = "true" ]; then
  echo "UPDATE_ON_START=true - updating zed/rustup/uv/npm-global tools..."
  setpriv --reuid=zed --regid=zed --keep-groups bash -c '
    set -x
    curl -f https://zed.dev/install.sh | sh
    rustup update
    uv self update
    npm install -g @anthropic-ai/claude-code@latest @earendil-works/pi-coding-agent@latest
  ' || echo "WARNING: UPDATE_ON_START did not complete cleanly; continuing with what was already installed." >&2
fi

if [ -n "${VNC_PASSWORD:-}" ]; then
  export NOVNC_AUTH_ARGS="--web-auth --auth-plugin=websockify.auth_plugins.BasicHTTPAuth --auth-source=${VNC_USERNAME:-zed}:${VNC_PASSWORD}"
else
  echo "WARNING: VNC_PASSWORD is not set. The browser endpoint has NO authentication." >&2
  echo "         Set -e VNC_PASSWORD=... or put this behind a trusted network/reverse proxy." >&2
  export NOVNC_AUTH_ARGS=""
fi

if [ -e /dev/dri ]; then
  echo "Found /dev/dri - hardware GPU rendering available."
else
  echo "WARNING: /dev/dri not found in container. Pass through the Intel GPU node with" >&2
  echo "         --device /dev/dri/cardN --device /dev/dri/renderDNNN or Zed/sway will fail." >&2
fi

# supervisord (once dropped to zed below) reopens /dev/stdout and /dev/stderr
# itself for each child program's stdout_logfile/stderr_logfile, rather than
# just inheriting the fds. Those point at Docker's own log pipe, created
# root:root mode 0600, so that reopen fails with EACCES once we're no longer
# root -- taking down sway/wayvnc/novnc. Widen it while we're still root.
chmod 666 /proc/self/fd/1 /proc/self/fd/2

# Drop root -> zed for the whole supervisord tree in one step, via setpriv
# rather than supervisord's own per-program `user=`. That distinction
# matters for NVIDIA: `podman run --group-add keep-groups` preserves this
# process's real (host) supplementary groups, including "video" (needed to
# open /dev/dri/card1) -- but a *second* privilege drop done by supervisord
# internally resets supplementary groups based on the container's own
# /etc/group, silently losing that access again. --keep-groups here means
# "don't touch groups at all", so whatever was already in effect survives.
exec setpriv --reuid=zed --regid=zed --keep-groups \
    /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
