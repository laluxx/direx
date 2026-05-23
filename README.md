# direx

A standalone terminal file manager in the spirit of Emacs dired, written in Zig.

It lists files the way dired does -- permissions, ownership, size, date, name -- with no dependency on `ls`.
Navigation is keyboard-driven and file opening hands off to `$EDITOR`.

## What it looks like

![screenshot](etc/screenshot.png)

## Keys

| Key             | Action                 |
|-----------------|------------------------|
| `j` `n`  `C-n`  | move down              |
| `k` `p`  `C-p`  | move up                |
| `l` `Enter`     | open directory or file |
| `h`             | go up a directory      |
| `q` `Esc` `C-c` | quit                   |

Navigation wraps at both ends.

## Configuration

On first run, direx creates `~/.config/direx/config.yaml`. Changes to it take effect immediately, no restart needed.

```yaml
theme:
  directories: "#9587DD"
  datetime:    "#9587DD"
  numbers:     "#41b0f3"
  default_fg:  "#e6e6e8"
  heading:     "#49bdb0"
  privileges:
    d:    "#6bd9db"
    r:    "#6dd797"
    w:    "#eae46a"
    dash: "#615B75"
    exec: "#e84c58"

icons:
  .zig: ""
  .md:  ""
```

Any file extension can be mapped to any Nerd Fonts glyph.

## Building

```sh
zig build
zig run src/main.zig
```
