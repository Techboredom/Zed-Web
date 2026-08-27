# Zed in a browser

Runs the real Zed editor inside a container, composited by a headless Wayland
compositor (`sway`) rendering through your actual Intel iGPU via `/dev/dri`,
captured by `wayvnc`, and streamed to any web browser through `websockify` +
`noVNC`. Verified working end-to-end, including real GPU-accelerated
rendering (Zed does not show its "Unsupported GPU / software rendering"
warning with this setup). Linux container hosts only for now — see
[Host platform support](#host-platform-support) for macOS/Windows notes.

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

### NVIDIA

NVIDIA works differently enough from Intel/AMD that it gets its own section.
It needs the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/index.html)
installed on the host (this is separate from, and in addition to, the normal
NVIDIA driver).

**Docker, or `sudo podman` (rootful) — should work, standard setup:**

```sh
# generate the CDI spec once (or use --gpus all if you're on Docker with the
# legacy nvidia-container-runtime instead of CDI):
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

docker run ... --device nvidia.com/gpu=all zed-web    # or: --gpus all
# / sudo podman run ... --device nvidia.com/gpu=all zed-web
```

This is the standard, documented way NVIDIA's own toolkit expects to be
used, and Docker's daemon runs as real root by default — so it isn't
independently re-verified end-to-end in this repo the way the Intel path
was, but there's no known reason it wouldn't work.

**Rootless Podman (Podman's default, no `sudo`) — confirmed does not work:**

Rendering hits a hard wall: `sway` fails with
`gbm_bo_create failed: Permission denied` /
`DRM_IOCTL_MODE_CREATE_DUMB failed: Permission denied`, even after correctly
passing through only the NVIDIA device
(`--device nvidia.com/gpu=all`) and preserving the invoking user's `video`
group membership (`podman run --group-add keep-groups`, needed because
rootless Podman otherwise drops supplementary groups on container devices —
this part *is* necessary and does fix plain device-open access, confirmed
with `vulkaninfo` and a raw `open()` both succeeding). The remaining failure
is one level deeper: `sway`'s buffer allocator needs actual DRM-master
status on the primary node to do KMS buffer allocation, which is a kernel
capability (effectively `CAP_SYS_ADMIN` against that device), not a
DAC/group-permission check — and rootless containers structurally can't
obtain that against real host hardware no matter what user or groups the
process has. Confirmed this isn't a startup-timing fluke by restarting
`sway` mid-session with the identical result. Intel/AMD never hits this
because Mesa's open-source drivers can do headless GPU allocation entirely
through the render node, which rootless containers *can* access; NVIDIA's
driver needs the primary node too.

If you're on rootless Podman and want NVIDIA, use `sudo podman` for this
container specifically rather than chasing further permission fixes.

## Host platform support

**Linux only, for now.** This image is built and tested against Linux
container hosts (Intel/AMD verified end-to-end; NVIDIA per the section
above). macOS and Windows were investigated but aren't supported — notes
below in case that changes later.

### macOS

Not supported, and architecturally a bigger gap than a config tweak would
fix: Docker/Podman containers on macOS always run inside a Linux VM (no
shared kernel with the host the way Linux-on-Linux works), so there's no
`/dev/dri` on the Mac side to pass through in the first place. Three paths
were checked:

- **Apple's own `container` CLI**: explicitly not supported — confirmed
  directly by the maintainer. Apple Silicon GPUs lack the IOMMU support the
  hypervisor needs for secure passthrough; this is a hardware/architecture
  limitation, not a missing feature that's coming later.
- **Docker Desktop**: no general GPU device passthrough. It has a narrow
  "Model Runner" feature for LLM inference specifically, not applicable to a
  general rendering workload like this one.
- **Podman with the `krunkit` machine backend** (not the default
  `applehv`): the one real lead. It exposes a paravirtualized
  `/dev/dri/renderD128`-style device inside the Linux VM via the Venus
  protocol (Vulkan-over-virtio-gpu, translated to Metal via MoltenVK on the
  real Mac GPU). Sources disagree on scope — one described it as
  compute-only (fine for LLM inference, not for us); better/newer sources
  say Venus has supported the same extensions DXVK/Zink need for actual
  draw-call rendering since 2023. Nothing found confirms or denies that a
  headless Wayland compositor specifically (what `sway` needs here) has
  been proven to work over it. Untested — would need a non-default Podman
  config plus likely Dockerfile changes (Venus-specific Mesa Vulkan ICD).

### Windows / WSL2

Not supported yet. Some of the underlying mechanism has real prior art;
the specific combination this project needs doesn't:

- WSL2's primary GPU path isn't the standard Linux DRM `/dev/dri` model —
  it exposes `/dev/dxg` (Microsoft's `dxgkrnl` driver), bridging to the
  Windows-side GPU driver over D3D12/WDDM. Mesa has a driver built for this
  specifically (`dzn`, aka "dozen") that translates Vulkan through
  `/dev/dxg` instead of talking to a real DRM device.
- This image currently installs Mesa's native hardware ICDs (`anv`/`radv`)
  and expects `/dev/dri/*` — the wrong driver and device for WSL2.
  Reportedly installing native Linux GPU drivers inside WSL2 can actively
  break passthrough rather than just fail to help. WSL2 instead needs the
  `dzn` ICD plus `libd3d12`/`libdxcore`, and `/dev/dxg` passed through
  instead of `/dev/dri/*` — a real branch in the Dockerfile, not a flag
  change.
- What's actually verified elsewhere: [MatLN8/wsl-gpu-graphics-container](https://github.com/MatLN8/wsl-gpu-graphics-container)
  demonstrates the `/dev/dxg` + Mesa D3D12 mechanism genuinely working
  inside a container — real evidence the passthrough mechanism itself
  works. But it's **OpenGL, not Vulkan** (Zed needs Vulkan), it's a
  single-commit proof-of-concept with no ongoing maintenance, and its own
  docs assume an NVIDIA host — Intel/AMD isn't confirmed there either.
- [jordankoehn/sway-wsl2](https://github.com/jordankoehn/sway-wsl2) runs
  `sway` under WSL2 and is actively maintained, but don't read too much
  into it: it doesn't claim or demonstrate GPU-accelerated rendering at
  all, it's `sway` as a desktop compositor riding WSLg's own graphics
  pipeline — not evidence for headless, GPU-accelerated `sway` the way this
  project would need.
- Net: the `/dev/dxg` passthrough mechanism has proof it can work at all
  (for OpenGL); nothing found confirms or denies the actual combination
  this project needs (headless `sway`, Vulkan via `dzn`). Rough edge on
  top: recent reports of `dzn` driver files going missing / Vulkan failing
  to detect the GPU on current Ubuntu-in-WSL2 setups, even for NVIDIA (the
  best-supported vendor everywhere else).

If either of these becomes worth pursuing, the right next step is testing
against real hardware (a borrowed Mac / a Windows box) rather than writing
more directions from research alone — happy to pick this back up then.

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
