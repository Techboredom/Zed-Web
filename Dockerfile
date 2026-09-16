FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/zed \
    SHELL=/bin/bash \
    XDG_RUNTIME_DIR=/run/user/1000 \
    WLR_BACKENDS=headless \
    WAYLAND_DISPLAY=wayland-1 \
    VNC_PORT=5900 \
    NOVNC_PORT=6080

RUN apt-get update && apt-get install -y --no-install-recommends \
        # core
        ca-certificates curl wget gnupg xz-utils tini git \
        # headless Wayland compositor (real GPU rendering) + VNC server + browser bridge
        sway wayvnc xwayland novnc websockify supervisor \
        # Mesa userspace: the real Intel/AMD hardware Vulkan (anv/radv) and
        # OpenGL (iris/radeonsi) drivers used against the passed-through
        # /dev/dri device, plus vulkan-tools for diagnostics (vulkaninfo).
        mesa-vulkan-drivers libvulkan1 vulkan-tools libgl1 libegl1 libglx-mesa0 \
        # libs Zed's GUI toolkit links against
        libxkbcommon0 libxkbcommon-x11-0 libdbus-1-3 libasound2t64 \
        # fonts so the editor doesn't render blank glyphs
        fonts-liberation fonts-noto-color-emoji fontconfig \
        # native toolchain (gcc/g++/make + headers many language servers and
        # crates/native-modules need to build things)
        build-essential pkg-config libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Headless Chrome, via Google's own apt repo. Ubuntu's "chromium-browser" is
# just a snap stub and doesn't work in a container, so this can't use apt's
# default sources.
RUN wget -q -O - https://dl.google.com/linux/linux_signing_key.pub \
        | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
        > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update && apt-get install -y --no-install-recommends google-chrome-stable \
    && rm -rf /var/lib/apt/lists/*

# Go: fetch whatever the latest stable release is at build time.
RUN GO_VERSION="$(curl -fsSL https://go.dev/VERSION?m=text | head -n1)" \
    && curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz \
    && tar -C /usr/local -xzf /tmp/go.tgz \
    && rm /tmp/go.tgz

# Node.js + npm: fetch whatever the latest release is at build time, straight
# from nodejs.org (not apt) so it isn't tied to Ubuntu's often-stale package,
# and so it isn't at the mercy of whatever version novnc happens to pull in
# as a transitive dependency. Extracting into /usr/local puts it ahead of
# apt's nodejs (/usr/bin) on PATH, so this version wins.
RUN NODE_VERSION="$(curl -fsSL https://nodejs.org/dist/index.json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["version"])')" \
    && curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-x64.tar.xz" -o /tmp/node.tar.xz \
    && tar -C /usr/local --strip-components=1 -xJf /tmp/node.tar.xz \
    && rm /tmp/node.tar.xz

# asdf (CLI version manager, asdf-vm.com): fetch latest release. Not an apt
# package on Ubuntu - "asdftool" there is an unrelated scientific-data-format
# tool (from python-asdf), not this. Modern asdf (0.16+) ships as a single
# Go binary, no more git-clone-and-source-a-shell-script install.
RUN ASDF_VERSION="$(curl -fsSL https://api.github.com/repos/asdf-vm/asdf/releases/latest | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')" \
    && curl -fsSL "https://github.com/asdf-vm/asdf/releases/download/${ASDF_VERSION}/asdf-${ASDF_VERSION}-linux-amd64.tar.gz" -o /tmp/asdf.tar.gz \
    && tar -C /usr/local/bin -xzf /tmp/asdf.tar.gz \
    && rm /tmp/asdf.tar.gz

# Zed refuses to run as root, so everything below runs as this user.
# Ubuntu's base image ships a default "ubuntu" user at uid 1000; drop it so
# we can reuse 1000, which lines up with the default host user's uid for
# bind-mount permissions on /workspace.
RUN userdel -r ubuntu 2>/dev/null; \
    useradd -m -u 1000 -d /home/zed -s /bin/bash zed

# Zed, Rust (rustup) and uv, installed as the zed user so everything lands
# in its $HOME with correct ownership instead of under root's.
USER zed
RUN curl -f https://zed.dev/install.sh | sh
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --profile default
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
USER root

RUN ln -s /home/zed/.local/bin/zed /usr/local/bin/zed \
    && mkdir -p /home/zed/.npm-global \
    && chown -R zed:zed /home/zed

# So `npm install -g ...` as the zed user writes to its own home instead of
# needing root access to /usr/local. The .asdf/shims entry is where asdf
# exposes whatever tool versions get installed via `asdf install ...`.
ENV NPM_CONFIG_PREFIX=/home/zed/.npm-global \
    PATH="/home/zed/.local/bin:/home/zed/.cargo/bin:/usr/local/go/bin:/home/zed/.npm-global/bin:/home/zed/.asdf/shims:${PATH}"

# Serve the noVNC client at the web root, auto-connecting straight into a
# session that resizes the real desktop resolution to match the browser
# window (stock noVNC otherwise lands on a manual connect screen with a
# fixed-size, non-resizing canvas). See novnc-index.html for the CSS-scaling
# fallback mode.
COPY novnc-index.html /usr/share/novnc/index.html

# Soften the streamed view with rounded corners + a shadow around the
# canvas - see zed-corners.css. This is a browser-side effect on noVNC's
# vnc.html (a vendor file we don't otherwise touch), so it's linked in with
# a one-line sed rather than owning a whole duplicate copy of that file.
COPY zed-corners.css /usr/share/novnc/zed-corners.css
RUN sed -i 's#</head>#<link rel="stylesheet" href="zed-corners.css">\n</head>#' \
    /usr/share/novnc/vnc.html

WORKDIR /workspace
RUN chown zed:zed /workspace

# Default Zed to a dark theme - there's no real "system" light/dark signal
# in a headless container for Zed's "system" mode to follow, so it'd
# otherwise land on whatever Zed's own hardcoded fallback is. Lands in the
# zed-config named volume's initial content on first creation (see
# entrypoint.sh for the matching runtime chown, needed because Docker
# creates that volume root-owned otherwise); edit settings.json normally
# after that to change it, this only sets the starting point.
COPY zed-settings.json /home/zed/.config/zed/settings.json
RUN chown -R zed:zed /home/zed/.config/zed

# sway launches Zed itself once the compositor is up (see sway-config); this
# keeps them on the same Wayland socket without extra process choreography.
COPY sway-config /home/zed/.config/sway/config
RUN chown -R zed:zed /home/zed/.config

COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 6080 = browser (noVNC/websockify), the only port meant to be published.
# wayvnc itself is loopback-only (see supervisord.conf) since its own auth
# is incompatible with noVNC; don't publish 5900 without an SSH/VPN tunnel.
EXPOSE 6080

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/entrypoint.sh"]
