# Karaoke MIDI Generator

A REAPER ReaScript that analyses a vocal audio track and generates MIDI notes aligned to the syllables and phrases it detects. Designed for authoring timing data for rhythm/karaoke games.

---

## Requirements

- [REAPER](https://www.reaper.fm/) (any recent version)
- [ReaImGui](https://forum.cockos.com/showthread.php?t=250419) extension — install via **Extensions → ReaPack → Browse packages**, search for `ReaImGui`

---

## Installation

1. Download `vocal_midi_generator_vkr.lua` and place it anywhere REAPER can find scripts (e.g. your REAPER Scripts folder).
2. In REAPER: **Actions → Show action list → Load ReaScript** and select the file.
3. Optionally assign the action to a toolbar button or keyboard shortcut.

---

## Quick start

1. Open a REAPER project containing a vocal stem on one track and a destination track with a MIDI item on it.
2. Run the script. The script window opens and attempts to auto-select the right tracks (it looks for tracks named `VOCALS AUDIO` / `DRYVOX1` for audio and `PART VOCALS` for MIDI destination).
3. Confirm the track selections in the dropdowns if needed.
4. Click **Dry run** to see how many notes would be detected with the current settings.
5. Click **Generate notes (append)** to write the notes into your MIDI item.

---

## UI overview

<!-- Screenshot placeholder: full script window -->

The window is divided into four main sections:

| Section | Purpose |
|---|---|
| Track selection | Choose audio source, MIDI destination, and (optionally) reference MIDI track |
| Note Detection | Sliders that control when and how syllables are detected |
| Pitch source | Choose how MIDI pitch is assigned to each detected note |
| MIDI output | Velocity slider, action buttons, result panel |

---

## Workflow

### Step 1 — Set up your tracks

You need two tracks before running the script:

- **Audio source track** — contains the vocal stem (an isolated vocals-only audio file, e.g. from an AI stem separator like Demucs or UVR).
- **MIDI destination track** — contains a MIDI item that spans the region you want to work on. The script writes into this existing item; it will not create a new one.

Optionally, a third **Reference MIDI track** is needed if you use the Reference MIDI pitch source.

### Step 2 — (Optional) Make a time selection

If you only want to process part of the song, make a time selection in REAPER before running any action. The script respects the time selection for all operations: detection, auto-tune, and apply pitch changes.

Without a time selection, the full audio item is analysed.

### Step 3 — Tune the Detection settings

<!-- Screenshot placeholder: Detection section sliders -->

The Detection sliders control the audio energy analysis. Start with defaults and adjust based on what Dry run reports.

| Slider | Range | Default | What to adjust |
|---|---|---|---|
| **RMS threshold** | 0.001 – 0.5 | 0.05 | Lower if quiet phrases are missed; raise if noise/breath triggers too many notes. |
| **Low-pass cutoff** | 0 – 8000 Hz (0 = off) | Off | Set to ~1500–2500 Hz to make sibilants (S, F, SH) invisible to the detector, so note starts snap to the vowel. |
| **Peak-split ratio** | 0 – 95% (0 = off) | Off | When phrases contain multiple syllables without dropping to silence, this splits them. Start around 40–60% and adjust. |
| **Min offset to next note** | 0 – 500 ms | 100 ms | Enforces a minimum gap between notes by trimming end times. Prevents notes from running into each other. |
| **Min note length** | 10 – 500 ms | 60 ms | Discards very short detections (breath noise, consonants). Raise to filter out more. |
| **RMS window** | 5 – 100 ms | 25 ms | Time resolution of the analysis. Smaller = more precise timing but slower. Rarely needs changing. |

> **Tip:** All sliders support Ctrl+click to type an exact value.

### Step 4 — Choose a Pitch source

<!-- Screenshot placeholder: Pitch source section -->

Select how MIDI pitch is assigned to each detected note:

#### Single pitch
Every note is assigned the same pitch (the **Default pitch** slider). Use this when pitch doesn't matter yet — you just want timing data — or when your game engine uses a single note row for vocals.

#### Reference MIDI
Pitch is taken from an existing MIDI track. For each detected note, the script finds the nearest MIDI note on the reference track (within the **Search tolerance** window) and uses that pitch. Falls back to Default pitch when nothing is within range.

This works well with MIDI output from AI pitch tools like [Basic Pitch](https://basicpitch.spotify.com/). Import the AI MIDI output onto the reference track, then use this mode to transfer those pitches onto your timing-detected notes.

#### Built-in detection (YIN)
The script analyses the audio directly using the [YIN algorithm](http://audition.ens.fr/adc/pdf/2002_JASA_YIN.pdf) to estimate the fundamental frequency of each note. No external MIDI reference needed.

| Slider | Range | Default | Notes |
|---|---|---|---|
| **YIN threshold** | 0.01 – 0.5 | 0.15 | Confidence cutoff. Lower = stricter (more fallbacks to Default pitch). Higher = more detections but more octave errors. |
| **Min frequency** | 40 – 400 Hz | 80 Hz | Set to just below the lowest note in the vocal. |
| **Max frequency** | 200 – 2000 Hz | 1000 Hz | Set to just above the highest note. |
| **YIN window** | 10 – 100 ms | 30 ms | Audio length analysed per note. Longer is more stable but may miss very short notes. |

The algorithm samples audio starting at 30% into each note (to avoid the attack transient and land on the steady-state vowel). Notes where no confident pitch is found fall back to Default pitch.

#### Pitch range constraints (min / max)

Two optional checkbox+slider pairs clamp or octave-shift pitches into a target range. When a detected pitch is outside the range, the script first tries octave-shifting it back in (±12 semitones, up to 16 attempts), then falls back to clamping. Useful for correcting octave errors from AI stem separation.

### Step 5 — Dry run and Generate

<!-- Screenshot placeholder: action buttons and result panel -->

- **Dry run** — runs the full detection and pitch assignment pipeline but does not write anything to REAPER. Reports how many notes were found, how many pitches were matched or fell back to default, etc.
- **Generate notes (append)** — writes notes into the destination MIDI item. Before inserting, it clears any existing notes at the pitches it is about to write (within the analysis range), so re-running is safe and does not stack duplicates.

The result panel below the buttons shows counts for the last action.

---

## Auto-tune from reference

<!-- Screenshot placeholder: Auto-tune button and result panel -->

Auto-tune automates the process of finding Detection slider values that reproduce a set of manually-placed timing reference notes.

**How to use it:**

1. Manually place a handful of MIDI notes on the destination track at the Default pitch. These represent the "correct" timing you want the detector to match.
2. Make a time selection covering those reference notes.
3. Click **Auto-tune from reference**.

The script runs a coordinate descent search over the five detection parameters (RMS threshold, Low-pass cutoff, Peak-split ratio, Min offset, Min note length). It does not change pitch settings or RMS window. When it finishes, the sliders update to the best-found values and the result panel shows accuracy statistics.

> **Note:** Auto-tune can take several seconds for longer sections. The UI will be unresponsive during the search — this is expected.

---

## Apply pitch changes

**Apply pitch changes** reassigns the pitches of existing notes on the destination track without altering their position or length. Use this when:

- You've manually adjusted note timing and now want to add pitch information.
- You want to re-pitch notes after changing the Pitch source settings without re-running detection.

The button is disabled when Pitch source is set to Single pitch (it would just overwrite every note with the same pitch, which is not useful).

---

## Undo

The **Undo** button directly calls REAPER's undo. It exists because the ImGui window captures keyboard focus, so REAPER's own Ctrl+Z shortcut does not fire while the script window is active. The button is disabled when there is nothing to undo, and the tooltip shows the label of the operation that will be undone.

---

## Save and Load

Settings are saved per-project using REAPER's project state. Click **Save** to store the current Detection and Pitch settings. Click **Load** to restore them.

Settings are loaded automatically when the script opens (if a save exists for the current project) and when you switch REAPER project tabs.

**What is saved:** all Detection sliders, Pitch source selection and all pitch settings (including YIN parameters), Velocity.

**What is not saved:** track selections. If your project follows the naming convention (`VOCALS AUDIO`, `PART VOCALS`) the script will re-select the right tracks automatically.

---

## Tips

- **Start with Single pitch mode** to get the timing right first, then switch to a pitch source and use Apply pitch changes to add pitch data without re-running detection.
- **Use a time selection to work section by section.** Chorus and verse may need different threshold settings. Generate into the same MIDI item repeatedly; each run only touches notes at the pitches it produces.
- **Low-pass cutoff makes a big difference** for sibilant-heavy vocals. If note starts consistently land on the consonant instead of the vowel, enable the low-pass filter around 1500–2000 Hz.
- **Reference MIDI mode + Basic Pitch** is a good combination: Basic Pitch provides reasonable pitch estimates that you can refine with the pitch range constraints, while the script provides tighter timing than Basic Pitch alone.
- **Auto-tune works best with 10–30 representative reference notes** covering the range of dynamics in the section.

---

## License

MIT — see [LICENSE](LICENSE).
