# Granola-Local Spec — First Pass

## Vision
A local-first meeting companion that captures, transcribes, and digests conversations on-device. No cloud, no subscription, no data leaves the machine.

---

## Tech Stack

| Layer | Choice | Rationale |
|-------|--------|-----------|
| **App Framework** | Tauri (Rust + WebView) | Native performance, small binary, access to OS audio APIs, web UI for rapid iteration |
| **Frontend** | Svelte 5 + Tailwind | Reactive, minimal bundle, compiles to vanilla JS |
| **Audio Capture** | `cpal` (Rust) → ring buffer → WAV/OPUS chunks | Cross-platform, low-level control, supports both loopback (system audio) and mic |
| **Transcription** | `whisper.cpp` (GGML) via `whisper-rs` bindings | Best-in-class local ASR, CPU + Metal/GPU, streaming support via `whisper.cpp` server mode or direct inference |
| **Summarization/Digest** | `llama.cpp` (GGUF) via `llama-rs` or `candle` | Local LLM inference, Metal on Apple Silicon, quantized models fit in RAM |
| **Storage** | SQLite (via `rusqlite` / `sqlx`) + FTS5 | Single file, full-text search, ACID, portable, zero-config |
| **Settings/State** | `tauri-plugin-store` (encrypted) | API keys (if any), model paths, user prefs |
| **Packaging** | `tauri-cli` → `.app` / `.msi` / `.AppImage` | Native installers, auto-update via GitHub Releases |

**Why not Electron?** Binary size (~150MB vs ~15MB), RAM, and audio loopback on macOS requires hardened runtime + entitlements — Tauri handles this cleaner.

---

## Local Model Choice

| Task | Model | Size (Q4_K_M) | Notes |
|------|-------|---------------|-------|
| **Transcription** | `whisper-large-v3-turbo` | ~800 MB | Best accuracy/speed tradeoff; turbo is 8x faster than large-v3 |
| **Summarization** | `qwen2.5-7b-instruct-q4_k_m` | ~4.2 GB | Strong instruction following, 32k context, fits 8GB unified memory |
| **Fallback (smaller)** | `gemma-2-2b-it-q4_k_m` | ~1.6 GB | For 8GB machines; weaker but usable |
| **Embeddings (optional)** | `nomic-embed-text-v1.5-q4_k_m` | ~270 MB | If we add semantic search later |

**Model storage**: `~/Library/Application Support/granola-local/models/` (macOS), `~/.local/share/granola-local/models/` (Linux), `%APPDATA%\granola-local\models\` (Windows). App downloads on first run with progress UI, verifies SHA256.

---

## Capture Mode: Hot-Mic vs Push-to-Talk

### Default: **Push-to-Talk (PTT)**
- Global hotkey (default: `⌥ Space`) toggles recording
- Visual indicator in menu bar / system tray (red dot = recording)
- Why: Privacy-first, battery-conscious, explicit consent, works in open offices

### Optional: **Hot-Mic (Continuous)**
- Always listening, VAD (Voice Activity Detection) gates transcription
- `silero-vad` (ONNX, ~1MB) runs inline — near-zero CPU
- Segments auto-split on silence > 2s
- **Requires explicit opt-in** + macOS microphone permission + "Record system audio" permission
- Battery warning shown in settings

**Implementation**: Both modes share the same audio pipeline. PTT = VAD threshold = ∞ (manual trigger). Hot-mic = VAD threshold = -50dB (tunable).

---

## Digest Cadence

| Trigger | Output | Latency Target |
|---------|--------|----------------|
| **Real-time (streaming)** | Live transcript chunks (partial → final) | < 500ms per chunk |
| **Segment close** (PTT release or VAD silence) | Segment summary (2-3 bullets) | < 3s |
| **Meeting end** (user clicks "End Meeting") | Full digest: title, attendees (heuristic), topics, decisions, action items, timeline | < 15s |
| **On-demand** | Re-digest any meeting with custom prompt | < 10s |

**Streaming architecture**:
```
Audio → Ring Buffer → whisper.cpp (streaming) → Partial text → UI
                                    ↓
                              VAD / PTT release → Segment boundary
                                    ↓
                              llama.cpp (summarize segment) → Segment card
                                    ↓
                              Meeting end → llama.cpp (full context) → Digest
```

---

## Storage Schema (SQLite)

```sql
-- Meetings
CREATE TABLE meetings (
  id           TEXT PRIMARY KEY,           -- ULID
  started_at   INTEGER NOT NULL,           -- unix ms
  ended_at     INTEGER,                    -- null = in progress
  title        TEXT,                       -- user-editable
  source       TEXT NOT NULL,              -- 'mic' | 'loopback' | 'both'
  mode         TEXT NOT NULL,              -- 'ptt' | 'hotmic'
  model_asr    TEXT NOT NULL,              -- e.g. 'whisper-large-v3-turbo-q4'
  model_llm    TEXT NOT NULL,              -- e.g. 'qwen2.5-7b-instruct-q4'
  digest_json  TEXT,                       -- full digest JSON (cached)
  created_at   INTEGER NOT NULL DEFAULT (strftime('%s','now')*1000)
);

