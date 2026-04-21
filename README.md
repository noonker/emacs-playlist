# emacs-playlist
## This repo was written by AI
## No one cares for this code


Search YouTube from Emacs, build a playlist, and download audio to your norns (or other destinations).

Uses `yt-dlp` for searching and downloading, and `ffmpeg` to convert audio to 48 kHz mono WAV — ready for norns.

## Requirements

- [yt-dlp](https://github.com/yt-dlp/yt-dlp)
- [ffmpeg](https://ffmpeg.org/)

## Installation

With `straight.el` and `use-package`:

```elisp
(use-package emacs-playlist
  :straight (:host github :repo "noonker/emacs-playlist"))
```

Or clone the repo and add it to your load path:

```elisp
(add-to-list 'load-path "~/git/emacs-playlist")
(require 'emacs-playlist)
```

## Usage

### 1. Search

```
M-x emacs-playlist-search
```

Enter a query. Results appear in a tabulated list with title, channel, duration, and view count.

### 2. Build a playlist

In the search results buffer:

| Key | Action                        |
|-----|-------------------------------|
| `m` | Mark entry                    |
| `u` | Unmark entry                  |
| `U` | Unmark all                    |
| `a` | Add entry at point to playlist|
| `x` | Add all marked to playlist    |
| `s` | New search                    |
| `P` | View current playlist         |
| `d` | Finalize and download         |

### 3. Review the playlist

`P` opens the playlist buffer. From there:

| Key | Action                  |
|-----|-------------------------|
| `d` | Remove entry at point   |
| `D` | Clear entire playlist   |
| `s` | Search for more songs   |
| `f` | Finalize and download   |
| `q` | Quit                    |

### 4. Finalize

Pressing `d` (from search) or `f` (from playlist) prompts for a destination, then:

1. Downloads audio with `yt-dlp`
2. Converts to 48 kHz mono WAV with `ffmpeg`
3. Sanitizes filenames (lowercase, no symbols, dashes for spaces)
4. Sends files to the chosen destination

## Destinations

| Destination      | Description                                          |
|------------------|------------------------------------------------------|
| Norns            | Uploads via sftp to `dust/audio/<date>/` on the norns|
| VLC Wi-Fi Share  | Uploads to a VLC HTTP endpoint                       |
| Open Folder      | Opens the download directory in your file manager     |

## Configuration

```elisp
;; Number of search results (default 10)
(setq emacs-playlist-search-results 10)

;; Max concurrent downloads (default 2)
(setq emacs-playlist-max-concurrent 2)

;; Norns connection
(setq emacs-playlist-norns-host "norns.local")
(setq emacs-playlist-norns-user "we")

;; VLC connection
(setq emacs-playlist-vlc-host "192.168.50.140")
(setq emacs-playlist-vlc-port 80)

;; Sample rate (default 48000)
(setq emacs-playlist-sample-rate 48000)
```
