# Kala

A standalone command-line app for watching movies and shows through your own
debrid account — no browser, no Electron, no background app. Type a title,
pick an episode and a source, and **mpv** opens playing the stream. That's it.

```
$ kala watch "in the grey"
what to watch? (12 results, all shown)
> In the Grey (2026) · movie · ★7.1
  ...
checking 8 sources (14 more unchecked)…
  ✓ In.the.Grey.2026.2160p.WEB-DL ...
which source? (all checked + playable)
> ★ In.the.Grey.2026.2160p.WEB-DL  [18.2 GB · 2160p ...]
playing in mpv: In.the.Grey.2026.2160p.WEB-DL.mkv
```

Kala is a **single binary** — not a library, not a service, nothing to add to
a project. (Unrelated to the `kino` package on hex.pm, which is Livebook's
widget library.)

## What it does

- **Title-first search** via TMDB: movies and shows, season/episode pickers,
  spelling-variant matching ("gray" finds "Grey"), year hints
  (`kala watch "heat 1995"`).
- **Only playable sources are offered.** Every source is actually resolved on
  your debrid provider before it reaches the picker — dead torrents, DMCA'd
  files, and 0-seeder stalls are filtered out with the reason shown.
  Known takedowns are remembered and skipped instantly.
- **Ranked like you'd want**: releases already in your debrid library first,
  provider-confirmed-cached next, then resolution tier with bigger files
  first. Releases in languages other than yours sink to the bottom
  (`KALA_LANG`, default English; dual-audio stays).
- **Continue watching**: `kala continue` jumps back to the exact episode,
  source, **and second** you left off at — the position is checkpointed every
  5 seconds while mpv plays, so it survives player crashes and power loss.
  It's remembered per title/episode, not per stream, so switching to a
  different source resumes from the same spot.
- **Scriptable**: `kala search`/`resolve`/`play` emit JSON when piped, so the
  interactive flow is just one frontend — overlays and scripts are another.

## Install

The binaries are self-contained — no Erlang, no Elixir, nothing to add to a
project. You just need **mpv** for playback (`fzf` is optional but makes the
pickers much nicer).

**Linux (x86_64):**

```sh
sudo pacman -S --needed mpv fzf   # or your distro's equivalent
curl -Lo kala https://github.com/alexdont/kala/releases/latest/download/kala_linux_x86_64
chmod +x kala && mkdir -p ~/.local/bin && mv kala ~/.local/bin/
```

**Windows** — use WSL2 (the built-in Ubuntu console; Windows 11 or updated
Windows 10, so mpv opens as a regular window via WSLg). Then it's exactly the
Linux install:

```sh
sudo apt install -y mpv fzf chafa
curl -Lo kala https://github.com/alexdont/kala/releases/latest/download/kala_linux_x86_64
chmod +x kala && mkdir -p ~/.local/bin && mv kala ~/.local/bin/
```

**macOS (Apple Silicon)** — untested build, feedback welcome:

```sh
brew install mpv fzf
curl -Lo kala https://github.com/alexdont/kala/releases/latest/download/kala_macos_aarch64
chmod +x kala && mv kala /usr/local/bin/
```

**From source** (needs Elixir; zig + p7zip only for the standalone build):

```sh
mix deps.get
mix escript.build               # → ./kala (needs Erlang installed to run)
MIX_ENV=prod mix release kala   # → burrito_out/kala_* (self-contained)
```

## Configure

Run `kala setup` — an interactive wizard that asks for your two keys,
validates them live against the real services, and writes the config for
you. (`kala doctor` later checks every binary, key, and service kala talks
to, with latencies.)

Or put keys in `~/.config/kala/config` by hand (env vars with the same
names also work and take precedence):

```
# required — your Real-Debrid API token: https://real-debrid.com/apitoken
RD_TOKEN=...
# required for the title flow: https://www.themoviedb.org/settings/api
TMDB_API_KEY=...
# optional second debrid provider: https://torbox.app/settings
#TORBOX_API_KEY=...
# preferred audio language for ranking (dual/multi releases always rank normally)
KALA_LANG=en
# poster previews: auto (sharp pixel graphics), ascii (colored ASCII art),
# ascii-bg (ASCII with painted backgrounds), off
KALA_POSTERS=auto
# intro/credits skipping — detected via AniSkip (anime) + named chapters:
#   ask (default): a "Skip — hold TAB" button appears on the video, skip is your call
#   auto: skip immediately · off: disable (hold Tab = +85s works in ask/auto)
KALA_SKIP=ask
# autoplay the next episode when one ends ("on" to enable — off by default;
# --binge or the post-play menu's autoplay entry do it per session)
KALA_AUTOPLAY=off
# optional: Jackett/Prowlarr (more indexers), OpenSubtitles, Jimaku
```

`kala config` shows which keys are set.

## Commands

| command | what it does |
| --- | --- |
| `kala watch "<title>"` | the whole flow: title → episode → source → mpv |
| `kala resume` | instantly resume the last thing you watched |
| `kala continue` | pick from your watch history |
| `kala search "<query>"` | list raw sources (JSON when piped) |
| `kala resolve <magnet>` | magnet → direct stream URL (JSON) |
| `kala play <magnet\|url>` | resolve and launch mpv directly |
| `kala setup` | first-run wizard: keys in, validated live |
| `kala doctor` | health-check binaries, keys, and services |
| `kala config` | show config status |

`kala watch --raw "<text>"` skips TMDB and searches indexers by text.

## Notes

Kala ships no content and hosts nothing. It searches public indexers and
drives **your own** debrid subscription and API keys, the same way a Stremio
debrid addon does; takedown responses from the provider are respected and
remembered. Real-Debrid and TorBox are wired today, and the resolve
step sits behind a behaviour so AllDebrid/Premiumize can be added too.
