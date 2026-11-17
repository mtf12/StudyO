# StudyO Player

A macOS video player with a built-in AI sidebar. It plays practically every format
(MKV, MP4, AVI, MOV, WebM, FLV, WMV, TS…) through the VLC engine, and lets you ask an AI
installed on your Mac about what is on screen.

## Build and run

```bash
./build.sh --run        # build, then open the app
./build.sh --install    # build, then copy to /Applications
./build.sh --dmg        # build, then make build/StudyO-<version>.dmg for sharing
```

The build uses Xcode's toolchain when Xcode is installed.

Needs: Apple Command Line Tools (`swiftc`) and VLC.app **3.x** in /Applications — the build copies
VLC's `lib` and `plugins` into `build/StudyO.app`, so the built app runs on its own.
The build stops if another VLC series is installed (the live audio level relies on libVLC 3).

## Layout

| File | What it does |
| --- | --- |
| `Sources/StudyOPlayer/StudyOPlayerApp.swift` | App entry, menus, keyboard shortcuts, self-test |
| `Sources/StudyOPlayer/PlayerModel.swift` | libvlc wrapper: open, play, seek, tracks, frame snapshot |
| `Sources/StudyOPlayer/ContentView.swift` | Main window: video area, control bar, drag and drop |
| `Sources/StudyOPlayer/AISidebar.swift` | Left AI panel: AI picker, chat, input |
| `Sources/StudyOPlayer/AIModel.swift` | Chat state, the prompt sent to the AI, subtitle reading |
| `Sources/StudyOPlayer/AudioMeter.swift` | The live sound bars (control panel and Touch Bar) |
| `Sources/StudyOPlayer/CloudAI.swift` | ChatGPT / Gemini by API key, Keychain, saved chats |
| `Sources/StudyOPlayer/L10n.swift` | Arabic / English strings |
| `Sources/StudyOPlayer/Settings.swift` | Preferences and the Settings window |
| `Sources/StudyOPlayer/TouchBar.swift`, `Thumbnails.swift` | Touch Bar and its frame strip |
| `Sources/StudyOPlayer/AIProviders.swift` | Finds AIs on the Mac and runs them |
| `Sources/CVLC/vlc_min.h` | The libvlc C functions the app uses |
| `Resources/Info.plist`, `scripts/make_icon.swift` | Bundle metadata and icon |

## AI sidebar

Detected automatically: **Claude Code**, **Codex CLI**, **Gemini CLI**, and every local
**Ollama** model. Each question is sent with the frame currently on screen, the file name,
the playback position, and nearby subtitle lines: from a subtitle file added by hand, or else a
`.srt` / `.vtt` next to the video with the same name (`Movie.srt`, `Movie.en.srt`…). The AI
does not hear the audio.

To add another AI: add a case to `AIProvider.Kind`, detect it in `AIDetector.detect()`,
and build its command in `AIModel.askCLI`.

## Connecting an AI

The AI must be connected before it can be used: pick it in the sidebar and press
**Sign In & Connect**. For Claude Code this checks `claude auth status` and, if needed, starts
Claude's own browser sign-in. "Disconnect" (in the AI menu) unlinks StudyO Player only.
The frame is sent to the AI but is not shown in the chat.

## Language, Touch Bar, gestures

- Arabic and English UI: Display menu. The AI panel stays on the left (or right, same menu).
- Touch Bar: play/pause (hold it for playback speeds), a strip of frames you can drag on to
  seek, and the time
  (`TouchBar.swift`, frames made by `Thumbnails.swift`).
- Trackpad: spread two fingers for full screen, pinch to leave it.

## Instructor panel

- AIs: Claude Code, Codex CLI and Gemini CLI (sign in through the tool), ChatGPT and Gemini
  (your own API key, kept in the Keychain — `CloudAI.swift`), and local Ollama models.
  Icons come from the AI's own app when it is installed, otherwise a simple mark.
- Chats are saved per video in `~/Library/Application Support/StudyO Player/chats.json` and come
  back when the video is opened again; the clock button lists all of them.
- Drag the line between chat and video to resize.
- Live sound bars (control panel and Touch Bar) follow the real loudness of the sound, read
  from the engine's level-meter filter and delayed by its measured lead (60 ms) so they move
  with what you hear. Spring-smoothed, display-synchronised, drawn with Core Animation layers,
  and fully idle while nothing plays (`AudioMeter.swift`).

## Settings (⌘,)

General (language, panel side, keep on top, resume), Playback (autoplay, repeat, arrow-key
skip, default speed, volume memory), Subtitles (auto-load, size), Assistant (account, what is
sent, answer language), Shortcuts. Keys and defaults are in `Settings.swift` (`Prefs`).

## About, licence, privacy

App menu → About StudyO Player shows the edition (Free), the maker (MT Technologies, Mohamed
Talaat) and the privacy note. `LICENSE.md` has the full text. The app has no analytics and
sends nothing anywhere except the questions put to the connected AI.

## Publishing

The app and the DMG are signed locally only. For other people's Macs to open it without a
Gatekeeper warning it must be signed with an Apple Developer ID and notarized. The bundled
video engine comes from VLC (LGPL/GPL parts): publishing means following those licences.

## Security

- Signed with the hardened runtime; macOS refuses to run the app if a signed file is changed.
- Local files only. Network, streaming-out, capture, remote-control, scripting and password
  modules of the video engine are removed at build time (see `REMOVE` in `build.sh`).
- Claude runs with all tools off (no file access, no commands, no MCP); the frame goes over stdin.
- Codex runs in its read-only sandbox. Gemini CLI gets a workspace setting that switches off its
  shell, file-writing and web tools.
- Questions, file names and subtitles reach CLI tools through stdin, never on the command line
  (where other users of the Mac could see them with `ps`). They are fenced as data.
- AI tools are launched only if owned by you or root and not writable by others, with a
  minimal environment. Stopping a question terminates the tool, even before it has started.
- Frames live in a private temp folder and are deleted after each question. Links in answers
  are not clickable.
- Not sandboxed (it has to launch the AI tools) and not notarized (needs an Apple Developer ID).

## Shortcuts

Space play/pause · ←/→ 5 s · ↑/↓ volume · F full screen · M mute · ⌘O open

## Smoke test

Only in builds made with `./build.sh --selftest`:

```bash
STUDYO_SELFTEST="What is on screen?" STUDYO_SELFTEST_FILE=/path/to/video.mkv \
  "build/StudyO.app/Contents/MacOS/StudyOPlayer"
```

Plays the file, asks the selected AI, prints the answer, and quits. Other modes:

- `STUDYO_SELFTEST_FIXES=/path/video` — seek after the end, Stop before the tool starts, new chat
  during an answer.
- `STUDYO_SELFTEST_AUDIO=/path/tone.wav` — measures how far the level reading leads the sound
  (use a tone that turns loud on each whole second).