-- Audio segments (one per PTT press or VAD segment)
CREATE TABLE segments (
  id           TEXT PRIMARY KEY,           -- ULID
  meeting_id   TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  seq          INTEGER NOT NULL,           -- order within meeting
  started_at   INTEGER NOT NULL,           -- unix ms
  ended_at     INTEGER NOT NULL,
  audio_path   TEXT NOT NULL,              -- relative to app data dir
  duration_ms  INTEGER NOT NULL,
  transcript   TEXT,                       -- final transcript
  summary      TEXT,                       -- 2-3 bullet summary
  speaker_hint TEXT,                       -- optional diarization label
  created_at   INTEGER NOT NULL DEFAULT (strftime('%s','now')*1000)
);

-- FTS5 for full-text search across transcripts + summaries
CREATE VIRTUAL TABLE segments_fts USING fts5(
  meeting_id UNINDEXED,
  transcript,
  summary,
  content='segments',
  content_rowid='rowid'
);

-- Triggers to keep FTS in sync
CREATE TRIGGER segments_ai AFTER INSERT ON segments BEGIN
  INSERT INTO segments_fts(rowid, meeting_id, transcript, summary)
  VALUES (new.rowid, new.meeting_id, new.transcript, new.summary);
END;

CREATE TRIGGER segments_ad AFTER DELETE ON segments BEGIN
  INSERT INTO segments_fts(segments_fts, rowid, meeting_id, transcript, summary)
  VALUES ('delete', old.rowid, old.meeting_id, old.transcript, old.summary);
END;

CREATE TRIGGER segments_au AFTER UPDATE ON segments BEGIN
  INSERT INTO segments_fts(segments_fts, rowid, meeting_id, transcript, summary)
  VALUES ('delete', old.rowid, old.meeting_id, old.transcript, old.summary);
  INSERT INTO segments_fts(rowid, meeting_id, transcript, summary)
  VALUES (new.rowid, new.meeting_id, new.transcript, new.summary);
END;

-- Settings (key-value)
CREATE TABLE settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
```

**File layout** (per meeting):
```
~/Library/Application Support/granola-local/
├── meetings/
│   └── <meeting-ulid>/
│       ├── audio/
│       │   ├── seg-001.opus
│       │   └── seg-002.opus
│       ├── transcript.jsonl      # streaming chunks for replay
│       └── digest.json           # cached full digest
├── models/
│   ├── whisper-large-v3-turbo-q4_k_m.bin
│   ├── qwen2.5-7b-instruct-q4_k_m.gguf
│   └── silero_vad.onnx
└── granola.db                    # SQLite DB
```

---

## MVP Scope (v0.1)

**Must have**:
- [ ] Tauri + Svelte scaffold with menu-bar/tray icon
- [ ] PTT global hotkey + menu bar recording indicator
- [ ] Microphone capture → OPUS chunks → whisper.cpp streaming → live transcript UI
- [ ] Segment summaries on PTT release (llama.cpp)
- [ ] "End Meeting" → full digest (title, topics, decisions, action items)
- [ ] SQLite storage + FTS search (Cmd+K to search meetings)
- [ ] Settings: model paths, hotkey, capture source (mic/loopback/both)
- [ ] First-run model downloader with progress + SHA256 verify

**Nice to have (v0.2+)**:
- [ ] Hot-mic mode with Silero VAD
- [ ] Speaker diarization (pyannote via ONNX or local whisper.cpp speaker embeddings)
- [ ] System audio loopback (BlackHole on macOS, PipeWire on Linux)
- [ ] Export: Markdown, Notion, Obsidian, PDF
- [ ] Calendar integration (read events → auto-title meetings)
- [ ] Plugin API for custom digest prompts

---

## Open Questions

1. **Whisper.cpp streaming**: Use `whisper.cpp` server mode (HTTP) or embed `whisper-rs` directly? Direct embedding avoids socket overhead but couples versions. Leaning direct.
2. **Metal vs CPU**: On Apple Silicon, `whisper.cpp` + `llama.cpp` both use Metal. Need to manage VRAM — run sequentially or use `ggml` backend config to limit.
3. **Permissions UX**: macOS mic + screen recording (for loopback) prompts are scary. Need a guided setup wizard.
4. **Model updates**: Auto-check for new quantized releases? Manual "Check for updates" button safer.
5. **Windows**: Loopback audio via WASAPI loopback client — more complex. Defer to v0.2.

---

## Next Steps

1. `cargo tauri init` in `prototypes/granola-local/`
2. Add `whisper-rs`, `llama-rs`, `rusqlite`, `cpal`, `opus`, `ulid` to `Cargo.toml`
3. Build audio capture → ring buffer → OPUS writer (Rust side)
4. Expose Tauri commands: `start_recording`, `stop_recording`, `transcribe_stream`, `summarize_segment`, `end_meeting`
5. Svelte UI: menu bar popover, meeting list, transcript view, digest view
6. Model downloader with `reqwest` + progress events

---

*Generated on first wakeup. One file, one commit. Ready for Andy to react.*
