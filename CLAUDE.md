# Vocal MIDI Generator — Project Documentation

A REAPER ReaScript (Lua) that generates MIDI notes from an audio track to assist with karaoke / lyric-timing workflows. Single file: `vocal_midi_generator_vkr.lua`.

This document is the canonical reference when working on the script. Read it before making changes.

---

## Quick orientation

**Purpose.** Take a vocal stem on one track, find where syllables/phrases occur, and write MIDI notes (timing-aligned, optionally pitch-aligned) into an existing MIDI item on another track. Used to author timing data for a karaoke game.

**Runtime.** REAPER's embedded Lua. UI is ReaImGui (a hard dependency — the script bails on startup if it's missing or too old). Requires **REAPER 6.x or later** and **ReaImGui 0.7 or later** (August 2022). The startup guard validates both: missing ReaImGui tests `ImGui_CreateContext`; outdated ReaImGui (pre-0.7) tests `ImGui_BeginDisabled`. All core REAPER APIs used (`new_array`, audio accessor, MIDI text events, `Undo_CanUndo2`) have been available since REAPER 5.x — the 6.x floor is set by ReaImGui's own requirements, not by any REAPER API the script calls directly.

**Single-file by design choice.** REAPER Lua scripts *can* load other files via `dofile()` or `require()` (use `({reaper.get_action_context()})[2]` to get the current script's own path and derive sibling paths from it). We stay single-file for simpler distribution (one file to download and register) and because the shared state table `S`, the DSP pipeline, and the UI reference each other so heavily that splitting would add friction without meaningful benefit. Long file is fine; well-organized sections matter more than line count.

**Versioning.** Header comment carries `@version`. Bump it whenever behavior or UI changes meaningfully. Mention what's new in the `@about` block.

---

## How the script is used (workflow)

The user's typical session:

1. Drop a vocal stem on one track. Add a destination track that contains a MIDI item covering the timeline area to work on. Open the script.
2. Pick the audio source track and the MIDI destination track in the dropdowns. Smart defaults are applied on startup (see design decision #9).
3. Optionally make a time selection in REAPER to limit work to one section.
4. Tune the Detection sliders to taste — RMS threshold, low-pass, peak-split ratio, min offset, min note length, RMS window.
5. Pick a Pitch source (single pitch / reference MIDI / built-in YIN detection).
6. Use **Dry run** to see counts without writing anything.
7. Use **Generate notes (append)** to write notes into the destination MIDI item.
8. Iterate. Re-running Generate over the same range clears existing notes at the pitches we're about to add, so iteration doesn't stack duplicates.

Two specialized actions exist outside that main loop:

- **Auto-tune from reference.** User manually places a few notes at the Default pitch as a "ground truth" timing reference, makes a time selection over them, and hits Auto-tune. The script searches for detection parameters (coordinate descent) that best reproduce those reference notes, then applies them to the sliders. Doesn't change pitch settings or RMS window.
- **Apply pitch changes.** Skips detection entirely. Reads the existing notes on the destination MIDI item and reassigns their pitches via the configured Pitch source, preserving position and length. Used after manual timing tweaks. Disabled in Single pitch mode.

---

## Pipeline (the core data flow)

```
ResolveAnalysisRange(audio_track)
        │   reads time selection, finds the audio item, returns range
        ▼
ComputeRMSContour(item, range, window_s, lpf_cutoff_hz)
        │   reads samples via take audio accessor
        │   optional 12 dB/oct LPF (two cascaded one-poles), per-channel state
        │   emits per-window RMS values
        ▼
GateAndSplit(contour, threshold, split_ratio, min_note_s)
        │   pass 1: gate by absolute RMS threshold → phrases
        │   pass 2 (if split_ratio > 0): split each phrase wherever
        │           contour drops below peak × split_ratio
        │   filter out sub-min_note_s notes
        ▼
ApplyMinOffset(notes, min_off_s)
        │   for each note, cap end time at next_note.start − min_off
        │   drop notes that get squeezed to zero length
        ▼
AssignPitches(notes, ref_track, audio_item)
        │   per-note: lookup pitch from configured source
        │            (Single → default, Reference → nearest MIDI on ref track,
        │             YIN → DetectPitchYIN on audio_item, fallback to default)
        │   apply [min_pitch, max_pitch] via octave-shift, clamp as fallback
        ▼
ClearNotesAtPitchesInRange + InsertNotes
            into the destination MIDI take
```

Auto-tune wraps this pipeline:
- Caches the contour by `(window_ms, lpf_cutoff_hz)` so most parameter sweeps don't recompute audio analysis.
- Coordinate descent: two coarse passes over candidate values for each of the five tunable parameters, then a fine refinement pass exploring values near the best found. Skips `window_ms` (resolution choice, not fit-to-reference).

Apply-pitch reuses `AssignPitches` only — feeds it `{s, e}` pairs read from existing MIDI notes, then deletes and reinserts the changed notes via `MIDI_DeleteNote` + `MIDI_InsertNote` (preserving position, length, channel, velocity). Uses the insert/delete pattern instead of `MIDI_SetNote` because `MIDI_SetNote` does not register properly with REAPER's undo system.

---

## File structure

The script is organized top-to-bottom in this order. Keep additions in their natural section.

```
1.  @description / @version / @about header
2.  ReaImGui dependency check
3.  Mode constants                 MODE_SINGLE / MODE_REFERENCE / MODE_YIN
                                   RB3_MIN_PITCH, RB3_MAX_PITCH, RB3_PHRASE_PITCH
                                   LYRIC_IGNORE (special text events to preserve)
4.  DEFAULTS table                 single source of truth for defaults
5.  S table                        live state (mutated by sliders & actions)
                                   includes S.lyrics_path (session-only, not saved)
6.  ResetXxx() functions           per-section resets to factory defaults
7.  Settings save/load             SerializeSettings, DeserializeSettings,
                                   SaveSettings, LoadSettings
                                   + auto-load on script open
8.  TIPS table                     all tooltip text in one place
9.  Helpers                        PitchName, Tooltip, SliderTooltip,
                                   FormatTime, GetTrackList, TrackCombo,
                                   GetTimeSelection, TrackHasAudio, TrackHasMIDI,
                                   SetDefaultTracks, AutoDetectLyricsFile
10. Range/target resolution        ResolveAnalysisRange,
                                   FindMIDIItem, FindFirstMIDIItem,
                                   ResolveApplyPitchTarget
11. MIDI reading                   ReadAllMIDINotesOnTrack,
                                   ReadReferenceNotes, ReadAutoTuneRefNotes,
                                   FindNearestRefPitch
12. Pitch helpers                  ApplyPitchRange,
                                   ClearNotesAtPitchesInRange
13. DSP                            ComputeRMSContour,
                                   GateAndSplit, ApplyMinOffset,
                                   OpenYINContext, CloseYINContext,
                                   DetectPitchYIN
14. Pipeline                       RunDetection, AssignPitches
15. Result formatting              FormatResult, FormatAutoTuneResult
16. Auto-tune                      EvaluateParams, AutoTune,
                                   ApplyAutoTuneResult, ScoreNotes
17. Insert helpers                 InsertNotes
18. Lyrics helpers                 ParseLyricsFile, ClearLyricEvents
19. Track resolution               ResolveTracks, ResolveApplyPitchTracks
20. Actions                        Preview, Generate, RunAutoTune,
                                   ApplyPitchChangesAction,
                                   ClearLyricsAction, AssignLyricsAction
21. UI                             SectionHeader, Loop
22. r.defer(Loop)                  start
```

---

## Public-facing concepts (what the UI exposes)

### Detection parameters

| Setting | Range | Default | What it does |
|---|---|---|---|
| **RMS threshold** | 0.001 – 0.5 | 0.05 | Audio level above which a note starts. Lower = more sensitive. |
| **Low-pass cutoff** | 0 – 8000 Hz | 0 (Off) | Filters audio before energy detection. Cuts sibilants so note starts snap to vowels. 1500–2500 Hz is the vocal sweet spot. |
| **Peak-split ratio** | 0 – 95 % | 0 (Off) | After detection, splits a phrase wherever its RMS dips below `peak × ratio`. Separates fast syllables that don't drop below absolute threshold. |
| **Min offset to next note** | 0 – 500 ms | 100 ms | Forces a minimum gap before the next note. End times get capped. |
| **Min note length** | 10 – 500 ms | 60 ms | Discards sub-threshold notes. |
| **RMS window** | 5 – 100 ms | 25 ms | Analysis resolution. Trade-off between precision and speed. **Not modified by Auto-tune.** |

### Pitch sources (radio button)

- **Single pitch.** Every note gets `S.pitch` (the Default pitch slider).
- **Reference MIDI.** For each note, find the nearest MIDI note on a chosen reference track within the configured Search tolerance (50–2000 ms). Falls back to Default pitch when nothing is in range. Reads from *all* MIDI items on the reference track that overlap the analysis range.
- **Built-in detection (YIN).** Runs the YIN monophonic pitch detection algorithm on the audio source directly — no external MIDI reference needed. Samples a window from ~30% into each note (to hit steady-state vowel, avoiding the attack transient). Falls back to Default pitch when the algorithm cannot find a confident pitch estimate. `Apply pitch changes` works in this mode.

#### YIN parameters

| Setting | Range | Default | What it does |
|---|---|---|---|
| **YIN threshold** | 0.01 – 0.5 | 0.15 | Aperiodicity confidence cutoff. Lower = more confident detections, more fallbacks. Higher = more detections, more octave errors. |
| **Min frequency (Hz)** | 40 – 400 | 80 Hz | Lower bound on detectable pitch. Sets the longest lag the algorithm searches. |
| **Max frequency (Hz)** | 200 – 2000 | 1000 Hz | Upper bound on detectable pitch. Sets the shortest lag. Must be > Min frequency. |
| **YIN window (ms)** | 10 – 100 | 30 ms | Length of audio analysed per note. Longer = more stable but misses short notes. Capped at 80% of the note length. |

### Pitch range constraints

Two checkbox+slider pairs (min and max). When a pitch falls outside the range, the script first tries octave-shifting it back into range (±12 at a time, up to 16 attempts). If the range is narrower than 12 semitones and no octave fits, it clamps to the nearer endpoint. This is mainly for fixing octave-error artifacts from AI stem separation. The `range_adjusted` count appears in the result panel when non-zero.

### Lyrics section

A section below MIDI output for assigning lyric text events to the destination MIDI item.

**File selection** — `S.lyrics_path` holds the current file path for the session (not persisted to project state). On script open and project switch, `AutoDetectLyricsFile` checks for `lyrics.txt` in the project folder and sets the path automatically if found. **Browse...** opens a native file picker filtered to `.txt` starting in the project folder; non-`.txt` selections are rejected with an error message.

**Clear lyrics** — removes all type-5 (lyric) MIDI text events from the entire destination MIDI take, preserving entries in `LYRIC_IGNORE`. Always operates on the whole take regardless of time selection. Wrapped in an undo block.

**Assign lyrics** — clears first (same ignore list), then assigns words from the file to notes in order:
1. Reads the file, strips `[...]` comment blocks, splits on any whitespace.
2. Reads all notes from the destination take. Notes in the RB3 vocal range (36–84) become candidates. Notes at `RB3_PHRASE_PITCH` (105) are collected separately for validation.
3. If a time selection is active, only notes within it receive lyrics. Without a selection, all vocal-range notes on the take are used.
4. Inserts one type-5 text event at the PPQ start of each candidate note, in start-time order.
5. Reports to the result panel: syllables added, scope, count-mismatch warning if notes ≠ lyrics, and phrase capitalization check.

**Phrase capitalization check** — for each phrase marker note (pitch 105), finds the first scoped note whose start time is at or after the marker's start, and checks that its assigned lyric starts with an uppercase letter. Reports each violation as `mNN  Xm SS.MMMsec  "word"` so the user can navigate directly in REAPER.

**Lyric file format** — plain text. Words separated by any whitespace (spaces, tabs, newlines). `[anything in brackets]` is stripped before splitting, so section headers like `[chorus]` are ignored.

**`LYRIC_IGNORE`** — module-level constant table of special game text events that both Clear and Assign preserve:
```lua
local LYRIC_IGNORE = {
    ['[tambourine_start]'] = true, ['[tambourine_end]'] = true,
    ['[cowbell_start]']    = true, ['[cowbell_end]']    = true,
    ['[clap_start]']       = true, ['[clap_end]']       = true,
}
```

**`FindFirstMIDIItem(track)`** — simpler variant of `FindMIDIItem`. Returns the first MIDI item on the track with no range-coverage requirement. Used by the lyrics actions because lyrics typically span the whole song and don't need the item to cover a specific analysis range.

### Save / Load

`SetProjExtState` / `GetProjExtState` under section `VocalMIDIGenVKR`, key `settings_v1`. Single slot per project. Auto-loads on script open (silent if no save exists).

**What's saved:** all detection sliders + pitch settings (including YIN parameters) + velocity.
**What's NOT saved:** track selections (audio_idx, midi_idx, ref_idx). Track positions can shift between sessions, so saved indices would be brittle. If we ever want to persist tracks, use `GetTrackGUID`.

`DeserializeSettings` parses each field independently. Adding new fields to `SerializeSettings` won't break loading older saves — missing fields just keep their current value.

---

## Key design decisions (and why)

### 1. Append, don't replace, MIDI items
Generate writes into an *existing* MIDI item the user has already created on the destination track. Doesn't create new items. Reasoning: users typically want to add notes alongside other content, and creating new items per run produced overlap/duplication issues.

### 2. Clear before append, scoped by pitch
On Generate, the script first deletes existing notes at every pitch the new run will produce (plus the Default pitch as safety), but only within the analysis range. Notes at *other* pitches survive — so reference pitches placed by hand or by an external tool aren't destroyed. Re-running Generate is idempotent for that pitch set.

### 3. Pitch range = octave-snap, not clamp-only
When out-of-range, octave-shift toward the range first. Most octave artifacts from stem separation preserve the note name (it's `C5` showing up as `C2`, not random pitches), so octave-shift recovers the intended pitch. Clamp is only the fallback for ranges narrower than 12 semitones.

### 4. Auto-tune scoring weights
`score = 1000 × (misses + extras) + 1000 × mean_start_diff_s + 100 × mean_length_diff_s`

Lower is better. Note count dominates (1 missed note ≈ 1 second of cumulative start error). Start time matters about 10× as much as length for tie-breaking. These weights produce the user-facing behavior: "match the right number of notes first, then get them in the right place, then worry about lengths."

### 5. Auto-tune skips `window_ms`
Window size is a quality/speed trade-off, not a fit-to-reference parameter. Letting auto-tune fiddle with it would just make detection slower without improving accuracy meaningfully, and the contour cache key includes it — changing window invalidates the cache.

### 6. Ctrl+click hint via `SliderTooltip` helper
Every slider tooltip ends with a Ctrl+click hint. Implemented as a thin helper that appends the hint, so all sliders get it consistently and TIPS strings stay clean. Buttons use `Tooltip` (no hint).

### 7. `Apply pitch changes` is opt-in, not automatic
Doesn't run as part of Generate. Separate button, separate flow, separate target resolution (`ResolveApplyPitchTarget` allows partially-overlapping MIDI items, unlike `FindMIDIItem` which requires full coverage). Disabled in Single pitch mode (would just overwrite every note with the same pitch — useless).

### 8. Time selection is the primary scope mechanism
Almost everything respects time selection: detection range, auto-tune range, apply-pitch range. Without a time selection, actions fall back to whole-item or whole-track defaults. This is the iteration mechanism — work one section at a time.

### 9. Smart default track selection on startup
`SetDefaultTracks` runs once at startup (and again on project switch). For the audio source it prefers a track named "VOCALS AUDIO", then "DRYVOX1", checking that the track has a non-MIDI item. For the MIDI destination it prefers "PART VOCALS", checking that it has a MIDI item. Falls back to track index 0 (first track) if no match is found. This reduces manual setup when the project follows a predictable naming convention.

### 10. Project-switch detection
The Loop function compares the current REAPER project pointer (`EnumProjects(-1)`) against a cached value each frame. When they differ, it resets track indices to 0, calls `LoadSettings` for the new project (or resets to defaults), re-runs `SetDefaultTracks`, and updates `S.status`. This ensures no state from the previous project tab leaks into the new session.

### 11. Button widths are text-derived, not fixed
All action and auto-tune buttons use `r.ImGui_CalcTextSize(ctx, label) + _bp` for their width (where `_bp = 40`, giving ~20 px padding on each side). This keeps buttons visually consistent regardless of DPI or font size changes, without hardcoding pixel widths.

### 12. Lyrics path is session-only, not persisted
`S.lyrics_path` is not written to `SerializeSettings`. Reasoning: file paths are machine-specific and change frequently during authoring; persisting a stale path would cause confusing "file not found" errors on next open more often than it would save a click. Auto-detect (`lyrics.txt` in project folder) plus Browse cover the two main workflows without persistence.

### 13. Clear lyrics always operates on the whole take
`ClearLyricsAction` ignores time selection and always clears all lyric events from the take. Reasoning: lyric events for the ignored special game events (`[tambourine_start]` etc.) can live anywhere on the take; scoping to selection would require knowing their positions relative to the vocal notes. Clearing the whole take and reinserting is the simplest safe approach. The RB3 vocal range filter and `LYRIC_IGNORE` table together protect all non-lyric content.

### 14. `FormatTime` uses REAPER's own measure formatter
`r.format_timestr_pos(t, '', 1)` returns the project time in REAPER's measures/beats format (e.g. `"90.1.00"`). The measure number is parsed from the leading digits. This respects arbitrary tempo and time-signature changes in the project without needing to implement measure math manually. Falls back to plain `Xm SS.MMMsec` if parsing fails. Durations (range lengths) are left in plain seconds since they are not positions to navigate to.

---

## Conventions

### Naming
- Globals (capitalized): `S`, `DEFAULTS`, `TIPS`, mode constants `MODE_*`.
- Functions: `PascalCase` for actions and helpers (`Generate`, `ResolveTracks`, `AssignPitches`).
- Local variables: `snake_case` (`range_info`, `midi_take`, `ref_notes`).
- REAPER-API references: `local r = reaper` at the top, then `r.SomeFunction()` everywhere. Don't write `reaper.X` directly.

### State mutation
- The single source of mutable state is the `S` table.
- Sliders write directly to `S.field` via the `_, S.field = r.ImGui_SliderXxx(...)` pattern.
- Defaults live in `DEFAULTS`. Reset functions copy from there.
- Persisted-settings code lives together near the top so the serialization format is easy to inspect.

### Tooltips
- All tooltip text lives in the `TIPS` table at module level. UI code references `TIPS.foo` — never inlines text.
- New sliders need a TIPS entry. Use the `SliderTooltip` helper so the Ctrl+click hint is appended.
- Buttons use `Tooltip` (no hint).

### Result reporting
- Actions that succeed update `S.status` (one-line summary) and `S.last_result` (multi-line detail in `\n`-separated form).
- The UI renders `S.last_result` line by line under a separator. Empty lines render as `Spacing` for visual breaks.
- New stats lines: append to the `lines` table inside whatever Format function applies. Keep counts as bullet-style aligned text — see `FormatAutoTuneResult` for the column-aligned style we use for tabular output.

### Undo blocks
- Anything that modifies the project gets `Undo_BeginBlock` / `Undo_EndBlock` with a descriptive label that includes counts.
- Wrap with `PreventUIRefresh(1)` / `PreventUIRefresh(-1)` around the modification — REAPER batches the refresh and it's faster.

### Error handling
- Functions that can fail return `nil, error_string` (Lua idiom). Callers check `if not result then ... end`.
- Errors surface to the UI via `S.status = 'Error'` and `S.last_result = err`. Don't `error()` or `ShowMessageBox`.

### Lua specifics
- `reaper.new_array(n)` for sample buffers. Indices are 1-based.
- `MIDI_GetNote` returns `(ok, sel, mute, sppq, eppq, chan, pitch, vel)`. Use named locals.
- After `MIDI_DeleteNote`, indices of remaining notes shift — iterate **in reverse** when deleting.
- After `MIDI_InsertNote` / `SetNote` with `noSort=true`, call `MIDI_Sort` once at the end.
- `MIDI_CountEvts(take)` returns `(retval, notecnt, ccevtcnt, textsyxevtcnt)` — the **fourth** value is the text/sysex event count. The third is CC count, a common mistake.
- `MIDI_GetTextSysexEvt(take, i)` returns `(ok, sel, mute, ppq, type, msg)`. Type 5 = lyric event.
- `MIDI_InsertTextSysexEvt(take, sel, mute, ppq, type, text)` — use type 5 for lyrics.
- `MIDI_DeleteTextSysexEvt` shifts indices like `MIDI_DeleteNote` — always iterate in reverse.
- `format_timestr_pos(tpos, '', mode)` returns a formatted string. Mode 1 = measures/beats (e.g. `"90.1.00"`). Useful for display; parse the leading integer for the measure number.

---

## Known limitations and edge cases

These are documented for transparency, not necessarily things to fix. Several have been weighed and intentionally accepted.

1. **Auto-tune freezes the UI.** Single-threaded Lua. Typical 20–40 s sections run in a few seconds. A coroutine-based approach was explored but REAPER's audio accessor APIs (`GetAudioAccessorSamples`, `new_array`) do not work reliably when called from a Lua coroutine — they return nil, causing crashes. The freeze is considered acceptable for now given that auto-tune is used infrequently.

2. **`Apply pitch changes` uses note-start time only for matching.** If you've shifted notes around, a manually-placed note at time T will pull the pitch of whatever reference note is closest to T — even if that reference note "belongs" to a different syllable that you've moved. Fix would require a more sophisticated matching pass.

3. **Peak-split uses a global per-phrase peak.** A phrase with one loud syllable (0.8 RMS) and one quiet syllable (0.3) will lose the quiet one if split ratio is 50% (cut lands at 0.4, above the quiet syllable). Local peak picking would fix this; not done yet because in practice vocals stay within ~2× within a phrase.

4. **Single audio item per track.** Without a time selection, only the first item on the audio track is analyzed. With a time selection, the script picks the item that overlaps. Multi-item gluing is the user's responsibility.

5. **Reference MIDI alignment is the user's job.** No auto-alignment with the audio. If Basic Pitch's output is consistently early/late, the user nudges the MIDI item in REAPER or increases search tolerance.

6. **Track selections are not persisted.** Indices are positional, so saving them across sessions would be brittle. `GetTrackGUID` would solve it but adds complexity; not needed yet. Smart defaults (`SetDefaultTracks`) partially mitigate this for projects that follow the expected naming convention.

7. **YIN samples a fixed window at 30% into the note.** Works well for sustained vowels but may land on a consonant for very fast syllables. The 30% offset is a heuristic — it avoids the attack while staying well within the note.

---

## Common change patterns

### Adding a new detection slider

1. Add field to `DEFAULTS` and `S`.
2. Add to `ResetDetection`.
3. Add a TIPS entry.
4. Add to `SerializeSettings` / `DeserializeSettings` (use a new short key — don't reuse).
5. Add the slider in the UI loop within the Detection section, with `SliderTooltip(TIPS.foo)`.
6. Thread it through `RunDetection` / `GateAndSplit` / wherever it applies.
7. If auto-tune should consider it: add to `CANDIDATES_COARSE`, the `best` table, and a `SweepParam` call in both passes plus a `FineCandidates` call. Confirm the contour cache key still makes sense (only `window_ms` and `lpf_cutoff_hz` should be in the key — those are the only ones that change the contour itself).

### Adding a new pitch source

1. Add a new `MODE_*` constant.
2. Add a radio button in the Pitch section.
3. Add a TIPS entry.
4. Add a branch in `AssignPitches` for the new mode. Follow the YIN pattern: open any needed context before the loop, close it after (in the finally position), yield nil on error, fall back to Default pitch when detection produces no result.
5. If it needs additional inputs (a track, a slider), add them with the existing `BeginDisabled`/`EndDisabled` pattern so they grey out when not selected.
6. Update `Apply pitch changes` enable/disable logic if the mode should support it (currently only Single is excluded).
7. Update settings save/load if the new mode has persistent inputs.

### Adding a new action button

1. Write the action function. Follow the pattern: resolve tracks → resolve range → run pipeline → update `S.status` and `S.last_result`.
2. Add a TIPS entry.
3. Add the button in the actions area of the UI loop, with `Tooltip(TIPS.foo)` after.
4. Set the button width with `r.ImGui_CalcTextSize(ctx, label) + _bp` (compute it alongside the other `bw_*` locals near the top of the `if visible then` block).
5. Wrap mutating actions in `Undo_BeginBlock` / `Undo_EndBlock` with a descriptive label.

### Adding a new tooltip
- All tooltip text in `TIPS` table at the top. UI code references `TIPS.foo` only.
- Sliders use `SliderTooltip`; buttons use `Tooltip`. Don't mix them.

---

## Testing checklist

No test framework — REAPER scripts are tested by running them. Manual checks I'd run before committing significant changes:

- [ ] Script loads without errors when ReaImGui is missing (shows the message, returns cleanly).
- [ ] Sliders move; values reflect in detection.
- [ ] Generate works with no time selection (whole audio item).
- [ ] Generate works with a time selection (limited to selection).
- [ ] Re-running Generate over the same range doesn't stack duplicates.
- [ ] Generate respects the `Min offset` rule (visible in the MIDI editor as gaps).
- [ ] Auto-tune produces reasonable values for a section with hand-placed reference notes; result panel shows accuracy stats.
- [ ] Apply pitch changes preserves note positions and lengths but updates pitches.
- [ ] Apply pitch changes is disabled when Pitch source = Single.
- [ ] Apply pitch changes works with YIN mode (pitch detection runs against audio source track).
- [ ] YIN mode: Generate assigns non-default pitches for pitched vocal audio.
- [ ] YIN mode: notes where pitch is ambiguous fall back to the Default pitch without error.
- [ ] Save → modify sliders (including YIN params) → Load → all values restored.
- [ ] Reset Detection / Reset Pitch / Reset MIDI output return their respective sections to factory defaults without affecting others.
- [ ] Pitch range constraints octave-shift out-of-range notes back into range; clamp when range < 12 semitones.
- [ ] Reference MIDI mode reports `matched` and `fallback to default` counts correctly.
- [ ] Smart defaults: on a project with "VOCALS AUDIO" and "PART VOCALS" tracks, those are pre-selected on open.
- [ ] Project switch: switching REAPER tabs clears track selections, loads the new project's saved settings, and re-runs smart defaults.
- [ ] Undo button: disabled when nothing to undo; shows the operation label in tooltip; actually undoes the last action.
- [ ] Long files (full song) don't crash; auto-tune freeze is bearable.
- [ ] Lyrics — Auto-detect finds `lyrics.txt` in the project folder on script open and sets the path silently.
- [ ] Lyrics — Browse opens in the project folder; selecting a non-.txt file shows an error and does not set the path.
- [ ] Lyrics — Clear lyrics removes all type-5 events except the LYRIC_IGNORE entries; produces a correct undo entry.
- [ ] Lyrics — Assign lyrics with no time selection assigns to all vocal-range notes on the take.
- [ ] Lyrics — Assign lyrics with a time selection assigns only to notes within the selection.
- [ ] Lyrics — Assign lyrics clears existing lyrics first (including partial re-runs don't stack duplicates).
- [ ] Lyrics — Count mismatch warning appears correctly when notes > lyrics and lyrics > notes.
- [ ] Lyrics — Phrase capitalization check reports "none found" when no pitch-105 notes exist.
- [ ] Lyrics — Phrase capitalization check reports all violations with correct timestamps when first-phrase words are lowercase.
- [ ] Lyrics — Phrase capitalization check reports OK when all phrases start with uppercase.
- [ ] Lyrics — Assign lyrics is greyed out when no file is selected; becomes active after auto-detect or browse.
- [ ] Timestamps in result panel show measure number and correct mm:ss format for positions ≥ 60 s.

---

## Things on the radar

Not in scope right now but worth keeping in mind so we don't paint ourselves into a corner:

- **`_temp/` standalone scripts superseded.** `prepare_lyric_import.lua` and `import_lyrics_ignoring_comments.lua` are now replaced by the integrated Lyrics section. They can be kept for reference or deleted; they are no longer part of the workflow.

- **Coroutine-based auto-tune progress bar.** Would eliminate the UI freeze during parameter search. Blocked by REAPER API restriction: `GetAudioAccessorSamples` and `new_array` return nil when called from a Lua coroutine. Needs either a workaround (pre-compute contour before entering coroutine) or a different approach (incremental state machine in the main loop).
- **Multi-item audio support.** If the vocal stem is split into multiple items, currently only the first (or the overlapping one) is processed.
- **Reference MIDI auto-alignment.** Cross-correlating detected onsets with reference onsets to find a global offset, before per-note matching. Would make Reference mode more forgiving.
- **Local-peak-aware splitting.** Replacing the global-peak split rule with per-syllable local peaks for phrases with very uneven dynamics.
- **Persist track selections across sessions.** Use `GetTrackGUID` to store the selected tracks in project state. Smart defaults (`SetDefaultTracks`) partially cover this for standard project layouts.

- **Lyrics syllable hint (opt-in, advisory only).** After Assign lyrics, flag tokens that appear to contain multiple syllables without a hyphen — e.g. `"wonderful"` where the user likely meant `"won-"` + `"der-"` + `"ful"`. Reported as an advisory line in the result panel, never blocking. Key design notes:
  - **Algorithm.** Count vowel-letter groups per token (e.g. `"won"→[o]`, `"der"→[e]`, `"ful"→[u]` = 3 groups → warn). Strip a trailing silent `e` before counting (`"smiles"→"smils"→[i]` = 1 group → no false positive). Tokens that already contain a hyphen are skipped.
  - **Language behaviour.** Works best for Spanish, Italian, and Portuguese (highly regular vowel-to-syllable mapping, no silent letters). Works reasonably for English with the silent-e rule. Unreliable for French (pervasive silent letters). Irrelevant for Japanese/Korean/Chinese (non-Latin scripts or CV-pattern romaji). Because reliability is language-dependent, this should be **opt-in via a checkbox** (default off) labelled something like *"Syllable hint (best for Spanish/Italian/English)"* so users doing French or Japanese know they can ignore it.
  - **Threshold.** Only flag tokens with 3+ vowel groups (i.e. likely 3+ syllables) to reduce noise; 2-group words have higher false-positive rates (e.g. many common English monosyllables contain two vowel letters).
  - **State.** One boolean in `S` (e.g. `S.lyric_syllable_check`), saved with other settings. UI: checkbox in the Lyrics section alongside the file-selection controls.
  - **Open question before building.** Gather feedback from actual users on whether the false-positive rate at the 3-group threshold is tolerable. The count-mismatch warning already catches the most actionable problem (wrong total syllable count); this feature adds value only if users regularly forget to split individual multi-syllable words.

---

## Attempted approaches and what we learned

### Coroutine-based progress bar (attempted in v2.0, reverted)

**Goal.** Show a live progress bar and Cancel button during slow operations (audio analysis, auto-tune parameter sweep, YIN pitch detection on long files) without freezing the ImGui UI.

**What was built.** A generic coroutine architecture where each action (Preview, Generate, AutoTune, ApplyPitchChanges) created a `coroutine.create(...)` over its slow body. The Loop resumed the active coroutine once per frame via `coroutine.resume`, reading back `(pct, label)` yield values to update a `ProgressBar`. Slow functions yielded at natural checkpoints: `ComputeRMSContour` every 256-window chunk, `AssignPitches` (YIN) every 5 notes, `AutoTune`'s inner `Eval` after each parameter evaluation.

**Why it was reverted.** REAPER's C-extension APIs that create or access native resources do not work when called from a Lua coroutine (i.e., any coroutine other than the main thread). Specifically:
- `reaper.new_array(n)` returns `nil` inside a coroutine.
- `reaper.GetAudioAccessorSamples(...)` returns `nil` when called with a nil buffer (the consequence of `new_array` failing).
- The crash manifested as `attempt to compare nil with number` at `if ret < 0 then break end` in `ComputeRMSContour` (line ~819).

Lua coroutines are cooperative (not real OS threads), so this is a REAPER-side restriction — the C extension apparently checks that it is executing on the main coroutine stack.

**What does work in coroutines.** Pure Lua computation with no REAPER native-resource calls is fine. `GateAndSplit`, `ApplyMinOffset`, and the non-YIN branch of `AssignPitches` all worked correctly inside a coroutine. YIN's inner math loop also works; the issue was only in the `new_array` / `GetAudioAccessorSamples` calls inside `OpenYINContext` / `DetectPitchYIN`.

**Secondary bug found during this work.** `ImGui_BeginDisabled` / `ImGui_EndDisabled` must be balanced within a single frame. When `S.busy` was `false` at the top of the actions row (so `BeginDisabled` was not called) but a button click set `S.busy = true` mid-frame (before the matching `EndDisabled` check), the `EndDisabled` fired without a paired `BeginDisabled`, crashing with `ImGui_EndDisabled: Calling EndDisabled() too many times!`. Fix: snapshot `local is_busy = S.busy` once before any `BeginDisabled` / `EndDisabled` guards, and use `is_busy` throughout — `S.busy` may only be used for checks that have no paired call (e.g., the progress bar visibility check). This fix is present in v1.9.

**Viable path forward (if revisited).** Three options, in order of difficulty:
1. **Pre-compute the contour in the main thread, then enter the coroutine.** `ComputeRMSContour` runs synchronously (fast — C-side REAPER), result is passed into the coroutine. The coroutine then handles GateAndSplit + AssignPitches (YIN), which are pure Lua and safe. No progress bar for audio analysis, but that part is fast anyway. The real freeze is either YIN over a full song or the auto-tune sweep.
2. **Incremental state machine in Loop.** No coroutines at all. Actions set a `S.pending_op` table with parameters and current progress state. Loop advances the computation by one step per frame (e.g., one contour chunk, one note's YIN analysis) and re-defers. More complex state management but no coroutine restrictions.
3. **Background thread via an external tool.** Not practical in standard REAPER Lua.

---

## Glossary

- **Stem** — an isolated track from a mix (vocal stem = vocals only, separated from the rest by an AI tool).
- **RMS** — root mean square of the signal in a window; perceived loudness proxy.
- **Phrase** (this script's terminology) — a contiguous region of contour above the absolute threshold. May be split into multiple notes by peak-split.
- **PPQ** — REAPER's MIDI tick unit. Convert to/from project time with `MIDI_GetPPQPosFromProjTime` / `MIDI_GetProjTimeFromPPQPos`.
- **Take** — a recording or MIDI clip inside a media item. We use the active take of MIDI items for note operations.
- **Audio accessor** — REAPER API for reading PCM samples from a take. Created with `CreateTakeAudioAccessor`, freed with `DestroyAudioAccessor`. Always free it.
- **YIN** — a monophonic pitch detection algorithm based on the cumulative mean normalized difference function (CMND). Finds the fundamental frequency by searching for the period (lag) that minimizes the difference function, with parabolic interpolation for sub-sample precision.
