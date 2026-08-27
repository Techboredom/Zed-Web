# Zed in a browser

Runs the real Zed editor inside a container, composited by a headless Wayland
compositor (`sway`) rendering through your actual Intel iGPU via `/dev/dri`,
captured by `wayvnc`, and streamed to any web browser through `websockify` +
`noVNC`. Verified working end-to-end, including real GPU-accelerated
rendering (Zed does not show its "Unsupported GPU / software rendering"
warning with this setup).

## Build & run

```sh
docker compose up --build
```

Then open `http://localhost:6080` and log in with the browser's basic-auth
prompt using `VNC_USERNAME` / `VNC_PASSWORD` from `docker-compose.yml`.

Without compose:

```sh
docker build -t zed-web .
docker run -it --rm \
  --device /dev/dri/card2:/dev/dri/card2 \
  --device /dev/dri/renderD129:/dev/dri/renderD129 \
  -p 6080:6080 \
  -e VNC_PASSWORD=changeme \
  -v "$PWD/workspace:/workspace" \
  zed-web
```

## GPU

Zed requires a working Vulkan device and refuses to run well without one.
This image is built for an Intel (or AMD) GPU passed through as specific
`/dev/dri` nodes:

- **Pass through only your Intel node, not the whole `/dev/dri` directory.**
  On a multi-GPU host, passing the whole directory would also hand the
  container your NVIDIA/other GPU. Find the right nodes with:
  ```sh
  lspci -nnk | grep -A2 -i vga      # identify the Intel PCI address, e.g. 00:02.0
  ls -l /dev/dri/by-path/           # map it to a cardN / renderDNNN pair
  ```
  Update the `devices:` list in `docker-compose.yml` accordingly.
- `sway` is started with `--unsupported-gpu`. This is necessary because
  `/proc/modules` isn't namespaced by containers — on a host with an NVIDIA
  driver loaded, sway sees that module and refuses to start even though the
  container itself only has the Intel node. Safe here specifically because
  the compose file restricts passthrough to the Intel device.
- Xvfb (the obvious first approach) does **not** work for this: it lacks the
  DRI3 extension a Vulkan app needs to present frames to a window, so Zed
  silently falls back to software rendering (llvmpipe) even with a GPU
  device passed through. That's why this image uses a Wayland compositor
  instead of X11.

## Security

The only port meant to be published is `6080` (browser/noVNC), protected by
HTTP Basic Auth via `VNC_PASSWORD`/`VNC_USERNAME` — always set a real
password. `wayvnc` itself is bound to loopback inside the container and is
*not* exposed: its own built-in authentication uses a VNC security type
noVNC can't speak, so auth is enforced one layer up instead. Don't rebind
wayvnc to `0.0.0.0` or publish port 5900 without adding equivalent
protection (SSH tunnel, VPN, reverse proxy). Treat port 6080 as sensitive
even with auth — put TLS in front of it (Caddy/nginx) if exposing beyond
localhost.

## Dev tooling

Also included in the image, all on `PATH` for the `zed` user (and reachable
from Zed's integrated terminal): `git`, `gcc`/`g++`/`make` (`build-essential`,
plus `pkg-config`/`libssl-dev` for crates like `openssl-sys`), `go` (latest
stable, fetched at build time), `rustc`/`cargo` (via `rustup`, stable
channel), `node`/`npm` (latest, fetched at build time — not Ubuntu's stale
apt package, and not the older Node that `novnc` happens to pull in as a
transitive dependency), `uv`/`uvx`, and `google-chrome` for headless browser
work.

`npm install -g <pkg>` works without sudo/permission errors as the `zed`
user — its global prefix is set to `~/.npm-global`, which that user owns.
Nothing browser-automation-specific (Puppeteer, Playwright, etc.) is
preinstalled; add whichever fits a given project or agent as needed
(`npm install -g playwright && playwright install --with-deps chromium`, or
point Puppeteer/Playwright at the already-installed system Chrome via
`executablePath`/`channel` instead of letting them download their own).

Headless Chrome needs `--no-sandbox` in this container — its own sandboxing
needs privileges containers don't grant by default, regardless of which user
runs it (confirmed: it crashes on startup for both root and the `zed` user
without the flag). This is standard for Chrome-in-Docker generally (same
advice Puppeteer/Playwright/Selenium docs give), not specific to this image:

```sh
google-chrome --headless --disable-gpu --no-sandbox --dump-dom https://example.com
```

If you're driving Chrome from Puppeteer/Playwright/Selenium, pass the
equivalent launch arg (e.g. Puppeteer's `args: ['--no-sandbox']`).

## Persistence

- `./workspace` — your project files, bind-mounted.
- `zed-config` / `zed-data` named volumes — Zed's settings and extensions
  survive container rebuilds.

## First run in the browser

- Zed opens `/workspace` in **Restricted Mode** (it doesn't recognize the
  folder as a trusted project yet) — click "Trust and Continue" once you've
  reviewed what's in there.
- A "Failed to Update" banner is expected — Zed's auto-updater can't replace
  its own binary inside a container; ignore it or disable auto-update in
  settings.

## Troubleshooting

- Blank browser screen: check `docker compose logs`. It's normal to see
  `wayvnc` fail once and restart on first boot — it starts slightly before
  sway's Wayland socket exists and supervisor's autorestart recovers it
  within a couple seconds.
- `Failed to connect to WAYLAND_DISPLAY`: sway isn't up yet or crashed;
  check the `sway` program's log.
- No GPU / `NoSupportedDeviceFound` or the "software emulated GPU" warning
  visible in a screenshot: confirm the two `--device` entries actually match
  your Intel node's `cardN`/`renderDNNN` (see GPU section above).
- Missing `.so` errors on Zed startup: run
  `docker compose exec zed ldd /home/zed/.local/bin/zed | grep "not found"`
  and add the missing package to the Dockerfile's apt-get list.
