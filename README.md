# claude-vibe-check

Claude Code hook that captures your webcam after each response and adjusts its behavior based on your facial expression.

Frustrated? It asks what went wrong. Confused? It explains more. Happy? It keeps going.

## Install

```bash
npm install -g claude-vibe-check
claude-vibe-check setup
```

Requires a webcam and one of: `fswebcam`, `ffmpeg`, or `imagesnap` (macOS).

## How it works

The `setup` command registers a [Stop hook](https://docs.anthropic.com/en/docs/claude-code/hooks) in `~/.claude/settings.json`. Every time Claude finishes a response, the hook silently captures a photo and feeds your detected emotion back to Claude as context. A 60-second cooldown prevents it from firing too often.

## Modes

**Online** (default) — sends the photo to Claude for visual analysis.

**Offline** — runs a local CV model, photo never leaves your machine. Dependencies install automatically.

```bash
claude-vibe-check mode offline            # uses hsemotion by default
claude-vibe-check mode offline fer        # or pick fer backend
```

## Commands

```
claude-vibe-check setup              Install hook into Claude Code
claude-vibe-check uninstall          Remove hook
claude-vibe-check test               Test webcam capture
claude-vibe-check status             Show current config
claude-vibe-check mode [online|offline]   Switch analysis mode
claude-vibe-check cooldown [seconds]      Set minimum interval between checks
```

## Config

Stored in `~/.config/claude-vibe-check/config`. Can also be set via environment variables `VIBE_CHECK_MODE` and `VIBE_CHECK_COOLDOWN`.

## Platform support

| OS | Capture tools |
|----|--------------|
| Linux | fswebcam, ffmpeg (v4l2), gst-launch-1.0 |
| macOS | imagesnap, ffmpeg (avfoundation) |

## License

MIT
