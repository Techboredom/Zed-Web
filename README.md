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
prompt using `VNC_USERNAME` / `VNC_PASSWORD` from `docker-compose.yml`. It
auto-connects and resizes the real desktop resolution to match your browser
window (`resize=remote`), so it fills the window edge-to-edge with no
letterboxing, live as you resize it. For the plain connect screen (e.g. to
try `resize=scale`, a CSS-scaling fallback that letterboxes on non-16:9
windows but doesn't depend on server-side resize support — see
`novnc-index.html` for details), open `vnc.html` directly with no query
string. The view itself has rounded corners and a drop shadow
(`zed-corners.css`) instead of butting flush against the browser edges —
purely a browser-side CSS effect on noVNC's canvas, not a real compositor
window shape (a real one would mean building `swayfx`, a `sway` fork, from
source — passed on that given the build fragility for a cosmetic change;
see git history if that tradeoff ever looks worth revisiting).

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

### Software rendering (no GPU device at all)

Works, no Dockerfile changes needed, verified end-to-end including through
the browser: run the container with **no `--device` flags at all**. `sway`
detects there's no DRM device, falls back to its software compositor
automatically, and Zed renders through Mesa's `lavapipe` (a software Vulkan
implementation that's already bundled in the image, no extra setup). Zed
will show its own "Unsupported GPU" dialog on first launch — click "Skip",
or set `ZED_ALLOW_EMULATED_GPU=1` in the container's environment to suppress
it permanently.

The real tradeoff is exactly what Zed's own dialog says: "awful
performance" — this is CPU-bound rendering, noticeably slower for anything
graphically heavy, but genuinely usable for editing text. Since it needs
no GPU passthrough of any kind, **this is the practical fallback for
platforms in the next section** (macOS, Windows/WSL2) where real GPU
passthrough isn't set up or supported — same image, same compose file,
just drop the `devices:` block.

## Host platform support

**Linux only for real GPU acceleration; software rendering (above) works
anywhere.** This image is built and tested against Linux container hosts
for the GPU-accelerated path (Intel/AMD verified end-to-end; NVIDIA per the
section above). macOS and Windows were investigated for GPU passthrough
specifically and aren't supported there yet — notes below in case that
changes later. Software rendering doesn't care what host platform this
runs on; if you're on macOS or Windows and just want it working today,
skip the `devices:` block and use that instead of chasing platform-specific
GPU setup.

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

