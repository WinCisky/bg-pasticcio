# bg-pasticcio — internals

Working notes for anyone (human or agent) changing this plugin. Install and
first-run instructions live in [README.md](README.md); everything below is how
it actually works and what must not be broken.

## Layout

| Path | What it is |
| --- | --- |
| `manifest.json` | Omarchy plugin manifest: id `ssimo.bg-pasticcio`, kinds `service` + `bar-widget`, entry points. |
| `Service.qml` | The `service`: headless singleton, owns the schedule, the config watch, and the `bgpasticcio` IPC target. |
| `BarPanel.qml` | The `bar-widget`: the icon by the clock and its popup. Stateless. |
| `bin/bg-pasticcio` | Bash worker. Does everything that can fail: network, disk, applying the wallpaper, writing config. |
| `config.env.example` | Reference copy of the config file. Editing it changes nothing. |

No build step, no runtime beyond bash and `omarchy-shell`.

## Architecture

**One worker, one owner of state.** A bar widget is instantiated once per
monitor, so `BarPanel.qml` keeps no state: it reaches the service with
`bar?.shell?.serviceFor("ssimo.bg-pasticcio")`, calls its functions and binds to
`service.workerStatus`. Every copy of the panel therefore agrees with every
other, and N monitors still means one worker process.

**The QML decides *when*, the bash does *what*.** Anything that can fail lives
in `bin/bg-pasticcio`. `Service.qml` only schedules it and reacts to the exit
code.

### Service.qml

- `FileView` on `config.env` with `watchChanges`, plus a 30 s re-read timer.
  The timer is not redundant: `watchChanges` misses a file replaced by rename
  (what `sed -i` and most editors do) and cannot watch a file that does not
  exist yet. Only two keys are parsed here — `BG_ENABLED` and
  `BG_INTERVAL_MINUTES`; the worker is the source of truth for the rest.
- `cycleTimer` — `running: root.rotationOn`, so an installed-but-untouched
  plugin has **no schedule at all**. Deliberately without `triggeredOnStart`:
  Qt honours that flag only on a Timer's very first start, so it cannot be
  relied on to fire every time the switch is flipped on.
- `onRotationOnChanged` is the one place the switch is acted on, and it calls
  `runNow()` — that is what makes turning it on (panel, `e`, IPC, or a hand
  edit of `config.env`) change the wallpaper immediately rather than at the
  next tick. If the worker is busy it retries in 5 s, because `runWorker`
  drops what it declines without a trace.
- `retryTimer` — cross-tick backoff after a non-zero exit: 1, 2, 4, 8 …
  minutes, capped at the interval. On top of the worker's own per-request
  backoff.
- Three separate `Process` objects on purpose: `worker` (images/wallpaper),
  `statusProc` (`status`), `configProc` (`set-config`). Editing a setting or
  refreshing the panel must not queue behind a download.
- Status polling runs at 5 s only while `uiWatchers > 0`; panels call
  `watch()`/`unwatch()` on open/close, so nothing polls when nobody is looking.
- `IpcHandler` target `bgpasticcio` exposes `next`, `rotate`, `like`,
  `dislike`, `enable`, `disable`, `restore`, `status`. Each returns
  `"running"` or `"busy"`.

### Trap: `next` means two different things

| Call | Effect |
| --- | --- |
| `omarchy-shell bgpasticcio next` | Service `runNow()` → worker **`run`** — fetch fresh from the network, restart the clock. |
| `bin/bg-pasticcio next` | Worker `cmd_next` — rotate to the next image in `liked/`, no network. |

In the worker, `next` and `rotate` are the same command. Over IPC they are not.

### BarPanel.qml

Left-click opens the panel, right-click fetches a fresh image, middle-click
steps through `liked/`. Keys inside the panel, via `PanelKeyCatcher` (suppressed
while a text field has focus): `e` toggle, `f` keep, `d`/`x` discard, `n` fresh
image.

| Control | Writes / calls |
| --- | --- |
| **Change my background** | `setEnabled()` → worker `enable`/`disable` (not `set-config`: only the worker takes the lock that makes restoring safe). |
| **Restore my wallpaper** | `restore`. Shown only while `canRestore`. |
| **Keep** / **Not this** / **Next** | `like` / `dislike` / `runNow`. |
| **Endpoint** | `set-config BG_ENDPOINT`. Enter saves, Escape reverts. |
| **Change every** | `set-config BG_INTERVAL_MINUTES`. |

Buttons grey out when the plugin is off, when the worker is busy, or when the
wallpaper on screen did not come from this plugin (`currentIsOurs`) — a theme
background or the setup notice is not something to rate.

