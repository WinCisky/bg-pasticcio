# bg-pasticcio

An Omarchy 4 ("Quattro") shell plugin that changes the desktop background on a
timer, pulling fresh images from an HTTP endpoint you configure and keeping the
last few locally so rotation keeps working with no internet.

- **Off until you switch it on.** Installing and enabling the plugin changes
  nothing; the panel's "Change my background" toggle is what lets it touch your
  wallpaper. After that it changes immediately, then every `N` minutes.
- **Your wallpaper is remembered.** The background in use before its first
  change is recorded, and put back when you switch the toggle off — or on
  demand, before uninstalling.
- Works with no configuration: it ships pointing at `https://bg.ssimo.dev`,
  a CC0 wallpaper feed. Point it anywhere else from the panel.
- An endpoint returns JSON like `{"url": "https://.../image.jpg"}`, optionally
  with a title, who made it, and its licence — all shown in the panel.
- An icon next to the clock opens a panel: what the service is doing, the
  endpoint, and **Keep** / **Not this** for the image on screen.
- Kept images are safe from pruning forever. Discarded ones are deleted, never
  shown again, and replaced on the spot.
- Downloaded images are cached; if the endpoint or the network fails, the
  plugin rotates the cache instead of leaving the wallpaper stuck.
- Retries with exponential backoff on failed requests.
- With no endpoint configured and nothing cached yet — and only once you have
  switched it on — it draws the setup instructions onto the background itself
  instead of doing nothing visible.
- Configuration beyond that first toggle is optional.

## Install

```sh
omarchy plugin add https://github.com/WinCisky/bg-pasticcio.git --enable --yes
omarchy bar put ssimo.bg-pasticcio --after omarchy.clock
```

From a local checkout (`omarchy plugin add` clones, and a filesystem path is a
valid git URL):

```sh
git init && git add -A && git commit -m "init"
omarchy plugin add "$PWD" --enable --yes
omarchy bar put ssimo.bg-pasticcio --after omarchy.clock
```

Or fully manually:

```sh
cp -r . ~/.config/omarchy/plugins/ssimo.bg-pasticcio
omarchy-shell shell rescanPlugins
omarchy plugin enable ssimo.bg-pasticcio --after omarchy.clock
```

Nothing has changed yet — that is deliberate. Click the icon by the clock and
turn on **Change my background**; the wallpaper changes within a second or two,
using the default feed. The equivalent from a terminal:

```sh
omarchy-shell bgpasticcio enable
```

To use your own feed, paste the URL into the endpoint field in the panel and
press Enter.

### Upgrading from 1.0.x

1.0 was a headless service, so it is recorded in `plugins[]` in `shell.json`
rather than in the bar layout, and enabling it again is a no-op. Move it across
once:

```sh
omarchy plugin disable ssimo.bg-pasticcio
omarchy plugin enable ssimo.bg-pasticcio --after omarchy.clock
```

### Upgrading from `omarchy-bkg-changer`

The plugin was renamed, and with it the plugin id, the worker, the IPC target
and every directory it owns. Nothing migrates automatically. Remove the old
plugin first, since the two ids install side by side:

```sh
omarchy plugin remove ssimo.bkg-changer
```

Then, to keep your liked images, blocklist and settings, move them across
before installing the new one:

```sh
mv ~/.config/omarchy-bkg-changer       ~/.config/bg-pasticcio
mv ~/.local/share/omarchy-bkg-changer  ~/.local/share/bg-pasticcio
mv ~/.local/state/omarchy-bkg-changer  ~/.local/state/bg-pasticcio
mv ~/.local/state/bg-pasticcio/bkg-changer.log \
   ~/.local/state/bg-pasticcio/bg-pasticcio.log
```

Skipping this loses nothing — the old directories stay where they are — but
the plugin starts from an empty pool with default settings.

The `bkg-changer-off` / `bg-pasticcio-off` pause flag is gone: the panel's
**Change my background** toggle replaces it, and it starts off.

## The panel

Left-click the icon to open the panel, right-click to fetch a new image, and
middle-click to rotate to the next cached one. Inside:

| Control | What it does |
| --- | --- |
| **Keep** (`f`) | Moves the image on screen into `liked/`, where pruning can never reach it. It stays in the rotation. |
| **Not this** (`d`, or `x`) | Deletes the image, records it so it is never shown again, and fetches a replacement immediately. |
| **Next** (`n`) | Fetches a fresh image now and restarts the clock. |
| **Endpoint** | Writes `BG_ENDPOINT`. Enter saves, Escape reverts. Empty means "only rotate what is already downloaded". Defaults to `https://bg.ssimo.dev`. |
| **Change every / Keep** | `BG_INTERVAL_MINUTES` and `BG_KEEP_IMAGES`. The interval re-arms without a restart. |
| **Change my background** (`e`) | Writes `BG_ENABLED`. Off until you turn it on; turning it off puts your original wallpaper back. Everything else in the panel is greyed out while it is off. |
| **Restore my wallpaper** | Puts back the background that was in use before the plugin's first change. Only shown while that file is still on disk. |

