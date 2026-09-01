# Kino

A standalone command-line app for watching movies and shows through your own
debrid account — no browser, no Electron, no background app. Type a title,
pick an episode and a source, and **mpv** opens playing the stream. That's it.

```
$ kino watch "in the grey"
what to watch? (12 results, all shown)
> In the Grey (2026) · movie · ★7.1
  ...
checking 8 sources (14 more unchecked)…
  ✓ In.the.Grey.2026.2160p.WEB-DL ...
which source? (all checked + playable)
> ★ In.the.Grey.2026.2160p.WEB-DL  [18.2 GB · 2160p ...]
playing in mpv: In.the.Grey.2026.2160p.WEB-DL.mkv
```

Kino is a **single binary** — not a library, not a service, nothing to add to
a project. (Unrelated to the `kino` package on hex.pm, which is Livebook's
widget library.)

## What it does

- **Title-first search** via TMDB: movies and shows, season/episode pickers,
  spelling-variant matching ("gray" finds "Grey"), year hints
  (`kino watch "heat 1995"`).
- **Only playable sources are offered.** Every source is actually resolved on
  your debrid provider before it reaches the picker — dead torrents, DMCA'd
  files, and 0-seeder stalls are filtered out with the reason shown.
  Known takedowns are remembered and skipped instantly.
- **Ranked like you'd want**: releases already in your debrid library first,
  provider-confirmed-cached next, then resolution tier with bigger files
  first. Releases in languages other than yours sink to the bottom
  (`KINO_LANG`, default English; dual-audio stays).
- **Continue watching**: `kino continue` jumps back to the exact episode,
  source, **and second** you left off at — the position is checkpointed every
  5 seconds while mpv plays, so it survives player crashes and power loss.
  It's remembered per title/episode, not per stream, so switching to a
  different source resumes from the same spot.
- **Scriptable**: `kino search`/`resolve`/`play` emit JSON when piped, so the
  interactive flow is just one frontend — overlays and scripts are another.

## Install

The binaries are self-contained — no Erlang, no Elixir, nothing to add to a
project. You just need **mpv** for playback (`fzf` is optional but makes the
pickers much nicer).

**Linux (x86_64):**

```sh
sudo pacman -S --needed mpv fzf   # or your distro's equivalent
curl -Lo kino https://github.com/alexdont/kino/releases/latest/download/kino_linux_x86_64
chmod +x kino && mkdir -p ~/.local/bin && mv kino ~/.local/bin/
```

**macOS (Apple Silicon)** — untested build, feedback welcome:

```sh
brew install mpv fzf
curl -Lo kino https://github.com/alexdont/kino/releases/latest/download/kino_macos_aarch64
chmod +x kino && mv kino /usr/local/bin/
```

**From source** (needs Elixir; zig + p7zip only for the standalone build):

```sh
mix deps.get
mix escript.build               # → ./kino (needs Erlang installed to run)
MIX_ENV=prod mix release kino   # → burrito_out/kino_* (self-contained)
```

## Configure

Put your keys in `~/.config/kino/config` (env vars with the same names also
work and take precedence):

```
# required — your Real-Debrid API token: https://real-debrid.com/apitoken
RD_TOKEN=...
# required for the title flow: https://www.themoviedb.org/settings/api
TMDB_API_KEY=...
# preferred audio language for ranking (dual/multi releases always rank normally)
KINO_LANG=en
# poster previews: auto (sharp pixel graphics), ascii (colored ASCII art),
# ascii-bg (ASCII with painted backgrounds), off
KINO_POSTERS=auto
# optional: Jackett/Prowlarr (more indexers), OpenSubtitles, Jimaku
```

`kino config` shows which keys are set.

## Commands

| command | what it does |
| --- | --- |
| `kino watch "<title>"` | the whole flow: title → episode → source → mpv |
| `kino continue` | resume the last thing you watched |
| `kino search "<query>"` | list raw sources (JSON when piped) |
| `kino resolve <magnet>` | magnet → direct stream URL (JSON) |
| `kino play <magnet\|url>` | resolve and launch mpv directly |
| `kino config` | show config status |

`kino watch --raw "<text>"` skips TMDB and searches indexers by text.

## Notes

Kino ships no content and hosts nothing. It searches public indexers and
drives **your own** debrid subscription and API keys, the same way a Stremio
debrid addon does; takedown responses from the provider are respected and
remembered. Real-Debrid is the only provider wired today, but the resolve
step sits behind a behaviour so AllDebrid/TorBox/Premiumize can be added.