## Worker command surface

`bin/bg-pasticcio <command>`; default is `run`.

| Command | Lock | Does |
| --- | --- | --- |
| `run` | yes | Fetch JSON, download, verify, apply. Falls back to a kept image on any failure. |
| `next` / `rotate` | yes | Next image in `liked/`. No network. No-op when `liked/` is empty. |
| `like` | yes | Move the current image into `liked/`, re-apply at the new path. The only way an image survives. |
| `dislike` | yes | Delete it, blocklist hash + source URL, fetch a replacement. |
| `enable` / `disable` | yes | Flip `BG_ENABLED`; `disable` also restores the original wallpaper. |
| `restore` | yes | Put the pre-first-change wallpaper back, leave the switch alone. |
| `set-config KEY VALUE` | **no** | Only writer of `config.env`. Never touches the images. |
| `status` | **no** | JSON: config, kept/blocked counts, current image, last result. |
| `interval` | **no** | Prints `BG_INTERVAL_MINUTES`. |

`status` and `set-config` skip `flock` so the panel stays responsive during a
download. Everything else serialises through `$STATE_DIR/lock`, so a timer tick
and a manual IPC call cannot race.

### Run path

`cmd_run` → `fetch_fresh_image` → `curl` the endpoint → `jq .url` →
`download_image` → `file` check on the bytes → store under a content hash in
`images/` → `write_meta` sidecar → `apply_background`. `main` then calls
`discard_unkept`, which deletes everything in `images/` that is not the file on
screen.

When the fetch fails — unreachable endpoint, or an endpoint that only offers
blocked images — `rotate_liked` shows the next image in `liked/` instead. With
`liked/` empty there is no fallback at all: the wallpaper is left alone, the run
is recorded as failed, and the service's backoff retries.

Applying always goes through `omarchy-theme-bg-set`, so Omarchy's
`~/.local/state/omarchy/current/background` symlink stays authoritative and the
change is instant.

Before the *first* background it ever applies, the worker records what was
already in place — both resolved file and raw symlink target — in
`original-background`.

## Config

`~/.config/bg-pasticcio/config.env`, written with defaults on first run.

| Key | Default | Meaning |
| --- | --- | --- |
| `BG_ENABLED` | `0` | Master switch. Every wallpaper-touching command refuses while `0`. |
| `BG_ENDPOINT` | `https://bg.ssimo.dev` | JSON endpoint. Empty = rotate `liked/` only. |
| `BG_INTERVAL_MINUTES` | `60` | Rotation period. |
| `BG_TIMEOUT_SECONDS` | `20` | Per-request timeout. |
| `BG_MAX_RETRIES` | `4` | Attempts per network call. |
| `BG_RETRY_BASE_SECONDS` | `2` | Backoff base: 2 s, 4 s, 8 s … |
| `BG_BLOCKED_RETRIES` | `3` | Re-asks when the endpoint keeps returning a blocked image. |

`BG_ENABLED` and `BG_INTERVAL_MINUTES` apply live (≤30 s, immediately when the
panel saves). The rest are read by the worker on its next run.

`BG_ENABLED=0` set by hand only stops rotation; it does **not** restore the
wallpaper. `disable` does both.

## On disk

| Path | Purpose |
| --- | --- |
| `~/.config/bg-pasticcio/config.env` | settings |
| `~/.local/share/bg-pasticcio/images/` | at most one file: the downloaded image on screen |
| `~/.local/share/bg-pasticcio/liked/` | kept images; the only durable collection, never deleted from |
| `~/.local/state/bg-pasticcio/original-background` | wallpaper from before the first change |
| `~/.local/state/bg-pasticcio/blocklist` | `<sha256>` + source URL per discarded image |
| `~/.local/state/bg-pasticcio/last` | tab-separated epoch, result, message — feeds `status` |
| `~/.local/state/bg-pasticcio/lock` | `flock` target |
| `~/.local/state/bg-pasticcio/setup-required.png` | generated "configure me" background |
| `~/.local/state/bg-pasticcio/bg-pasticcio.log` | one line per run; truncated to 200 lines past 256 KB |
| `<image>.meta` | JSON sidecar: the sanitized endpoint answer for that image |
| `<image>.src` | legacy sidecar, URL only; still read, upgraded to `.meta` when seen again |
| `~/.local/state/omarchy/current/background` | Omarchy's symlink to the active image |

Sidecars follow the image on `like` (`images/` → `liked/`).

## Endpoint contract

Only `url` is required:

