#!/usr/bin/env bash
set -euo pipefail

mkdir -p "$XDG_RUNTIME_DIR" /workspace
chown zed:zed "$XDG_RUNTIME_DIR" /workspace
chmod 700 "$XDG_RUNTIME_DIR"

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