When the endpoint sends them, the title and a `by creator · licence · source`
line sit under the preview. The licence and source are clickable when the
endpoint gave URLs for them, and open in your browser.

The top line says whether the plugin is off, running or failing, when the
last change happened and what came of it; the bottom line counts what is
cached, kept and blocked. Buttons that cannot apply are greyed out — a
wallpaper the plugin did not download is not one it will offer to rate.

The panel can also be summoned from a keybinding:

```sh
omarchy-shell shell toggle ssimo.bg-pasticcio
```

## Endpoint response

The default endpoint, `https://bg.ssimo.dev`, serves CC0 photography with full
credits. Any endpoint works as long as it answers with JSON: only `url` is
required, everything else is optional, and anything not listed here is
ignored:

```json
{
  "url": "https://upload.wikimedia.org/.../1920px-California%27s_Central_Valley.JPG",
  "title": "California's Central Valley",
  "creator": "Mark Miller",
  "license": "cc0",
  "licenseUrl": "https://creativecommons.org/publicdomain/zero/1.0/deed.en",
  "source": "wikimedia",
  "sourceUrl": "https://commons.wikimedia.org/w/index.php?curid=2374537"
}
```

The answer is a stranger's text on your desktop, so the worker keeps only those
keys, caps each string at 200 characters, and accepts `licenseUrl` and
`sourceUrl` only when they are `http(s)` URLs built from characters that cannot
break out of a quoted shell word. The apostrophe is deliberately not one of
them, which is what makes opening one in a browser safe. A field that fails any of that is dropped, and
the panel simply does not show it. The text fields are rendered as plain text,
never as markup.

Whatever survives is stored next to the image, so the credit still shows for a
picture that came out of the cache days later.

## Configuration

`~/.config/bg-pasticcio/config.env`, created with defaults on first run.
The panel edits this file for you; editing it by hand works just as well.

| Key | Default | Meaning |
| --- | --- | --- |
| `BG_ENABLED` | `0` | Whether the plugin may change the background at all. `0` on a fresh install. |
| `BG_ENDPOINT` | `https://bg.ssimo.dev` | JSON endpoint. Empty = rotate the local cache only. |
| `BG_INTERVAL_MINUTES` | `60` | How often to change the background. |
| `BG_KEEP_IMAGES` | `10` | How many downloaded images to keep. Kept images are not counted. |
| `BG_TIMEOUT_SECONDS` | `20` | Per-request network timeout. |
| `BG_MAX_RETRIES` | `4` | Attempts per network call before falling back. |
| `BG_RETRY_BASE_SECONDS` | `2` | Backoff base: waits 2s, 4s, 8s ... between attempts. |
| `BG_BLOCKED_RETRIES` | `3` | Times to re-ask an endpoint that answers with an image you discarded. |

`BG_ENABLED` and `BG_INTERVAL_MINUTES` are applied live: the config is re-read
within 30 seconds of being saved (immediately when the panel saves it) and the
schedule re-arms itself. The other keys are read by the worker on its next run.

Setting `BG_ENABLED=0` by hand only stops the rotation; it does not restore
your wallpaper. `bg-pasticcio disable`, and the panel toggle, do both.

## Commands

```sh
omarchy-shell bgpasticcio enable    # let it change the background, from now on
omarchy-shell bgpasticcio disable   # stop it, and put your original wallpaper back
omarchy-shell bgpasticcio restore   # put your original wallpaper back, leave it on
omarchy-shell bgpasticcio next      # fetch a fresh image now, restart the clock
omarchy-shell bgpasticcio rotate    # next cached image, no network
omarchy-shell bgpasticcio like      # keep the image on screen for good
omarchy-shell bgpasticcio dislike   # discard it, and never show it again
omarchy-shell bgpasticcio status    # scheduler and worker state as JSON
```

Everything that changes the wallpaper is refused while `BG_ENABLED` is `0` —
`enable` first, or use the panel toggle.

The worker is also runnable directly, which is the fastest way to see what is
going wrong:

```sh
P=~/.config/omarchy/plugins/ssimo.bg-pasticcio/bin/bg-pasticcio
$P enable
$P run
$P restore
$P status
$P like
$P dislike
$P set-config BG_ENDPOINT https://example.com/wallpaper.json
```

## How it works

- The manifest declares two kinds. `Service.qml` is the `service`: a headless
  singleton loaded by `omarchy-shell` at startup that owns the schedule and the
  `bgpasticcio` IPC target. `BarPanel.qml` is the `bar-widget`: the icon and its
  popup. A bar widget is built once per monitor, so the widget keeps no state —
  it calls the service, which owns the one worker process, and every copy of
  the panel therefore agrees with every other.
- The service owns a `Timer` that only runs while `BG_ENABLED` is on, with
  `triggeredOnStart: true` — so an installed plugin has no schedule at all, and
  switching it on is what triggers the first change. A second, single-shot timer
  backs off after a failed run: 1, 2, 4, 8 ... minutes, capped at the interval.