```json
{
  "url": "https://example.org/photo.jpg",
  "title": "California's Central Valley",
  "creator": "Mark Miller",
  "license": "cc0",
  "licenseUrl": "https://creativecommons.org/publicdomain/zero/1.0/deed.en",
  "source": "wikimedia",
  "sourceUrl": "https://commons.wikimedia.org/w/index.php?curid=2374537"
}
```

`sanitize_meta` treats the answer as a stranger's text that ends up on a
desktop and in a shell command line:

- unknown keys dropped, every string capped at 200 characters;
- `licenseUrl` / `sourceUrl` accepted only as `http(s)` URLs built from a
  character set that cannot break out of a single-quoted shell word — the
  apostrophe is deliberately excluded, which is what makes opening one in a
  browser safe;
- anything failing a check is dropped, and the panel simply omits it;
- text fields render as plain text, never markup.

Downloads: `curl` pinned to `http`/`https` (so an endpoint cannot bounce the
fetch into `file://`), stopped at 64 MB, and URLs are stripped out of logged
network errors because an endpoint URL can carry a token. Downloaded bytes are
verified with `file` — an HTML error page served with a `200` never becomes a
wallpaper.

Where the fetch may point is checked too, because the feed picks the image URL:
`url_is_public` resolves the host and refuses loopback, link-local, private,
CGNAT and multicast addresses, so a feed cannot have this machine fetch from a
service only this machine can reach. `-L` is not used — it would connect to
whatever the previous hop named before that check could run — so
`curl_with_backoff` walks redirects itself (at most `MAX_REDIRECTS`) and vets
every hop. Only `BG_ENDPOINT` itself is exempt on its first hop, since the user
configured it and a local feed of their own is legitimate; nothing it points at
afterwards is.

## Invariants — do not break these

1. **Nothing happens until `BG_ENABLED` is on.** No request, no schedule, no
   wallpaper change on install. `require_enabled` guards every mutating
   command; `cycleTimer` does not run.
2. **The original wallpaper is recorded before the first apply** and restorable
   for as long as the file exists.
3. **The worker is the only writer of `config.env`** — nothing else needs to
   know how to quote a shell value safely.
4. **No `set -e` in the worker.** Deliberate: every failure is handled and
   downgraded to offline rotation. A wallpaper that stops changing is the bug
   being avoided.
5. **The panel stores no state.** Anything remembered belongs in the service or
   in `status`.
6. **Only image/wallpaper commands take the lock.** `status` and `set-config`
   must stay lock-free.
7. **`status` is the single read model** for the UI: add a field there rather
   than shelling out from QML.
8. **At most one downloaded image exists at a time.** `images/` holds the file
   on screen and nothing else; `discard_unkept` in `main` enforces it after
   every locked command. `liked/` is the only durable collection, and nothing
   in the worker deletes from it except an explicit `dislike`.

## Debugging

```sh
tail -f ~/.local/state/bg-pasticcio/bg-pasticcio.log
bin/bg-pasticcio status | jq .
bin/bg-pasticcio run          # logs to stderr too when attached to a tty
omarchy-restart-shell         # after ANY QML edit
```

The shell caches compiled QML per file URL, so `rescanPlugins` can hand back
the previous version — restart the shell while developing.

Common failures, all visible in the log:

| Message | Meaning |
| --- | --- |
| `missing required command(s)` | Install what it names; checked once per run rather than failing mid-pipeline. |
| `endpoint response has no usable .url field` | Endpoint must return a top-level `url`. Check with `curl -s "$BG_ENDPOINT" \| jq .`. |
| `downloaded content is not a supported image` | Not JPEG/PNG/WebP/GIF/BMP — usually an error page or a login redirect. |
| `another run is in progress, skipping` | `flock` did its job. Not an error. |
| Black "configure an endpoint" background | `BG_ENDPOINT` blank and `liked/` empty. Rendered with ImageMagick at the largest monitor's size (`hyprctl`), in `fc-match sans-serif`. Without `magick` the worker logs and leaves the background alone. |
| Buttons greyed out | Plugin off, worker busy, or the wallpaper did not come from this plugin. |
| Background never changes offline | Nothing kept yet — offline rotation only has `liked/` to work with. |

## Uninstall notes

`disable` (or the toggle) first, then `omarchy plugin remove
ssimo.bg-pasticcio`. Kept images, config and log are left on purpose;
`rm -rf ~/.config/bg-pasticcio ~/.local/share/bg-pasticcio
~/.local/state/bg-pasticcio` clears them. If the active wallpaper still came
from this plugin, pick another background first (`omarchy theme bg next`) or the
desktop is left pointing at a file that no longer exists.
