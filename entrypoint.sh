#!/usr/bin/env bash
set -euo pipefail

mkdir -p "$XDG_RUNTIME_DIR" /workspace /home/zed/.config/zed /home/zed/.local/share/zed
chown zed:zed "$XDG_RUNTIME_DIR" /workspace
chmod 700 "$XDG_RUNTIME_DIR"

# The zed-config/zed-data named volumes mount over .config/zed and
# .local/share/zed. Docker creates a new named volume's initial contents
# root:root when there's nothing in the image at that exact path to copy
# ownership from (there isn't, until Zed itself runs once), which shadows
# the build-time `chown -R zed:zed /home/zed/.config` and leaves Zed unable
# to write there.
chown -R zed:zed /home/zed/.config/zed /home/zed/.local/share/zed

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