- Before the first background it ever applies, the worker records what was
  already in place — both the resolved file and the raw symlink target — in
  `original-background`. `restore`, and switching the toggle off, put that file
  back if it is still there.
- `bin/bg-pasticcio` does all the work: fetches the JSON, extracts `.url`,
  downloads the image, verifies the downloaded bytes really are an image (an
  HTML error page served with a `200` never becomes your wallpaper), stores it
  under a content hash, applies it, and prunes the pool. It is also the only
  writer of `config.env`, so nothing else has to know how to quote a shell
  variable safely.
- Applying goes through `omarchy-theme-bg-set`, so the symlink Omarchy uses
  stays authoritative and the change is instant.
- Discarding an image records its content hash and source URL in a blocklist.
  Both are checked on the next fetch, so a blocked image is rejected before it
  is downloaded when possible, and thrown away after hashing when not.
- Runs are serialised with `flock`, so a timer tick and a manual
  `omarchy-shell bgpasticcio next` cannot race. `status` and `set-config` do not
  take the lock, so the panel stays responsive during a download.

## Files

| Path | Purpose |
| --- | --- |
| `~/.config/bg-pasticcio/config.env` | your settings |
| `~/.local/share/bg-pasticcio/images/` | the downloaded image pool, pruned to `BG_KEEP_IMAGES` |
| `~/.local/share/bg-pasticcio/liked/` | images you kept; never pruned |
| `~/.local/state/bg-pasticcio/original-background` | the wallpaper in use before the first change, so it can be put back |
| `~/.local/state/bg-pasticcio/blocklist` | `<sha256>` + source URL of every image you discarded |
| `<image>.meta` | JSON sidecar: the endpoint's answer for that image |
| `~/.local/state/bg-pasticcio/setup-required.png` | generated "configure me" background |
| `~/.local/state/bg-pasticcio/bg-pasticcio.log` | one line per run, self-truncating |
| `~/.local/state/omarchy/current/background` | Omarchy's symlink to the active image |

Each image carries a `.meta` sidecar holding the sanitized endpoint answer, so
discarding it can block the URL it came from and the panel can credit it long
after it was downloaded. An image downloaded before this
existed has a plain `.src` sidecar holding only the URL; those are still read,
and replaced with a `.meta` when the endpoint offers the same picture again.

## Troubleshooting

Check the log first: `tail ~/.local/state/bg-pasticcio/bg-pasticcio.log`.

- **Nothing happens on install** — that is the intended behaviour: the plugin
  never changes your background until you turn on **Change my background** in
  the panel (or run `omarchy-shell bgpasticcio enable`). If the toggle is on and
  still nothing happens, `omarchy plugin list` should show `ssimo.bg-pasticcio`
  enabled; if not: `omarchy plugin enable ssimo.bg-pasticcio`.
- **The plugin works but there is no icon** — the widget has to be in the bar
  layout: `omarchy bar put ssimo.bg-pasticcio --after omarchy.clock`.
- **"Not this" says the endpoint only had that same image** — exactly that.
  Many wallpaper endpoints cache one answer for everybody for minutes or hours,
  so there is nothing else to hand out yet. The discarded image is still gone
  and still blocked; the plugin shows a cached one until the endpoint moves
  on.
- **The buttons are greyed out** — either the plugin is switched off, or the
  wallpaper on screen did not come from this plugin (a theme background, or the
  setup notice), so there is nothing to keep or discard.
- **`endpoint response has no usable .url field`** — the endpoint must return a
  top-level `url` key. Verify with `curl -s "$BG_ENDPOINT" | jq .`.
- **`downloaded content is not a supported image`** — the URL served something
  that is not JPEG/PNG/WebP/GIF/BMP, usually an error page or a redirect to a
  login form.
- **Background never changes offline** — the pool is still empty. It fills up
  one image per successful run.
- **A black background telling you to configure an endpoint** — `BG_ENDPOINT`
  was blanked and nothing has been downloaded yet. Put an endpoint back in the
  panel. It is rendered at your largest monitor's resolution
  with ImageMagick, in the system's `sans-serif` font as resolved by
  `fc-match`. Without `magick` the plugin just logs and leaves the background
  alone.
- **Editing the QML changes nothing** — the shell caches compiled QML per file
  URL, so a `rescanPlugins` can hand you the previous version. Run
  `omarchy-restart-shell` while developing.

## Uninstall

Put your own wallpaper back first — from the panel, by switching **Change my
background** off, or from a terminal:

```sh
omarchy-shell bgpasticcio disable
```

Then:

```sh
omarchy plugin remove ssimo.bg-pasticcio
```

The image pool, kept images, config and log are left in place on purpose.
Remove them with:

```sh
rm -rf ~/.config/bg-pasticcio \
       ~/.local/share/bg-pasticcio \
       ~/.local/state/bg-pasticcio
```

Note that if the wallpaper in use still came from the pool, delete it only
after picking another background (`omarchy theme bg next`), or the desktop is
left pointing at a file that no longer exists.