Not supported yet. Some of the underlying mechanism has real potential;
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
transitive dependency), `uv`/`uvx`, [`asdf`](https://asdf-vm.com/) (latest,
fetched at build time — not an apt package on Ubuntu; watch out, there's an
unrelated `asdftool` in Ubuntu's repos for scientific data files, not this),
`google-chrome` for headless browser work, and two terminal coding
agents — [`claude`](https://www.npmjs.com/package/@anthropic-ai/claude-code)
(Claude Code) and [`pi`](https://github.com/earendil-works/pi)
(`@earendil-works/pi-coding-agent` — not `@mariozechner/pi-coding-agent`,
which is the same tool under its old, now-deprecated npm scope; checked
directly against the registry since search results mostly still point at
the old one). Neither ships with credentials — set `ANTHROPIC_API_KEY` (or
run their own `/login`) at runtime. These aren't part of the Zed GUI
workflow; they're here because this image doubles as a plain dev shell —
`docker exec -it <container> bash` and use them directly, independent of
whatever's happening in the browser.

No `asdf` plugins/language versions are preinstalled — `asdf plugin add
<name> && asdf install <name> latest && asdf set -u <name> latest` per
project as needed; verified end-to-end (plugin add, install, and shim
resolution on `PATH` all work) with the `jq` plugin.

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
  survive container rebuilds. `zed-settings.json` (defaults to `"theme":
  "One Dark"` — there's no real "system" light/dark signal in a headless
  container for Zed's own system-follow mode to key off, so this just picks
  a fixed one) seeds `zed-config`'s `settings.json` the first time that
  volume is created; edit it normally through Zed after that, same as any
  other setting — this only sets the starting point, not a permanent
  override.
- Prefer one volume for the *whole* of `/home/zed` instead (matching
  `k8s/deployment.yaml`'s approach), so `rustup`/`uv`/the npm-global tool
  installs persist too, not just Zed's own settings/extensions? See the
  commented alternative in `docker-compose.yml`. Works with a named volume
  (auto-populated from the image the first time it's created — same as
  `zed-config`/`zed-data` above) or a bind mount to a real host folder
  instead — that starts empty, but `entrypoint.sh` detects that and
  restores `zed`/`rustup`/`uv`/npm-global tools from what's baked into the
  image (the same mechanism Kubernetes' PVC needs and this doesn't
  strictly; see the Kubernetes section below for why). Pair with
  `ZED_WORKSPACE_DIR=/home/zed/workspace` if you'd rather project files
  live inside that single volume too, instead of their own separate mount.

## Kubernetes

`k8s/deployment.yaml` has PVCs + a Deployment + a Service in place of
`docker-compose.yml`'s volumes/container/ports, pointing at
`ctr.int.techboredom.com:8443/coding_tools/zed:latest`. That image is built
and pushed by `.forgejo/workflows/build.yml` on every push to `main` (every
other branch just builds, to prove the Dockerfile still works, without
touching the registry) — needs `REGISTRY_USERNAME`/`REGISTRY_PASSWORD` set
under this repo's Settings → Actions → Secrets first; nothing's committed
anywhere. Copy `k8s/secret.example.yaml` to `k8s/secret.yaml` (gitignored)
and fill in a real VNC password, then:

```sh
kubectl apply -f k8s/secret.yaml -f k8s/deployment.yaml
kubectl port-forward svc/zed-web 6080:6080   # or your own Ingress/LoadBalancer
```

**The one big PVC deserves an explanation, since it's not just "bigger
volumes":** the manifest uses a single 100Gi `zed-home` PVC for the whole
of `/home/zed`, replacing compose's two narrower volumes
(`zed-config`/`zed-data`) — and that distinction actually matters, not just
stylistically. Docker's local named volumes auto-populate from whatever the
image already has at that exact path the first time they're created, which
is why the narrow compose volumes never caused problems. **Kubernetes PVCs
don't do that at all** — they mount in empty and completely shadow
whatever's baked into the image. Mount an empty PVC over the whole of
`/home/zed` without accounting for that, and Zed itself
(`~/.local/zed.app`), `rustup`, `uv`, and the npm-global installs (Claude
Code, Pi) all silently vanish. Worse: so does `~/.config/sway/config` — the
one line that launches Zed at all — so the container comes up looking
completely healthy (every `supervisord` program `RUNNING`) while showing a
blank screen forever, with nothing pointing at why.

`entrypoint.sh` handles this: the image bakes a golden copy of the fully
set-up `/home/zed` to `/opt/zed-home-seed` (a path no volume ever touches),
and restores from it on first boot only, detected via a `.provisioned`
marker file that's itself part of that backup. This is a no-op for the
compose deployment — that marker's already present there from the image
directly, since compose never empties `/home/zed` in the first place.
Verified end-to-end here: a fresh/empty volume mounted straight over
`/home/zed` correctly triggers the restore, Zed launches successfully
afterward, and a second boot on that same (now-populated) volume correctly
skips it.

There's no separate PVC for `/workspace` either — `ZED_WORKSPACE_DIR` in the
manifest points Zed at `/home/zed/workspace` (a directory inside the one
`zed-home` volume) instead of the default top-level `/workspace` path, so
project files live there without needing a volume of their own or a second
mount of the same one. `sway-config`'s launch line and `entrypoint.sh` both
read this var — it's what actually decides where Zed opens (defaulting to
`/workspace`, Docker Compose's own bind mount, when unset), independent of
however `/home/zed` itself happens to be mounted. Verified: with only the
single `/home/zed` mount and `ZED_WORKSPACE_DIR` set, Zed correctly opens
`/home/zed/workspace` and everything else works exactly as with the default
path.

Set `UPDATE_ON_START=true` (commented out in the manifest by default) to
also re-fetch latest `zed`/`rustup`/`uv`/the npm-global tools on every pod
start, not just restore what was baked in — verified working end-to-end too
(re-downloads Zed, runs `rustup update`, `uv self update`, and
`npm install -g ...@latest` for Claude Code/Pi). Off by default on purpose:
it needs network access and adds real time to *every* restart, not just the
first. It only covers what actually lives under `/home/zed` — Go, Node,
`asdf`'s own binary, Chrome, `sway` etc. are all system packages baked into
the image itself; refresh those by rebuilding the image, not from here.

GPU passthrough in Kubernetes doesn't have a direct equivalent of Docker's
`--device` flag for a generic Intel/AMD render node — see the commented
options in `deployment.yaml` (`hostPath` + pinning the pod to a specific
node, or the standard NVIDIA device-plugin resource request if your cluster
has that installed). The manifest defaults to no GPU at all and falls back
to software rendering instead, since that needs no device access, works on
any node, and is already verified working (see the GPU section above).

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
