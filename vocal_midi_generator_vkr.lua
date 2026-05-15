-- @description Vocal MIDI Generator
-- @author VeeKiraRay
-- @version 1.5
-- @about
--   Analyses a vocal audio track and appends MIDI notes to an existing MIDI
--   item on a destination track, one note per detected syllable or phrase.
--   Supports two pitch correction sources: reference MIDI and built-in YIN
--   monophonic pitch detection. Includes Auto-tune to fit detection
--   parameters to manually-placed reference timing notes.
--
--   Built with Claude (Anthropic) — https://claude.ai
--
--   v1.5
--     - Generate (replace): new button clears all vocal-range notes in the
--       analysis range before inserting, producing a clean result. Phrase
--       markers at other pitches are preserved.
--     - Generate (append) renamed from "Generate notes (append)".
--     - Pitch name display now uses Rock Band octave numbering (C1=36).
--     - Generate and Dry run always assign a fixed pitch (Default pitch
--       slider, now on the Note Placement tab). Pitch tab is now exclusively
--       for Apply pitch changes: only Built-in detection and Reference MIDI
--       remain; Single pitch mode removed; YIN is the new default.
--       Apply pitch changes is always enabled.
--     - Validation tab renamed to Pitch slide. YIN threshold and frequency
--       sliders added alongside Slide Scan controls so the full pitch slide
--       workflow is contained in one tab.
--
--   v1.4
--     - Slide Scan sliders added to the Validation tab: all five scan
--       parameters (min note length, min segment, edge skip, sample step,
--       sample window) are now adjustable and persisted with project settings.
--
--   v1.3
--     - Tab-based UI: reorganised into 5 tabs (General, Note Placement,
--       Pitch, Lyrics, Validation). Track selectors and status/results panel
--       remain global above and below the tab bar.
--     - MIDI destination track selector now appears before Audio source.
--     - "Note Detection" section renamed to "Note Placement".
--
--   v1.2
--     - Added Scan pitch slides: scans existing MIDI notes and reports any
--       where pitch moves significantly during the note (Slide up/down,
--       Scoop, Bend, Complex slide). Read-only; respects time selection.
--       Includes lyric text in the report when present.
--
--   v1.1
--     - Added Auto-tune YIN from reference: sweeps YIN parameters
--       (threshold, frequency range, window) against manually corrected
--       pitches to find the best-fit settings automatically.
--     - Fixed Assign lyrics to always operate on the whole MIDI take,
--       ignoring any time selection (required for correct word-to-note order).
--
--   Workflow:
--     1. Pick the audio source track and the MIDI destination track.
--        The destination track must contain a MIDI item that covers the range.
--     2. (Optional) Make a time selection to restrict analysis.
--     3. Configure detection settings; pick a Pitch source.
--     4. Dry run to check counts, Auto-tune to fit reference timing notes,
--        Generate to write into the destination MIDI item.
--     5. Or, if you've already tweaked the notes manually and just want to add
--        pitch info, use Apply pitch changes.

local r = reaper

if not r.ImGui_CreateContext then
    r.ShowMessageBox(
        "This script requires the ReaImGui extension.\n\n" ..
        "Install it via Extensions > ReaPack > Browse packages,\n" ..
        "then search for 'ReaImGui' and install it.",
        "Missing dependency", 0
    )
    return
end

if not r.ImGui_BeginDisabled then
    r.ShowMessageBox(
        "This script requires ReaImGui 0.7 or later.\n\n" ..
        "Update it via Extensions > ReaPack > Browse packages,\n" ..
        "then search for 'ReaImGui' and update.",
        "ReaImGui version too old", 0
    )
    return
end

local ctx = r.ImGui_CreateContext('Vocal MIDI Generator')

----------------------------------------------------------------------
-- Pitch source modes
----------------------------------------------------------------------
local MODE_SINGLE    = 0
local MODE_REFERENCE = 1
local MODE_YIN       = 2

-- Rock Band 3 vocal note range. Notes outside this are phrase/overdrive markers.
local RB3_MIN_PITCH    = 36   -- C1
local RB3_MAX_PITCH    = 84   -- C5
local RB3_PHRASE_PITCH = 105  -- phrase/overdrive marker pitch

-- Lyric text events that Clear and Assign both preserve (special game events).
local LYRIC_IGNORE = {
    ['[tambourine_start]'] = true, ['[tambourine_end]'] = true,
    ['[cowbell_start]']    = true, ['[cowbell_end]']    = true,
    ['[clap_start]']       = true, ['[clap_end]']       = true,
}

-- Suppress the Browse tooltip after a click until the mouse leaves the button;
-- native file dialogs open on top but the ImGui tooltip persists otherwise.
local _browse_tooltip_suppressed = false

----------------------------------------------------------------------
-- Defaults & state
----------------------------------------------------------------------
local DEFAULTS = {
    rms_threshold     = 0.05,
    min_offset_ms     = 100,
    min_note_ms       = 60,
    window_ms         = 25,
    lpf_cutoff_hz     = 0,
    split_ratio       = 0,

    pitch_mode        = MODE_YIN,
    pitch             = 60,
    ref_search_ms     = 500,
    min_pitch_enabled = false,
    min_pitch         = 48,
    max_pitch_enabled = false,
    max_pitch         = 72,

    yin_threshold     = 0.15,
    yin_min_freq      = 80,
    yin_max_freq      = 1000,
    yin_window_ms     = 30,

    velocity          = 100,

    slide_min_note_ms = 200,
    slide_min_seg_ms  = 50,
    slide_skip_ms     = 20,
    slide_step_ms     = 20,
    slide_win_ms      = 20,
}

local S = {
    audio_idx         = 0,
    midi_idx          = 0,
    ref_idx           = 0,
    lyrics_path       = '',  -- not persisted; auto-detected on open/project switch

    rms_threshold     = DEFAULTS.rms_threshold,
    min_offset_ms     = DEFAULTS.min_offset_ms,
    min_note_ms       = DEFAULTS.min_note_ms,
    window_ms         = DEFAULTS.window_ms,
    lpf_cutoff_hz     = DEFAULTS.lpf_cutoff_hz,
    split_ratio       = DEFAULTS.split_ratio,

    pitch_mode        = DEFAULTS.pitch_mode,
    pitch             = DEFAULTS.pitch,
    ref_search_ms     = DEFAULTS.ref_search_ms,
    min_pitch_enabled = DEFAULTS.min_pitch_enabled,
    min_pitch         = DEFAULTS.min_pitch,
    max_pitch_enabled = DEFAULTS.max_pitch_enabled,
    max_pitch         = DEFAULTS.max_pitch,

    yin_threshold     = DEFAULTS.yin_threshold,
    yin_min_freq      = DEFAULTS.yin_min_freq,
    yin_max_freq      = DEFAULTS.yin_max_freq,
    yin_window_ms     = DEFAULTS.yin_window_ms,

    velocity          = DEFAULTS.velocity,

    slide_min_note_ms = DEFAULTS.slide_min_note_ms,
    slide_min_seg_ms  = DEFAULTS.slide_min_seg_ms,
    slide_skip_ms     = DEFAULTS.slide_skip_ms,
    slide_step_ms     = DEFAULTS.slide_step_ms,
    slide_win_ms      = DEFAULTS.slide_win_ms,

    status            = 'Ready.',
    last_result       = nil,
}

local function ResetDetection()
    S.rms_threshold = DEFAULTS.rms_threshold
    S.min_offset_ms = DEFAULTS.min_offset_ms
    S.min_note_ms   = DEFAULTS.min_note_ms
    S.window_ms     = DEFAULTS.window_ms
    S.lpf_cutoff_hz = DEFAULTS.lpf_cutoff_hz
    S.split_ratio   = DEFAULTS.split_ratio
end

local function ResetPitch()
    S.pitch_mode        = DEFAULTS.pitch_mode
    S.pitch             = DEFAULTS.pitch
    S.ref_search_ms     = DEFAULTS.ref_search_ms
    S.min_pitch_enabled = DEFAULTS.min_pitch_enabled
    S.min_pitch         = DEFAULTS.min_pitch
    S.max_pitch_enabled = DEFAULTS.max_pitch_enabled
    S.max_pitch         = DEFAULTS.max_pitch
    S.yin_threshold     = DEFAULTS.yin_threshold
    S.yin_min_freq      = DEFAULTS.yin_min_freq
    S.yin_max_freq      = DEFAULTS.yin_max_freq
    S.yin_window_ms     = DEFAULTS.yin_window_ms
end

local function ResetMIDIOutput()
    S.velocity = DEFAULTS.velocity
end

local function ResetSlides()
    S.slide_min_note_ms = DEFAULTS.slide_min_note_ms
    S.slide_min_seg_ms  = DEFAULTS.slide_min_seg_ms
    S.slide_skip_ms     = DEFAULTS.slide_skip_ms
    S.slide_step_ms     = DEFAULTS.slide_step_ms
    S.slide_win_ms      = DEFAULTS.slide_win_ms
end

local function ResetYIN()
    S.yin_threshold = DEFAULTS.yin_threshold
    S.yin_min_freq  = DEFAULTS.yin_min_freq
    S.yin_max_freq  = DEFAULTS.yin_max_freq
    S.yin_window_ms = DEFAULTS.yin_window_ms
end

----------------------------------------------------------------------
-- Settings save/load (project state)
----------------------------------------------------------------------
local PROJ_KEY_SECTION = 'VocalMIDIGenVKR'
local PROJ_KEY_NAME    = 'settings_v1'

local function bool_to_num(b) return b and 1 or 0 end
local function num_to_bool(n) return (tonumber(n) or 0) ~= 0 end

local function SerializeSettings()
    return ('rms=%.6f;lpf=%.2f;split=%.2f;offset=%.2f;minnote=%.2f;window=%.2f;' ..
            'pmode=%d;pitch=%d;reftol=%.0f;' ..
            'minpe=%d;minp=%d;maxpe=%d;maxp=%d;vel=%d;' ..
            'yt=%.3f;ymn=%.0f;ymx=%.0f;yw=%.0f;' ..
            'sl_mn=%d;sl_ms=%d;sl_sk=%d;sl_st=%d;sl_wn=%d')
        :format(S.rms_threshold, S.lpf_cutoff_hz, S.split_ratio,
                S.min_offset_ms, S.min_note_ms, S.window_ms,
                S.pitch_mode, math.floor(S.pitch + 0.5), S.ref_search_ms,
                bool_to_num(S.min_pitch_enabled),
                math.floor(S.min_pitch + 0.5),
                bool_to_num(S.max_pitch_enabled),
                math.floor(S.max_pitch + 0.5),
                math.floor(S.velocity + 0.5),
                S.yin_threshold, S.yin_min_freq, S.yin_max_freq, S.yin_window_ms,
                S.slide_min_note_ms, S.slide_min_seg_ms, S.slide_skip_ms,
                S.slide_step_ms, S.slide_win_ms)
end

local function DeserializeSettings(str)
    local tmp = {}
    for k, v in str:gmatch('([%w]+)=([^;]+)') do
        tmp[k] = tonumber(v)
    end
    if tmp.rms     then S.rms_threshold     = tmp.rms     end
    if tmp.lpf     then S.lpf_cutoff_hz     = tmp.lpf     end
    if tmp.split   then S.split_ratio       = tmp.split   end
    if tmp.offset  then S.min_offset_ms     = tmp.offset  end
    if tmp.minnote then S.min_note_ms       = tmp.minnote end
    if tmp.window  then S.window_ms         = tmp.window  end
    if tmp.pmode   then S.pitch_mode        = tmp.pmode   end
    if S.pitch_mode == MODE_SINGLE then S.pitch_mode = DEFAULTS.pitch_mode end
    if tmp.pitch   then S.pitch             = math.floor(tmp.pitch + 0.5) end
    if tmp.reftol  then S.ref_search_ms     = tmp.reftol  end
    if tmp.minpe   then S.min_pitch_enabled = num_to_bool(tmp.minpe) end
    if tmp.minp    then S.min_pitch         = math.floor(tmp.minp + 0.5) end
    if tmp.maxpe   then S.max_pitch_enabled = num_to_bool(tmp.maxpe) end
    if tmp.maxp    then S.max_pitch         = math.floor(tmp.maxp + 0.5) end
    if tmp.vel     then S.velocity          = math.floor(tmp.vel + 0.5)  end
    if tmp.yt      then S.yin_threshold     = tmp.yt                     end
    if tmp.ymn     then S.yin_min_freq      = math.floor(tmp.ymn + 0.5) end
    if tmp.ymx     then S.yin_max_freq      = math.floor(tmp.ymx + 0.5) end
    if tmp.yw      then S.yin_window_ms     = tmp.yw                     end
    if tmp.sl_mn   then S.slide_min_note_ms = math.floor(tmp.sl_mn + 0.5) end
    if tmp.sl_ms   then S.slide_min_seg_ms  = math.floor(tmp.sl_ms + 0.5) end
    if tmp.sl_sk   then S.slide_skip_ms     = math.floor(tmp.sl_sk + 0.5) end
    if tmp.sl_st   then S.slide_step_ms     = math.floor(tmp.sl_st + 0.5) end
    if tmp.sl_wn   then S.slide_win_ms      = math.floor(tmp.sl_wn + 0.5) end
end

local function SaveSettings()
    r.SetProjExtState(0, PROJ_KEY_SECTION, PROJ_KEY_NAME, SerializeSettings())
    r.MarkProjectDirty(0)
end

local function LoadSettings()
    local _, str = r.GetProjExtState(0, PROJ_KEY_SECTION, PROJ_KEY_NAME)
    if str and str ~= '' then
        DeserializeSettings(str)
        return true
    end
    return false
end

local _autoloaded = LoadSettings()
if _autoloaded then S.status = 'Loaded saved settings.' end

----------------------------------------------------------------------
-- Tooltip text
----------------------------------------------------------------------
local CTRL_CLICK_HINT = "\n\nTip: Ctrl+click the slider to type an exact value."

local TIPS = {
    rms_threshold =
        "Audio level (0..1) above which a note starts.\n\n" ..
        "LOWER -> more sensitive, picks up quiet phrases. Too low triggers " ..
        "on breath, room noise, and bleed -> way too many notes.\n\n" ..
        "HIGHER -> ignores quiet material. Too high misses real phrases.\n\n" ..
        "Start around 0.05 for clean stems; try 0.01-0.03 for quieter sources.\n\n" ..
        "Note: enabling Low-pass cutoff lowers the overall RMS values, so you " ..
        "may need to lower this threshold to compensate.",

    lpf_cutoff =
        "Low-pass filter applied to the audio before energy detection.\n\n" ..
        "Cuts high frequencies so sibilants ('s', 'sh', 'f', 'th') become " ..
        "nearly invisible to the detector — note starts snap to the vowel " ..
        "instead of the leading consonant.\n\n" ..
        "LOWER cutoff (~800 Hz) -> stronger sibilant rejection but may also " ..
        "smooth other transients and slightly delay note starts.\n\n" ..
        "HIGHER cutoff (~4000 Hz) -> mild rejection, less impact on timing.\n\n" ..
        "0 = Off (no filtering). 1500-2500 Hz is a good range for vocals.\n\n" ..
        "Filtering reduces the audio's overall RMS, so re-tune the threshold " ..
        "after enabling.",

    split_ratio =
        "Peak-relative threshold for splitting a single detection into " ..
        "multiple notes.\n\n" ..
        "After a phrase is detected, its loudest point is found. If the " ..
        "RMS contour inside the phrase dips below this percentage of that " ..
        "peak, the phrase is split there. Useful for fast syllables sung " ..
        "together that don't drop below the absolute threshold.\n\n" ..
        "0%% = Off (use absolute threshold only).\n" ..
        "~50%% = moderate splitting.\n" ..
        "HIGHER -> more aggressive splitting; risk of over-splitting steady " ..
        "vowels into many small notes.",

    min_offset_ms =
        "Forces a minimum gap before the next detected note.\n\n" ..
        "If a note's natural end would land closer than this to the next " ..
        "note, it is cut short to enforce the gap.\n\n" ..
        "HIGHER -> cleaner separation but shortens many notes; very short " ..
        "notes can disappear (see 'Dropped' count in the result).\n\n" ..
        "LOWER -> notes can run right up to the next one (no enforced gap).",

    min_note_ms =
        "Notes shorter than this are discarded after detection.\n\n" ..
        "Filters out clicks, lip noise, and brief transients that aren't " ..
        "real syllables.\n\n" ..
        "TOO LOW -> junk gets through.\n" ..
        "TOO HIGH -> real short syllables get dropped.",

    window_ms =
        "Analysis resolution: how often RMS is measured.\n\n" ..
        "SMALLER -> more precise note start/end times, but slower analysis.\n\n" ..
        "LARGER -> smoother, faster, less precise edges.\n\n" ..
        "20-30ms is a sweet spot for vocals.\n\n" ..
        "Note: this is NOT changed by Auto-tune.",

    pitch_mode_single =
        "Every generated note gets the same pitch (the Default pitch slider " ..
        "below). Pick a pitch that doesn't already have notes in the " ..
        "destination MIDI item, so reference notes at other pitches are " ..
        "preserved when you regenerate.",

    pitch_mode_reference =
        "For each generated note, look at a separate MIDI track and copy " ..
        "the pitch of the nearest reference note (by start time) within " ..
        "the configured Search tolerance. If nothing is in range, use the " ..
        "Default pitch.\n\n" ..
        "It's up to you to align the reference MIDI item to the song. " ..
        "Generate it externally with Basic Pitch / Melodyne / etc., import, " ..
        "and shift/stretch as needed.",

    pitch_mode_yin =
        "Built-in monophonic pitch detection using the YIN algorithm.\n\n" ..
        "Analyses the audio from the source track directly to estimate the " ..
        "fundamental frequency of each note — no external MIDI reference needed.\n\n" ..
        "Adjust the YIN threshold and frequency range to suit the source. " ..
        "Notes where pitch cannot be reliably detected fall back to the Default pitch.\n\n" ..
        "Works best on clean, dry vocal stems.",

    yin_threshold =
        "Confidence threshold for YIN pitch detection (0.01 - 0.5).\n\n" ..
        "YIN measures aperiodicity: 0 = perfectly periodic, 1 = no periodicity.\n\n" ..
        "LOWER -> stricter; only confident detections accepted. More notes " ..
        "fall back to Default pitch in noisy or consonant-heavy regions.\n" ..
        "HIGHER -> more permissive; detects more notes but may pick wrong " ..
        "pitches on breaths or fricatives.\n\n" ..
        "0.10 - 0.20 works well for clean vocal stems.",

    yin_min_freq =
        "Lowest pitch frequency to detect (Hz).\n\n" ..
        "Set near the lowest note expected in the vocal part.\n" ..
        "Typical male bass: ~80 Hz (E2). Typical tenor: ~130 Hz (C3).\n\n" ..
        "Must be lower than Max frequency. Wider range = slightly slower analysis.",

    yin_max_freq =
        "Highest pitch frequency to detect (Hz).\n\n" ..
        "Set near the highest note expected in the vocal part.\n" ..
        "Typical soprano: ~1000 Hz (B5). Most pop vocals stay under 800 Hz.\n\n" ..
        "Must be higher than Min frequency.",

    yin_window_ms =
        "Length of the audio window analysed per note for pitch detection (ms).\n\n" ..
        "YIN reads this many milliseconds from around 30%% into each note " ..
        "to find the steady-state vowel region.\n\n" ..
        "LONGER -> more stable estimate; requires a note at least this long.\n" ..
        "SHORTER -> works on short notes but may be noisier.\n\n" ..
        "30 ms is a good default for most vocals.",

    pitch =
        "Pitch assigned to all notes by Generate and Dry run.\n\n" ..
        "Also used as the fallback when Reference MIDI or Built-in detection " ..
        "cannot find a pitch for a note.\n\n" ..
        "Set this on the Note Placement tab.",

    ref_track =
        "MIDI track containing reference notes whose pitches will be copied " ..
        "into the generated notes. The track may contain one or more MIDI " ..
        "items; all notes inside the analysis range are considered.\n\n" ..
        "Only used when Pitch source is set to 'Reference MIDI'.",

    ref_search =
        "How far (in either direction from a note's start) to search for the " ..
        "nearest reference note. If nothing is found inside this window, the " ..
        "note gets the Default pitch instead.\n\n" ..
        "HIGHER -> more permissive; reference timing can be sloppy.\n" ..
        "LOWER -> stricter; missing reference notes default more often.\n\n" ..
        "500 ms is a reasonable starting point.",

    min_pitch_enabled =
        "Constrain notes to be at or above this pitch.\n\n" ..
        "Useful for fixing octave-error artifacts from stem separation: " ..
        "weird low octaves get shifted up by 12 semitones until they're " ..
        "in range.\n\n" ..
        "Disable if you don't want any minimum.",

    max_pitch_enabled =
        "Constrain notes to be at or below this pitch.\n\n" ..
        "Useful for fixing octave-error artifacts: weird high octaves " ..
        "get shifted down by 12 semitones until they're in range.\n\n" ..
        "Disable if you don't want any maximum.",

    min_pitch =
        "Lowest allowed pitch.\n\n" ..
        "Notes below this are octave-shifted up until they fit. If the " ..
        "range is narrower than an octave, they clamp to this value.",

    max_pitch =
        "Highest allowed pitch.\n\n" ..
        "Notes above this are octave-shifted down until they fit. If the " ..
        "range is narrower than an octave, they clamp to this value.",

    velocity =
        "MIDI velocity (1..127) for every generated note. Affects how loud " ..
        "notes play in your sampler / synth. Has no effect on detection.",

    reset_detection = "Reset all Note Placement sliders to factory defaults.",
    reset_pitch     = "Reset all Pitch settings to factory defaults.",
    reset_midi      = "Reset MIDI output sliders to factory defaults.",

    save_settings =
        "Save the current Detection, Pitch, and Velocity values into the " ..
        "project file. They'll be auto-loaded next time the script is " ..
        "opened in this project.\n\n" ..
        "Track selections (audio / MIDI dest / reference MIDI) are NOT saved.",

    load_settings =
        "Reload the most recently saved values from the project file.",

    preview =
        "Run detection only and show stats, without writing any notes.",

    generate =
        "Run detection and append the resulting notes to the existing MIDI " ..
        "item on the destination track. First clears existing notes at every " ..
        "pitch the new run will produce (plus the Default pitch), so re-running " ..
        "over the same range does not stack duplicates.",

    generate_replace =
        "Run detection and replace all existing notes in the analysis range " ..
        "(vocal pitch range only — phrase markers at other pitches are preserved). " ..
        "Produces a clean result with no leftover notes from previous runs.",

    autotune =
        "Find detection settings that best match reference notes you've " ..
        "manually placed.\n\n" ..
        "Prerequisites:\n" ..
        " - Make a time selection covering a section of the song.\n" ..
        " - Place reference notes at the Default pitch in that range.\n\n" ..
        "Tunes RMS threshold, low-pass, split ratio, min offset, and min " ..
        "note. Does NOT change Pitch settings or RMS window.\n\n" ..
        "Use 'Save' first if you want to be able to return to your " ..
        "current values via 'Load'.",

    apply_pitch =
        "Reassign pitches of existing notes on the destination MIDI item " ..
        "without changing their position or length.\n\n" ..
        "Use this when you've already done timing work (manual placement, " ..
        "splitting, length tweaks) and just want to apply pitch information.\n\n" ..
        "Scope:\n" ..
        " - With time selection: processes notes within the selection.\n" ..
        " - Without time selection: processes all notes on the destination " ..
        "MIDI item.\n\n" ..
        "Each existing note gets a new pitch via the configured Pitch source. " ..
        "Pitch range constraints are applied. Velocity, position, and length " ..
        "are preserved.",

    apply_pitch_disabled =
        "Apply pitch changes is only available when Pitch source is set to " ..
        "'Reference MIDI' or 'Built-in detection'. In Single " ..
        "pitch mode, this would overwrite every note with the same pitch.",

    autotune_yin =
        "Find YIN settings that best match notes whose pitches you have\n" ..
        "already corrected manually.\n\n" ..
        "Prerequisites:\n" ..
        " - Make a time selection covering the corrected notes.\n" ..
        " - Ensure notes on the destination MIDI item have the correct pitches\n" ..
        "   in that range (e.g. from manual editing or Apply pitch changes).\n\n" ..
        "Sweeps YIN threshold, frequency range, and window length. Scoring is\n" ..
        "octave-insensitive — pitch-class accuracy is the goal; use pitch range\n" ..
        "constraints to fix any octave errors afterward.\n\n" ..
        "Only available when Pitch source is Built-in detection.\n\n" ..
        "Use 'Save' first to preserve your current values.",

    scan_slides =
        "Scan existing notes on the destination MIDI item and report any\n" ..
        "where pitch moves significantly during the note.\n\n" ..
        "Uses the audio source track to sample pitch at multiple points\n" ..
        "inside each note (via YIN), then classifies the trajectory:\n" ..
        "  Slide up    — pitch rises through the note\n" ..
        "  Slide down  — pitch falls through the note\n" ..
        "  Scoop       — dips then rises (e.g. start mid, drop, go high)\n" ..
        "  Bend        — rises then falls\n" ..
        "  Complex slide — three or more direction changes\n\n" ..
        "Stable notes are not reported. Notes below Min note length are skipped.\n" ..
        "Requires at least two pitch segments each meeting Min segment duration\n" ..
        "inside the note to count as a slide.\n" ..
        "Octave detection errors (C3 vs C5) are ignored — only pitch-class\n" ..
        "changes trigger a slide report.\n\n" ..
        "Uses the YIN threshold and frequency settings in the section above.\n\n" ..
        "Scope:\n" ..
        " - With time selection: scans notes within the selection.\n" ..
        " - Without time selection: scans all notes on the MIDI item.\n\n" ..
        "Read-only — does not modify the project.",

    reset_slides =
        "Reset all Slide Scan sliders to factory defaults.",
    reset_yin =
        "Reset YIN detection settings to factory defaults.",
    slide_min_note_ms =
        "Notes shorter than this duration are skipped entirely.\n" ..
        "Increase to ignore short notes; decrease to scan more aggressively.\n\n",
    slide_min_seg_ms =
        "A detected pitch run shorter than this is discarded.\n" ..
        "Increase to suppress flickery false positives;\n" ..
        "decrease to catch very short slides.\n\n",
    slide_skip_ms =
        "Skip the start and end of each note before sampling.\n" ..
        "Hides consonant artifacts at note boundaries.\n" ..
        "Set to 0 for clean audio with no edge artifacts.\n\n",
    slide_step_ms =
        "How often pitch is sampled along the note.\n" ..
        "Smaller = more resolution and better coverage, but slower scan.\n\n",
    slide_win_ms =
        "YIN analysis window per sample point.\n" ..
        "Longer = more stable detection;\n" ..
        "shorter = catches faster pitch changes.\n\n",

    lyrics_auto_detect =
        "Look for 'lyrics.txt' in the current project folder and select it " ..
        "automatically. Nothing happens if the file is not found.",

    lyrics_browse =
        "Open a file browser to select a lyrics file.\n\n" ..
        "Format: plain text, words separated by any whitespace. " ..
        "Content inside [square brackets] is stripped before splitting, " ..
        "so section headers like '[verse]' are ignored.",

    lyrics_clear =
        "Remove all lyric text events from the entire destination MIDI item.\n\n" ..
        "Special game events ([tambourine_start], [cowbell_start], etc.) are preserved.",

    lyrics_assign =
        "Assign lyrics from the file to notes on the destination MIDI item.\n\n" ..
        "Words are assigned in order to notes in the RB3 vocal pitch range (C1–C5), " ..
        "sorted by start time.\n\n" ..
        "Scope:\n" ..
        " - With time selection: only notes within the selection receive lyrics.\n" ..
        " - Without time selection: all notes on the MIDI item.\n\n" ..
        "Existing lyric events are cleared first (special game events preserved).\n\n" ..
        "After assigning, the result panel shows count-mismatch warnings and a " ..
        "phrase capitalization check (first word after each phrase marker should " ..
        "start with an uppercase letter).",
}

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local NOTE_NAMES = { 'C','C#','D','D#','E','F','F#','G','G#','A','A#','B' }

local function PitchName(p)
    p = math.floor(p + 0.5)
    if p < 0 then p = 0 elseif p > 127 then p = 127 end
    local octave = math.floor(p / 12) - 2  -- Rock Band octave convention (C1=36, not C2)
    return ('%s%d'):format(NOTE_NAMES[(p % 12) + 1], octave)
end

local function Tooltip(text)
    if r.ImGui_IsItemHovered(ctx) then
        r.ImGui_SetTooltip(ctx, text)
    end
end

local function SliderTooltip(text)
    if r.ImGui_IsItemHovered(ctx) then
        r.ImGui_SetTooltip(ctx, text .. CTRL_CLICK_HINT)
    end
end

-- Format a project time position as "mNN  Xm SS.MMMsec" (measure + wall time).
-- Durations (not positions) should stay in plain seconds — don't use this for them.
local function FormatTime(t)
    local mbt = r.format_timestr_pos(t, '', 1)        -- e.g. "90.1.00"
    local measure = tonumber(mbt:match('^(%d+)'))
    local mins = math.floor(t / 60)
    local secs = t - mins * 60
    local ts = mins > 0 and ('%dm %06.3fs'):format(mins, secs) or ('%.3fs'):format(t)
    return measure and ('m%d  %s'):format(measure, ts) or ts
end

local function GetTrackList()
    local list = {}
    for i = 0, r.CountTracks(0) - 1 do
        local tr = r.GetTrack(0, i)
        local _, name = r.GetTrackName(tr)
        if name == '' then name = ('Track %d'):format(i + 1) end
        list[#list + 1] = { idx = i, label = ('%d: %s'):format(i + 1, name) }
    end
    return list
end

local function TrackCombo(label, sel_idx, tracks)
    local preview = (#tracks > 0 and sel_idx < #tracks)
        and tracks[sel_idx + 1].label or '<no tracks>'
    if r.ImGui_BeginCombo(ctx, label, preview) then
        for i, t in ipairs(tracks) do
            local is_sel = (i - 1 == sel_idx)
            if r.ImGui_Selectable(ctx, t.label, is_sel) then
                sel_idx = i - 1
            end
            if is_sel then r.ImGui_SetItemDefaultFocus(ctx) end
        end
        r.ImGui_EndCombo(ctx)
    end
    return sel_idx
end

local function GetTimeSelection()
    local s, e = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if e > s then return s, e end
    return nil, nil
end

local function TrackHasAudio(track)
    for i = 0, r.CountTrackMediaItems(track) - 1 do
        local item = r.GetTrackMediaItem(track, i)
        local take = r.GetActiveTake(item)
        if take and not r.TakeIsMIDI(take) then return true end
    end
    return false
end

local function TrackHasMIDI(track)
    for i = 0, r.CountTrackMediaItems(track) - 1 do
        local item = r.GetTrackMediaItem(track, i)
        local take = r.GetActiveTake(item)
        if take and r.TakeIsMIDI(take) then return true end
    end
    return false
end

local function SetDefaultTracks()
    local n = r.CountTracks(0)
    local audio_found = false
    for _, name in ipairs({ 'VOCALS AUDIO', 'DRYVOX1' }) do
        if not audio_found then
            for i = 0, n - 1 do
                local tr = r.GetTrack(0, i)
                local _, tname = r.GetTrackName(tr)
                if tname == name and TrackHasAudio(tr) then
                    S.audio_idx = i
                    audio_found = true
                    break
                end
            end
        end
    end
    for i = 0, n - 1 do
        local tr = r.GetTrack(0, i)
        local _, tname = r.GetTrackName(tr)
        if tname == 'PART VOCALS' and TrackHasMIDI(tr) then
            S.midi_idx = i
            break
        end
    end
end

SetDefaultTracks()

local function AutoDetectLyricsFile()
    local proj_path = r.GetProjectPath('')
    if not proj_path or proj_path == '' then return false end
    local sep = (proj_path:sub(-1) == '/' or proj_path:sub(-1) == '\\') and '' or '/'
    local candidate = proj_path .. sep .. 'lyrics.txt'
    local f = io.open(candidate, 'r')
    if f then
        f:close()
        S.lyrics_path = candidate
        return true
    end
    return false
end

AutoDetectLyricsFile()

----------------------------------------------------------------------
-- Resolve audio analysis range
----------------------------------------------------------------------
local function ResolveAnalysisRange(audio_track)
    local sel_start, sel_end = GetTimeSelection()
    local item

    if sel_start then
        for i = 0, r.CountTrackMediaItems(audio_track) - 1 do
            local it  = r.GetTrackMediaItem(audio_track, i)
            local pos = r.GetMediaItemInfo_Value(it, 'D_POSITION')
            local len = r.GetMediaItemInfo_Value(it, 'D_LENGTH')
            if pos < sel_end and pos + len > sel_start then
                item = it
                break
            end
        end
        if not item then
            return nil, 'No audio item on the source track overlaps the time selection.'
        end
    else
        item = r.GetTrackMediaItem(audio_track, 0)
        if not item then
            return nil, 'No media item on the audio track.'
        end
    end

    local item_pos = r.GetMediaItemInfo_Value(item, 'D_POSITION')
    local item_len = r.GetMediaItemInfo_Value(item, 'D_LENGTH')
    local item_end = item_pos + item_len

    local range_start, range_end
    if sel_start then
        range_start = math.max(item_pos, sel_start)
        range_end   = math.min(item_end, sel_end)
    else
        range_start = item_pos
        range_end   = item_end
    end

    if range_end - range_start <= 0 then
        return nil, 'Analysis range is empty.'
    end

    return {
        item          = item,
        range_start   = range_start,
        range_end     = range_end,
        has_selection = sel_start ~= nil,
    }
end

----------------------------------------------------------------------
-- Find a MIDI item on the destination track that fully covers a range
----------------------------------------------------------------------
local function FindMIDIItem(track, range_start, range_end)
    local TOL = 0.001
    for i = 0, r.CountTrackMediaItems(track) - 1 do
        local item = r.GetTrackMediaItem(track, i)
        local take = r.GetActiveTake(item)
        if take and r.TakeIsMIDI(take) then
            local pos = r.GetMediaItemInfo_Value(item, 'D_POSITION')
            local len = r.GetMediaItemInfo_Value(item, 'D_LENGTH')
            if pos <= range_start + TOL and pos + len + TOL >= range_end then
                return item, take
            end
        end
    end
    return nil, nil
end

----------------------------------------------------------------------
-- Find the first MIDI item on a track (no range requirement)
----------------------------------------------------------------------
local function FindFirstMIDIItem(midi_track)
    for i = 0, r.CountTrackMediaItems(midi_track) - 1 do
        local item = r.GetTrackMediaItem(midi_track, i)
        local take = r.GetActiveTake(item)
        if take and r.TakeIsMIDI(take) then return item, take end
    end
    return nil, nil
end

----------------------------------------------------------------------
-- Resolve target for "Apply pitch changes": find a MIDI item to operate on,
-- and the time range within which to process notes.
--
-- With time selection: find a MIDI item that OVERLAPS the selection
-- (doesn't need to fully cover it; we just process notes within both).
-- Without time selection: use the first MIDI item on the track and its
-- full bounds.
----------------------------------------------------------------------
local function ResolveApplyPitchTarget(midi_track)
    local sel_start, sel_end = GetTimeSelection()

    if sel_start then
        for i = 0, r.CountTrackMediaItems(midi_track) - 1 do
            local item = r.GetTrackMediaItem(midi_track, i)
            local take = r.GetActiveTake(item)
            if take and r.TakeIsMIDI(take) then
                local pos = r.GetMediaItemInfo_Value(item, 'D_POSITION')
                local len = r.GetMediaItemInfo_Value(item, 'D_LENGTH')
                local item_end = pos + len
                if pos < sel_end and item_end > sel_start then
                    return {
                        item = item, take = take,
                        range_start = math.max(pos, sel_start),
                        range_end   = math.min(item_end, sel_end),
                        has_selection = true,
                    }
                end
            end
        end
        return nil, 'No MIDI item on the destination track overlaps the time selection.'
    end

    for i = 0, r.CountTrackMediaItems(midi_track) - 1 do
        local item = r.GetTrackMediaItem(midi_track, i)
        local take = r.GetActiveTake(item)
        if take and r.TakeIsMIDI(take) then
            local pos = r.GetMediaItemInfo_Value(item, 'D_POSITION')
            local len = r.GetMediaItemInfo_Value(item, 'D_LENGTH')
            return {
                item = item, take = take,
                range_start = pos, range_end = pos + len,
                has_selection = false,
            }
        end
    end
    return nil, 'No MIDI item found on the destination track.'
end

----------------------------------------------------------------------
-- Read all MIDI notes from all MIDI items on a track within a range
----------------------------------------------------------------------
local function ReadAllMIDINotesOnTrack(track, range_start, range_end)
    local notes = {}
    for i = 0, r.CountTrackMediaItems(track) - 1 do
        local item = r.GetTrackMediaItem(track, i)
        local take = r.GetActiveTake(item)
        if take and r.TakeIsMIDI(take) then
            local item_pos = r.GetMediaItemInfo_Value(item, 'D_POSITION')
            local item_len = r.GetMediaItemInfo_Value(item, 'D_LENGTH')
            local item_end = item_pos + item_len
            if item_pos < range_end and item_end > range_start then
                local _, n = r.MIDI_CountEvts(take)
                for j = 0, n - 1 do
                    local ok, _, _, sppq, _, _, p = r.MIDI_GetNote(take, j)
                    if ok then
                        local s_t = r.MIDI_GetProjTimeFromPPQPos(take, sppq)
                        if s_t >= range_start - 1.0 and s_t <= range_end + 1.0 then
                            notes[#notes + 1] = { s = s_t, pitch = p }
                        end
                    end
                end
            end
        end
    end
    table.sort(notes, function(a, b) return a.s < b.s end)
    return notes
end

----------------------------------------------------------------------
-- Read notes at a specific pitch (for autotune reference)
----------------------------------------------------------------------
local function ReadReferenceNotes(midi_take, pitch, range_start, range_end)
    local notes = {}
    local _, n_notes = r.MIDI_CountEvts(midi_take)
    for i = 0, n_notes - 1 do
        local ok, _, _, sppq, eppq, _, p = r.MIDI_GetNote(midi_take, i)
        if ok and p == pitch then
            local s_t = r.MIDI_GetProjTimeFromPPQPos(midi_take, sppq)
            local e_t = r.MIDI_GetProjTimeFromPPQPos(midi_take, eppq)
            if s_t < range_end and e_t > range_start then
                notes[#notes + 1] = { s = s_t, e = e_t }
            end
        end
    end
    table.sort(notes, function(a, b) return a.s < b.s end)
    return notes
end

-- Read all vocal-range notes for auto-tune: pitch-agnostic, deduplicates
-- stacked notes (keeps the lowest pitch when notes share a start time).
local function ReadAutoTuneRefNotes(midi_take, range_start, range_end)
    local raw = {}
    local _, n_notes = r.MIDI_CountEvts(midi_take)
    for i = 0, n_notes - 1 do
        local ok, _, _, sppq, eppq, _, p = r.MIDI_GetNote(midi_take, i)
        if ok and p >= RB3_MIN_PITCH and p <= RB3_MAX_PITCH then
            local s_t = r.MIDI_GetProjTimeFromPPQPos(midi_take, sppq)
            local e_t = r.MIDI_GetProjTimeFromPPQPos(midi_take, eppq)
            if s_t < range_end and e_t > range_start then
                raw[#raw + 1] = { s = s_t, e = e_t, pitch = p }
            end
        end
    end
    -- Sort by start time; within same start time sort lowest pitch first.
    table.sort(raw, function(a, b)
        if math.abs(a.s - b.s) < 0.01 then return a.pitch < b.pitch end
        return a.s < b.s
    end)
    -- Deduplicate: skip any note whose start is within 10 ms of the last kept note.
    local notes = {}
    local last_s = -math.huge
    for _, n in ipairs(raw) do
        if n.s - last_s >= 0.01 then
            notes[#notes + 1] = { s = n.s, e = n.e }
            last_s = n.s
        end
    end
    return notes
end

----------------------------------------------------------------------
-- Find the nearest reference pitch to a given time, within tolerance
----------------------------------------------------------------------
local function FindNearestRefPitch(ref_notes, time, tolerance_s)
    local best_pitch, best_dist = nil, tolerance_s + 1
    for _, ref in ipairs(ref_notes) do
        if ref.s > time + tolerance_s then break end
        if ref.s >= time - tolerance_s then
            local dist = math.abs(ref.s - time)
            if dist < best_dist then
                best_dist = dist
                best_pitch = ref.pitch
            end
        end
    end
    return best_pitch
end

----------------------------------------------------------------------
-- Snap a pitch into [min, max] by trying octave shifts
----------------------------------------------------------------------
local function ApplyPitchRange(pitch, min_p, max_p)
    if not min_p and not max_p then return pitch end
    local p = pitch
    local guard = 16
    while min_p and p < min_p and guard > 0 do
        p = p + 12
        guard = guard - 1
    end
    guard = 16
    while max_p and p > max_p and guard > 0 do
        p = p - 12
        guard = guard - 1
    end
    if min_p and p < min_p then p = min_p end
    if max_p and p > max_p then p = max_p end
    if p < RB3_MIN_PITCH then p = RB3_MIN_PITCH elseif p > RB3_MAX_PITCH then p = RB3_MAX_PITCH end
    return p
end

----------------------------------------------------------------------
-- Delete notes at any of the given pitches that overlap a range
----------------------------------------------------------------------
local function ClearNotesAtPitchesInRange(midi_take, pitch_set, range_start, range_end)
    local _, n_notes = r.MIDI_CountEvts(midi_take)
    local removed = 0
    for i = n_notes - 1, 0, -1 do
        local ok, _, _, sppq, eppq, _, p = r.MIDI_GetNote(midi_take, i)
        if ok and pitch_set[p] and p >= RB3_MIN_PITCH and p <= RB3_MAX_PITCH then
            local s_t = r.MIDI_GetProjTimeFromPPQPos(midi_take, sppq)
            local e_t = r.MIDI_GetProjTimeFromPPQPos(midi_take, eppq)
            if s_t < range_end and e_t > range_start then
                r.MIDI_DeleteNote(midi_take, i)
                removed = removed + 1
            end
        end
    end
    return removed
end

local function ClearAllNotesInRange(midi_take, range_start, range_end)
    local _, n_notes = r.MIDI_CountEvts(midi_take)
    local removed = 0
    for i = n_notes - 1, 0, -1 do
        local ok, _, _, sppq, eppq, _, p = r.MIDI_GetNote(midi_take, i)
        if ok and p >= RB3_MIN_PITCH and p <= RB3_MAX_PITCH then
            local s_t = r.MIDI_GetProjTimeFromPPQPos(midi_take, sppq)
            local e_t = r.MIDI_GetProjTimeFromPPQPos(midi_take, eppq)
            if s_t < range_end and e_t > range_start then
                r.MIDI_DeleteNote(midi_take, i)
                removed = removed + 1
            end
        end
    end
    return removed
end

----------------------------------------------------------------------
-- RMS contour
----------------------------------------------------------------------
local function ComputeRMSContour(audio_item, range_start, range_end, window_s, lpf_cutoff_hz)
    local take = r.GetActiveTake(audio_item)
    if not take or r.TakeIsMIDI(take) then
        return nil, 'Active take on the audio track is not audio.'
    end

    local src = r.GetMediaItemTake_Source(take)
    local sr  = r.GetMediaSourceSampleRate(src)
    local nch = r.GetMediaSourceNumChannels(src)
    if sr == 0 then return nil, 'Could not read source sample rate.' end

    local item_pos  = r.GetMediaItemInfo_Value(audio_item, 'D_POSITION')
    local rel_start = range_start - item_pos
    local rel_len   = range_end   - range_start

    local accessor   = r.CreateTakeAudioAccessor(take)
    local win_samps  = math.max(1, math.floor(window_s * sr))
    local total_wins = math.floor(rel_len / window_s)
    local chunk_wins = 256
    local buf_samps  = win_samps * chunk_wins
    local buffer     = r.new_array(buf_samps * nch)

    local lpf_alpha
    if lpf_cutoff_hz > 0 and lpf_cutoff_hz < sr * 0.5 then
        lpf_alpha = 1 - math.exp(-2 * math.pi * lpf_cutoff_hz / sr)
    end
    local lpf_y1, lpf_y2 = {}, {}
    for c = 0, nch - 1 do lpf_y1[c] = 0; lpf_y2[c] = 0 end

    local contour = {}
    local w = 0
    while w < total_wins do
        local this_wins  = math.min(chunk_wins, total_wins - w)
        local this_samps = this_wins * win_samps
        local t_start    = rel_start + (w * win_samps) / sr

        buffer.clear()
        local ret = r.GetAudioAccessorSamples(accessor, sr, nch, t_start, this_samps, buffer)
        if ret < 0 then break end

        for k = 0, this_wins - 1 do
            local sum  = 0
            local base = k * win_samps * nch + 1
            local last = base + win_samps * nch - 1
            if lpf_alpha then
                for i = base, last do
                    local ch  = (i - base) % nch
                    local raw = buffer[i]
                    local y1  = lpf_y1[ch] + lpf_alpha * (raw - lpf_y1[ch])
                    local y2  = lpf_y2[ch] + lpf_alpha * (y1  - lpf_y2[ch])
                    lpf_y1[ch] = y1
                    lpf_y2[ch] = y2
                    sum = sum + y2 * y2
                end
            else
                for i = base, last do
                    local s = buffer[i]
                    sum = sum + s * s
                end
            end
            contour[#contour + 1] = math.sqrt(sum / (win_samps * nch))
        end
        w = w + this_wins
    end

    r.DestroyAudioAccessor(accessor)

    return {
        contour     = contour,
        win_samps   = win_samps,
        sr          = sr,
        time_offset = range_start,
    }
end

----------------------------------------------------------------------
-- YIN monophonic pitch detection
----------------------------------------------------------------------
local function OpenYINContext(audio_item)
    local take = r.GetActiveTake(audio_item)
    if not take or r.TakeIsMIDI(take) then
        return nil, 'Audio item has no valid audio take.'
    end
    local src = r.GetMediaItemTake_Source(take)
    local sr  = r.GetMediaSourceSampleRate(src)
    local nch = r.GetMediaSourceNumChannels(src)
    if sr == 0 then return nil, 'Could not read source sample rate.' end
    return {
        accessor = r.CreateTakeAudioAccessor(take),
        sr       = sr,
        nch      = nch,
        item_pos = r.GetMediaItemInfo_Value(audio_item, 'D_POSITION'),
    }
end

local function CloseYINContext(ctx)
    if ctx then r.DestroyAudioAccessor(ctx.accessor) end
end

local function DetectPitchYIN(ctx, note_s, note_e)
    local sr, nch = ctx.sr, ctx.nch
    local note_len = note_e - note_s

    local win_s = math.min(S.yin_window_ms / 1000, note_len * 0.8)
    if win_s < 0.01 then return nil end

    local n_samps = math.max(2, math.floor(win_s * sr))
    local tau_min = math.max(1, math.floor(sr / S.yin_max_freq))
    local tau_max = math.min(
        math.floor(sr / S.yin_min_freq),
        math.floor(n_samps / 2) - 1)
    if tau_max < tau_min then return nil end

    -- Sample from 30% into the note to hit steady-state vowel, avoid attack
    local t_off = note_s + note_len * 0.3 - ctx.item_pos
    if t_off < 0 then t_off = 0 end

    local buf = r.new_array(n_samps * nch)
    buf.clear()
    r.GetAudioAccessorSamples(ctx.accessor, sr, nch, t_off, n_samps, buf)

    -- Mix to mono Lua table for the inner loop
    local mono = {}
    for i = 1, n_samps do
        local s = 0
        for c = 0, nch - 1 do s = s + buf[(i - 1) * nch + c + 1] end
        mono[i] = nch > 1 and s / nch or s
    end

    -- Cumulative mean normalized difference function (CMND / YIN step 2)
    local d = {}
    d[0] = 0
    local running_sum = 0
    for tau = 1, tau_max do
        local sq = 0
        for j = 1, n_samps - tau do
            local diff = mono[j] - mono[j + tau]
            sq = sq + diff * diff
        end
        running_sum = running_sum + sq
        d[tau] = (running_sum > 0) and (sq * tau / running_sum) or 1
    end

    -- First dip below threshold, sliding to local minimum
    local tau_est = nil
    for tau = tau_min, tau_max - 1 do
        if d[tau] < S.yin_threshold then
            while tau < tau_max and d[tau + 1] < d[tau] do tau = tau + 1 end
            tau_est = tau
            break
        end
    end

    -- Fallback: global minimum if confident enough
    if not tau_est then
        local min_d, min_tau = math.huge, tau_min
        for tau = tau_min, tau_max do
            if d[tau] < min_d then min_d = d[tau]; min_tau = tau end
        end
        if min_d > 0.5 then return nil end
        tau_est = min_tau
    end

    -- Parabolic interpolation for sub-sample period precision
    if tau_est > tau_min and tau_est < tau_max then
        local s0, s1, s2 = d[tau_est - 1], d[tau_est], d[tau_est + 1]
        local denom = 2 * s1 - s0 - s2
        if math.abs(denom) > 1e-10 then
            tau_est = tau_est + (s0 - s2) / (2 * denom)
        end
    end

    local freq = sr / tau_est
    if freq < S.yin_min_freq or freq > S.yin_max_freq then return nil end
    return math.floor(69 + 12 * math.log(freq / 440) / math.log(2) + 0.5)
end

-- Variant of DetectPitchYIN that samples at an explicit project time instead
-- of the 30%-into-note heuristic. Used by ScanPitchSlidesAction for multi-
-- point sampling along a note.
local function SampleYINAt(yctx, t_sample, win_s)
    local sr, nch = yctx.sr, yctx.nch
    if win_s < 0.01 then return nil end

    local n_samps = math.max(2, math.floor(win_s * sr))
    local tau_min = math.max(1, math.floor(sr / S.yin_max_freq))
    local tau_max = math.min(
        math.floor(sr / S.yin_min_freq),
        math.floor(n_samps / 2) - 1)
    if tau_max < tau_min then return nil end

    local t_off = t_sample - yctx.item_pos
    if t_off < 0 then t_off = 0 end

    local buf = r.new_array(n_samps * nch)
    buf.clear()
    r.GetAudioAccessorSamples(yctx.accessor, sr, nch, t_off, n_samps, buf)

    local mono = {}
    for i = 1, n_samps do
        local s = 0
        for c = 0, nch - 1 do s = s + buf[(i - 1) * nch + c + 1] end
        mono[i] = nch > 1 and s / nch or s
    end

    local d = {}
    d[0] = 0
    local running_sum = 0
    for tau = 1, tau_max do
        local sq = 0
        for j = 1, n_samps - tau do
            local diff = mono[j] - mono[j + tau]
            sq = sq + diff * diff
        end
        running_sum = running_sum + sq
        d[tau] = (running_sum > 0) and (sq * tau / running_sum) or 1
    end

    local tau_est = nil
    for tau = tau_min, tau_max - 1 do
        if d[tau] < S.yin_threshold then
            while tau < tau_max and d[tau + 1] < d[tau] do tau = tau + 1 end
            tau_est = tau
            break
        end
    end
    if not tau_est then
        local min_d, min_tau = math.huge, tau_min
        for tau = tau_min, tau_max do
            if d[tau] < min_d then min_d = d[tau]; min_tau = tau end
        end
        if min_d > 0.5 then return nil end
        tau_est = min_tau
    end

    if tau_est > tau_min and tau_est < tau_max then
        local s0, s1, s2 = d[tau_est - 1], d[tau_est], d[tau_est + 1]
        local denom = 2 * s1 - s0 - s2
        if math.abs(denom) > 1e-10 then
            tau_est = tau_est + (s0 - s2) / (2 * denom)
        end
    end

    local freq = sr / tau_est
    if freq < S.yin_min_freq or freq > S.yin_max_freq then return nil end
    return math.floor(69 + 12 * math.log(freq / 440) / math.log(2) + 0.5)
end

----------------------------------------------------------------------
-- Gate + optional peak-relative split
----------------------------------------------------------------------
local function GateAndSplit(contour_info, threshold, split_ratio, min_note_s)
    local contour   = contour_info.contour
    local win_samps = contour_info.win_samps
    local sr        = contour_info.sr
    local t_off     = contour_info.time_offset
    local win_s     = win_samps / sr
    local min_wins  = math.max(1, math.floor(min_note_s / win_s))

    local phrases = {}
    local in_phr, p_s, p_e = false, 0, 0
    for i = 1, #contour do
        if contour[i] >= threshold then
            if not in_phr then in_phr = true; p_s = i end
            p_e = i + 1
        elseif in_phr then
            phrases[#phrases + 1] = { s = p_s, e = p_e }
            in_phr = false
        end
    end
    if in_phr then phrases[#phrases + 1] = { s = p_s, e = p_e } end

    local notes_idx = {}
    local split_extra = 0

    for _, phr in ipairs(phrases) do
        if split_ratio <= 0 then
            if (phr.e - phr.s) >= min_wins then
                notes_idx[#notes_idx + 1] = { s = phr.s, e = phr.e }
            end
        else
            local peak = 0
            for i = phr.s, phr.e - 1 do
                if contour[i] > peak then peak = contour[i] end
            end
            local cut = peak * split_ratio
            if cut < threshold then cut = threshold end

            local sub_count = 0
            local in_sub, s_idx, e_idx = false, 0, 0
            for i = phr.s, phr.e - 1 do
                if contour[i] >= cut then
                    if not in_sub then in_sub = true; s_idx = i end
                    e_idx = i + 1
                elseif in_sub then
                    if (e_idx - s_idx) >= min_wins then
                        notes_idx[#notes_idx + 1] = { s = s_idx, e = e_idx }
                        sub_count = sub_count + 1
                    end
                    in_sub = false
                end
            end
            if in_sub and (e_idx - s_idx) >= min_wins then
                notes_idx[#notes_idx + 1] = { s = s_idx, e = e_idx }
                sub_count = sub_count + 1
            end
            if sub_count > 1 then split_extra = split_extra + (sub_count - 1) end
        end
    end

    local notes = {}
    for _, n in ipairs(notes_idx) do
        notes[#notes + 1] = {
            s = t_off + (n.s - 1) * win_s,
            e = t_off + (n.e - 1) * win_s,
        }
    end

    return notes, #phrases, split_extra
end

----------------------------------------------------------------------
-- Apply min-offset cap
----------------------------------------------------------------------
local function ApplyMinOffset(notes, min_off_s)
    local capped = 0
    for i = 1, #notes - 1 do
        local cap = notes[i + 1].s - min_off_s
        if notes[i].e > cap then
            notes[i].e = cap
            capped = capped + 1
        end
    end
    local out, dropped = {}, 0
    for _, n in ipairs(notes) do
        if n.e > n.s then
            out[#out + 1] = n
        else
            dropped = dropped + 1
        end
    end
    return out, capped, dropped
end

----------------------------------------------------------------------
-- Run the full detection pipeline
----------------------------------------------------------------------
local function RunDetection(range_info)
    local contour_info, cerr = ComputeRMSContour(
        range_info.item, range_info.range_start, range_info.range_end,
        S.window_ms / 1000, S.lpf_cutoff_hz)
    if not contour_info then return nil, cerr end

    local raw, n_phrases, n_splits = GateAndSplit(
        contour_info,
        S.rms_threshold,
        S.split_ratio / 100,
        S.min_note_ms / 1000)

    local notes, capped, dropped = ApplyMinOffset(raw, S.min_offset_ms / 1000)

    return {
        notes         = notes,
        raw_count     = #raw,
        phrases       = n_phrases,
        splits        = n_splits,
        capped        = capped,
        dropped       = dropped,
        range_start   = range_info.range_start,
        range_end     = range_info.range_end,
        has_selection = range_info.has_selection,
    }
end

----------------------------------------------------------------------
-- Assign pitches based on the configured Pitch source
----------------------------------------------------------------------
local function AssignPitches(notes, ref_track, audio_item, force_mode)
    local mode = force_mode ~= nil and force_mode or S.pitch_mode
    local default = S.pitch
    local min_p = S.min_pitch_enabled and S.min_pitch or nil
    local max_p = S.max_pitch_enabled and S.max_pitch or nil

    local ref_notes
    local ref_used, ref_fallback = 0, 0

    if mode == MODE_REFERENCE then
        if not ref_track then
            return nil, 'Reference MIDI track is not selected.'
        end
        local pad = (S.ref_search_ms / 1000) + 0.1
        local r_start = (notes[1] and notes[1].s or 0) - pad
        local r_end   = (notes[#notes] and notes[#notes].e or 0) + pad
        ref_notes = ReadAllMIDINotesOnTrack(ref_track, r_start, r_end)
    end

    local yin_ctx
    if mode == MODE_YIN then
        if not audio_item then
            return nil, 'Audio source item is required for built-in pitch detection.'
        end
        local err
        yin_ctx, err = OpenYINContext(audio_item)
        if not yin_ctx then return nil, err end
    end

    local out = {}
    for _, n in ipairs(notes) do
        local pitch
        if mode == MODE_REFERENCE then
            local found = FindNearestRefPitch(ref_notes, n.s, S.ref_search_ms / 1000)
            if found then
                pitch = found
                ref_used = ref_used + 1
            else
                pitch = default
                ref_fallback = ref_fallback + 1
            end
        elseif mode == MODE_YIN then
            local detected = DetectPitchYIN(yin_ctx, n.s, n.e)
            if detected then
                pitch = detected
                ref_used = ref_used + 1
            else
                pitch = default
                ref_fallback = ref_fallback + 1
            end
        else
            pitch = default
        end

        local raw_pitch = pitch
        pitch = ApplyPitchRange(pitch, min_p, max_p)
        out[#out + 1] = {
            s = n.s, e = n.e,
            pitch = pitch,
            shifted = (pitch ~= raw_pitch),
        }
    end

    if yin_ctx then CloseYINContext(yin_ctx) end

    local stats = { ref_used = ref_used, ref_fallback = ref_fallback }
    local shifted = 0
    for _, n in ipairs(out) do if n.shifted then shifted = shifted + 1 end end
    stats.range_adjusted = shifted

    return out, stats
end

----------------------------------------------------------------------
-- Result formatting (Preview / Generate)
----------------------------------------------------------------------
local function FormatResult(res, action, cleared, pitch_stats)
    local lines = {
        ('%s: %d notes'):format(action, #res.notes),
        ('Range: %s — %s  (%.3fs)%s'):format(
            FormatTime(res.range_start), FormatTime(res.range_end),
            res.range_end - res.range_start,
            res.has_selection and ' [time selection]' or ' [whole item]'),
    }
    if res.splits > 0 then
        lines[#lines + 1] = ('Phrases: %d  ->  split into %d extra notes')
            :format(res.phrases, res.splits)
    else
        lines[#lines + 1] = ('Phrases: %d'):format(res.phrases)
    end
    lines[#lines + 1] = ('Length-capped by min offset: %d'):format(res.capped)
    lines[#lines + 1] = ('Dropped (too short): %d'):format(res.dropped)

    if pitch_stats then
        if S.pitch_mode == MODE_REFERENCE then
            lines[#lines + 1] = ('Pitch source: Reference  ->  matched %d, fallback to default %d')
                :format(pitch_stats.ref_used, pitch_stats.ref_fallback)
        elseif S.pitch_mode == MODE_YIN then
            lines[#lines + 1] = ('Pitch source: Built-in  ->  detected %d, fallback to default %d')
                :format(pitch_stats.ref_used, pitch_stats.ref_fallback)
        end
        if pitch_stats.range_adjusted and pitch_stats.range_adjusted > 0 then
            lines[#lines + 1] = ('Pitch range adjusted: %d notes octave-shifted or clamped')
                :format(pitch_stats.range_adjusted)
        end
    end

    if cleared then
        lines[#lines + 1] = ('Cleared existing notes in range: %d'):format(cleared)
    end
    return table.concat(lines, '\n')
end

----------------------------------------------------------------------
-- Score detection vs reference (for auto-tune)
----------------------------------------------------------------------
local MATCH_TOLERANCE_S = 0.25

local function ScoreNotes(detected, reference)
    local pairs_list = {}
    for i, ref in ipairs(reference) do
        for j, det in ipairs(detected) do
            local dist = math.abs(det.s - ref.s)
            if dist <= MATCH_TOLERANCE_S then
                pairs_list[#pairs_list + 1] = { i = i, j = j, dist = dist }
            end
        end
    end
    table.sort(pairs_list, function(a, b) return a.dist < b.dist end)

    local matches = {}
    local ref_used, det_used = {}, {}
    for _, p in ipairs(pairs_list) do
        if not ref_used[p.i] and not det_used[p.j] then
            ref_used[p.i] = true
            det_used[p.j] = true
            local ref = reference[p.i]
            local det = detected[p.j]
            matches[#matches + 1] = {
                start_diff = det.s - ref.s,
                len_diff   = (det.e - det.s) - (ref.e - ref.s),
            }
        end
    end

    local matched = #matches
    local misses  = #reference - matched
    local extras  = #detected  - matched

    local sum_start, sum_len = 0, 0
    for _, m in ipairs(matches) do
        sum_start = sum_start + math.abs(m.start_diff)
        sum_len   = sum_len   + math.abs(m.len_diff)
    end
    local mean_start = matched > 0 and sum_start / matched or 0
    local mean_len   = matched > 0 and sum_len   / matched or 0

    local score = (misses + extras) * 1000
                + mean_start * 1000
                + mean_len   * 100

    return {
        score        = score,
        matched      = matched,
        misses       = misses,
        extras       = extras,
        mean_start_s = mean_start,
        mean_len_s   = mean_len,
        ref_count    = #reference,
        det_count    = #detected,
    }
end

----------------------------------------------------------------------
-- Auto-tune
----------------------------------------------------------------------
local function FineCandidates(value, deltas, lo, hi)
    local out = {}
    for _, d in ipairs(deltas) do
        local v = value + d
        if v >= lo and v <= hi then out[#out + 1] = v end
    end
    return out
end

local function EvaluateParams(contour_cache, range_info, params)
    local key = ('%.0f|%.2f'):format(params.window_ms, params.lpf_cutoff_hz)
    local contour_info = contour_cache[key]
    if not contour_info then
        local ci, err = ComputeRMSContour(
            range_info.item, range_info.range_start, range_info.range_end,
            params.window_ms / 1000, params.lpf_cutoff_hz)
        if not ci then return nil, err end
        contour_cache[key] = ci
        contour_info = ci
    end
    local notes = GateAndSplit(contour_info,
        params.rms_threshold, params.split_ratio / 100, params.min_note_ms / 1000)
    notes = ApplyMinOffset(notes, params.min_offset_ms / 1000)
    return notes
end

local function AutoTune(range_info, midi_take)
    local ref_notes = ReadAutoTuneRefNotes(midi_take,
        range_info.range_start, range_info.range_end)
    if #ref_notes == 0 then
        return nil, 'No notes in the time selection to use as reference.\n' ..
            'Place a few notes manually on the destination MIDI item first, then run Auto-tune.'
    end

    local cache = {}
    local CANDIDATES_COARSE = {
        rms_threshold = { 0.005, 0.01, 0.02, 0.04, 0.07, 0.1, 0.15, 0.2 },
        lpf_cutoff_hz = { 0, 1500, 2000, 2500, 3000 },
        split_ratio   = { 0, 30, 50, 70 },
        min_offset_ms = { 0, 25, 50, 100, 150, 200, 300 },
        min_note_ms   = { 30, 50, 80, 120, 200 },
    }

    local best = {
        rms_threshold = S.rms_threshold,
        lpf_cutoff_hz = S.lpf_cutoff_hz,
        split_ratio   = S.split_ratio,
        min_offset_ms = S.min_offset_ms,
        min_note_ms   = S.min_note_ms,
        window_ms     = S.window_ms,
    }

    local function Eval(params)
        local notes, err = EvaluateParams(cache, range_info, params)
        if not notes then return nil, err end
        return ScoreNotes(notes, ref_notes)
    end

    local best_score, eval_err = Eval(best)
    if not best_score then return nil, eval_err end

    local function SweepParam(name, candidates)
        for _, val in ipairs(candidates) do
            if val ~= best[name] then
                local trial = {}
                for k, v in pairs(best) do trial[k] = v end
                trial[name] = val
                local sc = Eval(trial)
                if sc and sc.score < best_score.score then
                    best = trial
                    best_score = sc
                end
            end
        end
    end

    for _ = 1, 2 do
        SweepParam('rms_threshold', CANDIDATES_COARSE.rms_threshold)
        SweepParam('lpf_cutoff_hz', CANDIDATES_COARSE.lpf_cutoff_hz)
        SweepParam('split_ratio',   CANDIDATES_COARSE.split_ratio)
        SweepParam('min_offset_ms', CANDIDATES_COARSE.min_offset_ms)
        SweepParam('min_note_ms',   CANDIDATES_COARSE.min_note_ms)
    end

    SweepParam('rms_threshold', FineCandidates(best.rms_threshold,
        { -0.015, -0.01, -0.005, 0.005, 0.01, 0.015 }, 0.001, 0.5))
    if best.lpf_cutoff_hz > 0 then
        SweepParam('lpf_cutoff_hz', FineCandidates(best.lpf_cutoff_hz,
            { -500, -250, 250, 500 }, 100, 8000))
    end
    if best.split_ratio > 0 then
        SweepParam('split_ratio', FineCandidates(best.split_ratio,
            { -15, -10, -5, 5, 10, 15 }, 1, 95))
    end
    SweepParam('min_offset_ms', FineCandidates(best.min_offset_ms,
        { -30, -15, 15, 30 }, 0, 500))
    SweepParam('min_note_ms', FineCandidates(best.min_note_ms,
        { -30, -15, 15, 30 }, 10, 500))

    return { params = best, score = best_score, ref_count = #ref_notes }
end

local function FormatAutoTuneResult(result)
    local p  = result.params
    local sc = result.score
    local denom = math.max(sc.ref_count, sc.det_count, 1)
    local accuracy = (sc.matched / denom) * 100

    local lines = {
        'Auto-tune complete',
        ('  Reference     : %d notes'):format(sc.ref_count),
        ('  Detected      : %d notes'):format(sc.det_count),
        ('  Matched       : %d  (%.0f%% accuracy)'):format(sc.matched, accuracy),
        ('  Misses / extras: %d / %d'):format(sc.misses, sc.extras),
        ('  Avg start diff : ±%.0f ms'):format(sc.mean_start_s * 1000),
        ('  Avg length diff: ±%.0f ms'):format(sc.mean_len_s   * 1000),
        '',
        'Applied values:',
        ('  RMS threshold : %.4f'):format(p.rms_threshold),
        ('  Low-pass      : %s'):format(
            p.lpf_cutoff_hz > 0 and ('%.0f Hz'):format(p.lpf_cutoff_hz) or 'Off'),
        ('  Split ratio   : %s'):format(
            p.split_ratio > 0 and ('%.0f%%'):format(p.split_ratio) or 'Off'),
        ('  Min offset    : %.0f ms'):format(p.min_offset_ms),
        ('  Min note      : %.0f ms'):format(p.min_note_ms),
    }
    return table.concat(lines, '\n')
end

local function ApplyAutoTuneResult(result)
    local p = result.params
    S.rms_threshold = p.rms_threshold
    S.lpf_cutoff_hz = p.lpf_cutoff_hz
    S.split_ratio   = p.split_ratio
    S.min_offset_ms = p.min_offset_ms
    S.min_note_ms   = p.min_note_ms
end

local function FormatAutoTuneYINResult(result)
    local p   = result.params
    local pct = result.ref_count > 0
        and (result.pc_hits / result.ref_count * 100) or 0

    local lines = {
        'YIN auto-tune complete',
        ('  Reference notes  : %d'):format(result.ref_count),
        ('  Detected         : %d  (fallback to default: %d)'):format(
            result.detected, result.fallback),
        ('  Pitch-class hits : %d  (%.0f%%)'):format(result.pc_hits, pct),
        '',
        'Applied values:',
        ('  YIN threshold  : %.3f'):format(p.yin_threshold),
        ('  Min frequency  : %.0f Hz'):format(p.yin_min_hz),
        ('  Max frequency  : %.0f Hz'):format(p.yin_max_hz),
        ('  YIN window     : %.0f ms'):format(p.yin_window_ms),
    }

    if result.octave_mismatches > 0 then
        lines[#lines + 1] = ''
        lines[#lines + 1] = ('Octave mismatches: %d (correct pitch class, wrong octave).')
            :format(result.octave_mismatches)
        lines[#lines + 1] = ('Reference spans %s\xe2\x80\x93%s. Consider enabling pitch range constraints:')
            :format(PitchName(result.ref_min_pitch), PitchName(result.ref_max_pitch))
        lines[#lines + 1] = ('  Min pitch: %d (%s),  Max pitch: %d (%s)')
            :format(result.ref_min_pitch, PitchName(result.ref_min_pitch),
                    result.ref_max_pitch, PitchName(result.ref_max_pitch))
    end

    lines[#lines + 1] = ''
    lines[#lines + 1] = 'These are starting values \xe2\x80\x94 review and fine-tune the sliders as needed.'
    return table.concat(lines, '\n')
end

----------------------------------------------------------------------
-- YIN auto-tune from reference
----------------------------------------------------------------------
local function AutoTuneYIN(audio_item, ref_notes)
    local yin_ctx, err = OpenYINContext(audio_item)
    if not yin_ctx then return nil, err end

    local sr  = yin_ctx.sr
    local nch = yin_ctx.nch

    local CANDIDATES_COARSE = {
        yin_threshold = { 0.05, 0.08, 0.10, 0.12, 0.15, 0.18, 0.20, 0.25, 0.30, 0.40 },
        yin_min_hz    = { 40, 60, 80, 100, 130, 160, 200 },
        yin_max_hz    = { 400, 600, 800, 1000, 1300, 1600, 2000 },
        yin_window_ms = { 10, 15, 20, 25, 30, 40, 50, 70 },
    }

    -- CMND cache keyed by window_ms. Built lazily; each entry is a list of
    -- per-note { d, n_samps, tau_max } or false when the note is too short.
    -- Computed up to tau for 40 Hz (the lowest possible candidate min freq) so
    -- that any min/max freq combination can be evaluated without re-reading audio.
    local cmnd_cache      = {}
    local MIN_HZ_ABSOLUTE = 40

    local function GetOrComputeCMND(window_ms)
        if cmnd_cache[window_ms] then return cmnd_cache[window_ms] end
        local entries = {}
        for ni, n in ipairs(ref_notes) do
            local note_len = n.e - n.s
            local win_s    = math.min(window_ms / 1000, note_len * 0.8)
            if win_s < 0.01 then
                entries[ni] = false
            else
                local n_samps = math.max(2, math.floor(win_s * sr))
                local tau_max = math.min(math.floor(sr / MIN_HZ_ABSOLUTE),
                                         math.floor(n_samps / 2) - 1)
                local t_off   = n.s + note_len * 0.3 - yin_ctx.item_pos
                if t_off < 0 then t_off = 0 end

                local buf = r.new_array(n_samps * nch)
                buf.clear()
                r.GetAudioAccessorSamples(yin_ctx.accessor, sr, nch, t_off, n_samps, buf)

                local mono = {}
                for i = 1, n_samps do
                    local s = 0
                    for c = 0, nch - 1 do s = s + buf[(i - 1) * nch + c + 1] end
                    mono[i] = nch > 1 and s / nch or s
                end

                local d = {}; d[0] = 0
                local running_sum = 0
                for tau = 1, tau_max do
                    local sq = 0
                    for j = 1, n_samps - tau do
                        local diff = mono[j] - mono[j + tau]
                        sq = sq + diff * diff
                    end
                    running_sum = running_sum + sq
                    d[tau] = running_sum > 0 and sq * tau / running_sum or 1
                end
                entries[ni] = { d = d, n_samps = n_samps, tau_max = tau_max }
            end
        end
        cmnd_cache[window_ms] = entries
        return entries
    end

    -- Scan a cached CMND with given freq/threshold bounds.
    -- Returns MIDI pitch or nil on fallback. No audio I/O.
    local function ScanCMND(e, tau_min, tau_max_eff, threshold, min_hz, max_hz)
        local d       = e.d
        local tau_est
        for tau = tau_min, tau_max_eff - 1 do
            if d[tau] < threshold then
                while tau < tau_max_eff and d[tau + 1] < d[tau] do tau = tau + 1 end
                tau_est = tau
                break
            end
        end
        if not tau_est then
            local min_d, min_tau = math.huge, tau_min
            for tau = tau_min, tau_max_eff do
                if d[tau] < min_d then min_d = d[tau]; min_tau = tau end
            end
            if min_d > 0.5 then return nil end
            tau_est = min_tau
        end
        if tau_est > tau_min and tau_est < tau_max_eff then
            local s0, s1, s2 = d[tau_est - 1], d[tau_est], d[tau_est + 1]
            local denom = 2 * s1 - s0 - s2
            if math.abs(denom) > 1e-10 then
                tau_est = tau_est + (s0 - s2) / (2 * denom)
            end
        end
        local freq = sr / tau_est
        if freq < min_hz or freq > max_hz then return nil end
        return math.floor(69 + 12 * math.log(freq / 440) / math.log(2) + 0.5)
    end

    -- Score params using cached CMNDs; no audio access after first call per window_ms.
    local function EvalYIN(params)
        if params.yin_min_hz >= params.yin_max_hz then return nil end
        local entries    = GetOrComputeCMND(params.yin_window_ms)
        local tau_min    = math.max(1, math.floor(sr / params.yin_max_hz))
        local tau_max_hz = math.floor(sr / params.yin_min_hz)
        local total      = 0
        for ni, n in ipairs(ref_notes) do
            local e = entries[ni]
            if not e then
                total = total + 6
            else
                local tau_max = math.min(tau_max_hz, e.tau_max, math.floor(e.n_samps / 2) - 1)
                if tau_max < tau_min then
                    total = total + 6
                else
                    local p = ScanCMND(e, tau_min, tau_max, params.yin_threshold,
                                       params.yin_min_hz, params.yin_max_hz)
                    if p then
                        local diff = math.abs(p - n.pitch) % 12
                        total = total + math.min(diff, 12 - diff)
                    else
                        total = total + 6
                    end
                end
            end
        end
        return total
    end

    local best = {
        yin_threshold = S.yin_threshold,
        yin_min_hz    = S.yin_min_freq,
        yin_max_hz    = S.yin_max_freq,
        yin_window_ms = S.yin_window_ms,
    }
    local best_score = EvalYIN(best) or math.huge

    local function SweepParam(name, candidates)
        for _, val in ipairs(candidates) do
            if val ~= best[name] then
                local trial = {}
                for k, v in pairs(best) do trial[k] = v end
                trial[name] = val
                local sc = EvalYIN(trial)
                if sc and sc < best_score then
                    best       = trial
                    best_score = sc
                end
            end
        end
    end

    for _ = 1, 2 do
        SweepParam('yin_threshold', CANDIDATES_COARSE.yin_threshold)
        SweepParam('yin_min_hz',    CANDIDATES_COARSE.yin_min_hz)
        SweepParam('yin_max_hz',    CANDIDATES_COARSE.yin_max_hz)
        SweepParam('yin_window_ms', CANDIDATES_COARSE.yin_window_ms)
    end

    SweepParam('yin_threshold', FineCandidates(best.yin_threshold,
        { -0.04, -0.02, -0.01, 0.01, 0.02, 0.04 }, 0.01, 0.5))
    SweepParam('yin_min_hz', FineCandidates(best.yin_min_hz,
        { -20, -10, 10, 20 }, 40, 400))
    SweepParam('yin_max_hz', FineCandidates(best.yin_max_hz,
        { -100, -50, 50, 100 }, 200, 2000))
    SweepParam('yin_window_ms', FineCandidates(best.yin_window_ms,
        { -10, -5, 5, 10 }, 10, 100))

    -- All audio access is done; close accessor before the stats pass.
    CloseYINContext(yin_ctx)

    -- Final pass at best params from cached CMNDs for detailed result panel stats.
    local final_entries = cmnd_cache[best.yin_window_ms]
    local tau_min_final = math.max(1, math.floor(sr / best.yin_max_hz))
    local tau_max_hz_f  = math.floor(sr / best.yin_min_hz)

    local final_detected    = 0
    local final_fallback    = 0
    local pc_hits           = 0
    local octave_mismatches = 0
    local ref_min_pitch     = math.huge
    local ref_max_pitch     = -math.huge

    for ni, n in ipairs(ref_notes) do
        ref_min_pitch = math.min(ref_min_pitch, n.pitch)
        ref_max_pitch = math.max(ref_max_pitch, n.pitch)
        local e = final_entries and final_entries[ni]
        local p
        if e then
            local tau_max = math.min(tau_max_hz_f, e.tau_max, math.floor(e.n_samps / 2) - 1)
            if tau_max >= tau_min_final then
                p = ScanCMND(e, tau_min_final, tau_max, best.yin_threshold,
                             best.yin_min_hz, best.yin_max_hz)
            end
        end
        if p then
            final_detected = final_detected + 1
            local diff   = math.abs(p - n.pitch) % 12
            local pc_err = math.min(diff, 12 - diff)
            if pc_err == 0 then
                pc_hits = pc_hits + 1
                if p ~= n.pitch then octave_mismatches = octave_mismatches + 1 end
            end
        else
            final_fallback = final_fallback + 1
        end
    end

    return {
        params            = best,
        score             = best_score,
        ref_count         = #ref_notes,
        detected          = final_detected,
        fallback          = final_fallback,
        pc_hits           = pc_hits,
        octave_mismatches = octave_mismatches,
        ref_min_pitch     = ref_min_pitch,
        ref_max_pitch     = ref_max_pitch,
    }
end

----------------------------------------------------------------------
-- Insert notes with per-note pitch
----------------------------------------------------------------------
local function InsertNotes(midi_take, notes_with_pitch, vel)
    for _, n in ipairs(notes_with_pitch) do
        local sp = r.MIDI_GetPPQPosFromProjTime(midi_take, n.s)
        local ep = r.MIDI_GetPPQPosFromProjTime(midi_take, n.e)
        r.MIDI_InsertNote(midi_take, false, false, sp, ep, 0, n.pitch, vel, true)
    end
    r.MIDI_Sort(midi_take)
end

----------------------------------------------------------------------
-- Track resolution
----------------------------------------------------------------------
local function ResolveTracks()
    local tracks = GetTrackList()
    if #tracks == 0 then return nil, 'No tracks in project.' end
    if S.audio_idx >= #tracks or S.midi_idx >= #tracks then
        return nil, 'Track selection out of range.'
    end
    if S.audio_idx == S.midi_idx then
        return nil, 'Pick different tracks for audio and MIDI.'
    end
    local atr = r.GetTrack(0, tracks[S.audio_idx + 1].idx)
    local mtr = r.GetTrack(0, tracks[S.midi_idx  + 1].idx)
    local rtr
    if S.pitch_mode == MODE_REFERENCE then
        if S.ref_idx >= #tracks then
            return nil, 'Reference MIDI track index out of range.'
        end
        if S.ref_idx == S.audio_idx or S.ref_idx == S.midi_idx then
            return nil, 'Reference MIDI track must be different from audio and destination tracks.'
        end
        rtr = r.GetTrack(0, tracks[S.ref_idx + 1].idx)
    end
    return { audio = atr, midi = mtr, ref = rtr }
end

-- For Apply Pitch Changes: audio track only required when mode is MODE_YIN.
local function ResolveApplyPitchTracks()
    local tracks = GetTrackList()
    if #tracks == 0 then return nil, 'No tracks in project.' end
    if S.midi_idx >= #tracks then
        return nil, 'Destination track index out of range.'
    end
    local mtr = r.GetTrack(0, tracks[S.midi_idx + 1].idx)
    local rtr, atr
    if S.pitch_mode == MODE_REFERENCE then
        if S.ref_idx >= #tracks then
            return nil, 'Reference MIDI track index out of range.'
        end
        if S.ref_idx == S.midi_idx then
            return nil, 'Reference MIDI track must be different from the destination track.'
        end
        rtr = r.GetTrack(0, tracks[S.ref_idx + 1].idx)
    elseif S.pitch_mode == MODE_YIN then
        if S.audio_idx >= #tracks then
            return nil, 'Audio track index out of range.'
        end
        if S.audio_idx == S.midi_idx then
            return nil, 'Pick different tracks for audio and MIDI.'
        end
        atr = r.GetTrack(0, tracks[S.audio_idx + 1].idx)
    end
    return { midi = mtr, ref = rtr, audio = atr }
end

----------------------------------------------------------------------
-- Lyrics helpers
----------------------------------------------------------------------
local function ParseLyricsFile(path)
    local f = io.open(path, 'r')
    if not f then return nil, 'Could not open file:\n' .. path end
    local content = f:read('*all')
    f:close()
    content = content:gsub('%b[]', '')  -- strip [comment] blocks
    local words = {}
    for w in content:gmatch('%S+') do words[#words + 1] = w end
    if #words == 0 then
        return nil, 'No lyrics found in file (after stripping comments).'
    end
    return words
end

-- Remove all type-5 (lyric) text events from a take, preserving LYRIC_IGNORE entries.
local function ClearLyricEvents(midi_take)
    local _, _, _, n_text = r.MIDI_CountEvts(midi_take)
    local removed = 0
    for i = n_text - 1, 0, -1 do
        local ok, _, _, _, typ, msg = r.MIDI_GetTextSysexEvt(midi_take, i)
        if ok and typ == 5 and not LYRIC_IGNORE[msg] then
            r.MIDI_DeleteTextSysexEvt(midi_take, i)
            removed = removed + 1
        end
    end
    return removed
end

----------------------------------------------------------------------
-- Actions
----------------------------------------------------------------------
local function Preview()
    local trks, terr = ResolveTracks()
    if not trks then S.status = terr; S.last_result = nil; return end

    local range_info, rerr = ResolveAnalysisRange(trks.audio)
    if not range_info then
        S.status = 'Error'; S.last_result = rerr; return
    end

    local res, err = RunDetection(range_info)
    if not res then S.status = 'Error'; S.last_result = err; return end

    local with_pitch, ps_or_err = AssignPitches(res.notes, trks.ref, range_info.item, MODE_SINGLE)
    if not with_pitch then
        S.status = 'Error'; S.last_result = ps_or_err; return
    end

    S.status = 'Preview complete.'
    S.last_result = FormatResult(res, 'Preview', nil, ps_or_err)
end

local function Generate(replace)
    local trks, terr = ResolveTracks()
    if not trks then S.status = terr; S.last_result = nil; return end

    local range_info, rerr = ResolveAnalysisRange(trks.audio)
    if not range_info then
        S.status = 'Error'; S.last_result = rerr; return
    end

    local midi_item, midi_take = FindMIDIItem(trks.midi, range_info.range_start, range_info.range_end)
    local clamp_warning = nil

    if not midi_take then
        -- Full coverage not found; accept any overlapping MIDI item and clamp the range.
        for i = 0, r.CountTrackMediaItems(trks.midi) - 1 do
            local it   = r.GetTrackMediaItem(trks.midi, i)
            local take = r.GetActiveTake(it)
            if take and r.TakeIsMIDI(take) then
                local pos  = r.GetMediaItemInfo_Value(it, 'D_POSITION')
                local iend = pos + r.GetMediaItemInfo_Value(it, 'D_LENGTH')
                if pos < range_info.range_end and iend > range_info.range_start then
                    local orig_start = range_info.range_start
                    local orig_end   = range_info.range_end
                    range_info.range_start = math.max(range_info.range_start, pos)
                    range_info.range_end   = math.min(range_info.range_end,   iend)
                    local trimmed_start = range_info.range_start - orig_start
                    local trimmed_end   = orig_end - range_info.range_end
                    local parts = {}
                    if trimmed_end   > 0.001 then parts[#parts+1] = ('%.2fs trimmed from end'):format(trimmed_end) end
                    if trimmed_start > 0.001 then parts[#parts+1] = ('%.2fs trimmed from start'):format(trimmed_start) end
                    clamp_warning = 'Note: audio range clamped to MIDI item bounds (' ..
                        table.concat(parts, ', ') .. ').\n' ..
                        ('Audio: %s — %s   MIDI item: %s — %s')
                            :format(FormatTime(orig_start), FormatTime(orig_end),
                                    FormatTime(pos),        FormatTime(iend))
                    midi_item = it
                    midi_take = take
                    break
                end
            end
        end
    end

    if not midi_take then
        S.status = 'Error'
        S.last_result =
            'No MIDI item on the destination track overlaps the analysis range.\n' ..
            'Create a MIDI item on that track to span the range.'
        return
    end

    local res, err = RunDetection(range_info)
    if not res then S.status = 'Error'; S.last_result = err; return end

    local with_pitch, ps_or_err = AssignPitches(res.notes, trks.ref, range_info.item, MODE_SINGLE)
    if not with_pitch then S.status = 'Error'; S.last_result = ps_or_err; return end

    local cleared
    r.PreventUIRefresh(1)
    r.Undo_BeginBlock()
    if replace then
        cleared = ClearAllNotesInRange(midi_take,
            range_info.range_start, range_info.range_end)
    else
        local pitch_set = { [S.pitch] = true }
        for _, n in ipairs(with_pitch) do pitch_set[n.pitch] = true end
        cleared = ClearNotesAtPitchesInRange(midi_take, pitch_set,
            range_info.range_start, range_info.range_end)
    end
    InsertNotes(midi_take, with_pitch, S.velocity)
    local verb = replace and 'replaced' or 'appended'
    r.Undo_EndBlock(
        ('Karaoke MIDI: cleared %d, %s %d'):format(cleared, verb, #with_pitch), -1)
    r.PreventUIRefresh(-1)

    local action = replace and 'Replaced' or 'Appended'
    S.status = 'Done.'
    S.last_result = FormatResult(res, action, cleared, ps_or_err)
    if clamp_warning then
        S.last_result = S.last_result .. '\n\n' .. clamp_warning
    end
end

local function RunAutoTune()
    local trks, terr = ResolveTracks()
    if not trks then S.status = terr; S.last_result = nil; return end

    if not GetTimeSelection() then
        S.status = 'Error'
        S.last_result = 'Auto-tune requires a time selection covering the reference notes.'
        return
    end

    local range_info, rerr = ResolveAnalysisRange(trks.audio)
    if not range_info then
        S.status = 'Error'; S.last_result = rerr; return
    end

    local _, midi_take = FindMIDIItem(trks.midi, range_info.range_start, range_info.range_end)
    if not midi_take then
        S.status = 'Error'
        S.last_result =
            'No MIDI item on the destination track covers the analysis range.\n' ..
            'Create or extend a MIDI item on that track and place reference notes inside.'
        return
    end

    S.status = 'Auto-tuning... (UI may freeze briefly)'
    local t0 = r.time_precise()
    local result, err = AutoTune(range_info, midi_take)
    local elapsed = r.time_precise() - t0

    if not result then S.status = 'Error'; S.last_result = err; return end

    ApplyAutoTuneResult(result)
    S.status = ('Auto-tune complete in %.1fs.'):format(elapsed)
    S.last_result = FormatAutoTuneResult(result)
end

local function RunAutoTuneYIN()
    if not GetTimeSelection() then
        S.status = 'Error'
        S.last_result = 'YIN auto-tune requires a time selection covering your corrected reference notes.'
        return
    end

    local trks, terr = ResolveApplyPitchTracks()
    if not trks then S.status = terr; S.last_result = nil; return end

    local target, perr = ResolveApplyPitchTarget(trks.midi)
    if not target then S.status = 'Error'; S.last_result = perr; return end

    local audio_item
    for i = 0, r.CountTrackMediaItems(trks.audio) - 1 do
        local it   = r.GetTrackMediaItem(trks.audio, i)
        local take = r.GetActiveTake(it)
        if take and not r.TakeIsMIDI(take) then
            local pos = r.GetMediaItemInfo_Value(it, 'D_POSITION')
            local len = r.GetMediaItemInfo_Value(it, 'D_LENGTH')
            if pos < target.range_end and pos + len > target.range_start then
                audio_item = it
                break
            end
        end
    end
    if not audio_item then
        S.status = 'Error'
        S.last_result = 'No audio item on the source track overlaps the time selection.'
        return
    end

    local ref_notes = {}
    local _, n_notes = r.MIDI_CountEvts(target.take)
    for i = 0, n_notes - 1 do
        local ok, _, _, sppq, eppq, _, p = r.MIDI_GetNote(target.take, i)
        if ok and p >= RB3_MIN_PITCH and p <= RB3_MAX_PITCH then
            local s_t = r.MIDI_GetProjTimeFromPPQPos(target.take, sppq)
            local e_t = r.MIDI_GetProjTimeFromPPQPos(target.take, eppq)
            if s_t >= target.range_start - 0.001 and s_t < target.range_end + 0.001 then
                ref_notes[#ref_notes + 1] = { s = s_t, e = e_t, pitch = p }
            end
        end
    end

    if #ref_notes == 0 then
        S.status = 'Error'
        S.last_result =
            'No notes in the time selection.\n' ..
            'Place corrected notes on the destination MIDI item first, then run YIN auto-tune.'
        return
    end

    S.status = ('YIN auto-tuning against %d reference notes\xe2\x80\xa6 (UI may freeze briefly)')
        :format(#ref_notes)
    local t0 = r.time_precise()
    local result, err = AutoTuneYIN(audio_item, ref_notes)
    local elapsed = r.time_precise() - t0

    if not result then S.status = 'Error'; S.last_result = err; return end

    S.yin_threshold = result.params.yin_threshold
    S.yin_min_freq  = result.params.yin_min_hz
    S.yin_max_freq  = result.params.yin_max_hz
    S.yin_window_ms = result.params.yin_window_ms

    S.status = ('YIN auto-tune complete in %.1fs.'):format(elapsed)
    S.last_result = FormatAutoTuneYINResult(result)
end

----------------------------------------------------------------------
-- Apply pitch changes: reassign pitches of existing notes without
-- altering their position or length.
----------------------------------------------------------------------
local function ApplyPitchChangesAction()
    if S.pitch_mode == MODE_SINGLE then
        S.status = 'Error'
        S.last_result =
            'Apply pitch changes requires Pitch source to be Reference MIDI or Built-in detection.\n' ..
            'In Single pitch mode, this would just set every note to the Default pitch.'
        return
    end

    local trks, terr = ResolveApplyPitchTracks()
    if not trks then S.status = terr; S.last_result = nil; return end

    local target, perr = ResolveApplyPitchTarget(trks.midi)
    if not target then S.status = 'Error'; S.last_result = perr; return end

    -- For YIN: find an audio item on the source track that overlaps the range.
    local audio_item_for_yin
    if S.pitch_mode == MODE_YIN then
        for i = 0, r.CountTrackMediaItems(trks.audio) - 1 do
            local item = r.GetTrackMediaItem(trks.audio, i)
            local take = r.GetActiveTake(item)
            if take and not r.TakeIsMIDI(take) then
                local pos = r.GetMediaItemInfo_Value(item, 'D_POSITION')
                local len = r.GetMediaItemInfo_Value(item, 'D_LENGTH')
                if pos < target.range_end and pos + len > target.range_start then
                    audio_item_for_yin = item
                    break
                end
            end
        end
        if not audio_item_for_yin then
            S.status = 'Error'
            S.last_result = 'No audio item on the source track overlaps the target range.'
            return
        end
    end

    -- Read existing notes within range, preserving everything we'll need
    -- to reinsert them with a new pitch.
    local existing = {}
    local _, n_notes = r.MIDI_CountEvts(target.take)
    for i = 0, n_notes - 1 do
        local ok, sel, mute, sppq, eppq, chan, p, vel = r.MIDI_GetNote(target.take, i)
        if ok then
            local s_t = r.MIDI_GetProjTimeFromPPQPos(target.take, sppq)
            local e_t = r.MIDI_GetProjTimeFromPPQPos(target.take, eppq)
            -- Process notes whose start falls in range. Avoids edge cases
            -- where a long note that just barely overlaps would also get
            -- updated even though the user probably didn't intend it.
            if s_t >= target.range_start - 0.001 and s_t < target.range_end + 0.001
            and p >= RB3_MIN_PITCH and p <= RB3_MAX_PITCH then
                existing[#existing + 1] = {
                    idx = i, s = s_t, e = e_t,
                    sppq = sppq, eppq = eppq,
                    sel = sel, mute = mute, chan = chan, vel = vel,
                    old_pitch = p,
                }
            end
        end
    end

    if #existing == 0 then
        S.status = 'No notes in range.'
        S.last_result = ('Range: %s — %s%s\nNothing to update.'):format(
            FormatTime(target.range_start), FormatTime(target.range_end),
            target.has_selection and ' [time selection]' or ' [whole MIDI item]')
        return
    end

    -- Reuse AssignPitches by feeding it just the timing fields.
    local input_notes = {}
    for _, n in ipairs(existing) do
        input_notes[#input_notes + 1] = { s = n.s, e = n.e }
    end

    local with_pitch, ps_or_err = AssignPitches(input_notes, trks.ref, audio_item_for_yin)
    if not with_pitch then S.status = 'Error'; S.last_result = ps_or_err; return end

    -- Collect only notes whose pitch actually changes.
    local changes = {}
    for i, n in ipairs(existing) do
        local new_pitch = with_pitch[i].pitch
        if new_pitch ~= n.old_pitch then
            changes[#changes + 1] = { n = n, new_pitch = new_pitch }
        end
    end
    local changed = #changes

    -- MIDI_SetNote does not register with REAPER's undo auto-detection (-1 flag).
    -- Delete + reinsert uses the same API as Generate and produces proper undo entries.
    r.PreventUIRefresh(1)
    r.Undo_BeginBlock()
    if changed > 0 then
        -- Delete in descending index order so earlier indices stay valid.
        table.sort(changes, function(a, b) return a.n.idx > b.n.idx end)
        for _, ch in ipairs(changes) do
            r.MIDI_DeleteNote(target.take, ch.n.idx)
        end
        -- Reinsert with new pitch; PPQ positions are still valid.
        for _, ch in ipairs(changes) do
            r.MIDI_InsertNote(target.take, ch.n.sel, ch.n.mute,
                ch.n.sppq, ch.n.eppq, ch.n.chan, ch.new_pitch, ch.n.vel, true)
        end
        r.MIDI_Sort(target.take)
    end
    r.Undo_EndBlock(
        ('Karaoke MIDI: reassigned pitch of %d/%d notes'):format(changed, #existing), -1)
    r.PreventUIRefresh(-1)

    -- Build result panel
    local lines = {
        ('Apply pitch changes: %d notes processed, %d pitches changed')
            :format(#existing, changed),
        ('Range: %s — %s  (%.3fs)%s'):format(
            FormatTime(target.range_start), FormatTime(target.range_end),
            target.range_end - target.range_start,
            target.has_selection and ' [time selection]' or ' [whole MIDI item]'),
    }
    if S.pitch_mode == MODE_REFERENCE then
        lines[#lines + 1] = ('Pitch source: Reference  ->  matched %d, fallback to default %d')
            :format(ps_or_err.ref_used, ps_or_err.ref_fallback)
    elseif S.pitch_mode == MODE_YIN then
        lines[#lines + 1] = ('Pitch source: Built-in  ->  detected %d, fallback to default %d')
            :format(ps_or_err.ref_used, ps_or_err.ref_fallback)
    end
    if ps_or_err.range_adjusted and ps_or_err.range_adjusted > 0 then
        lines[#lines + 1] = ('Pitch range adjusted: %d notes octave-shifted or clamped')
            :format(ps_or_err.range_adjusted)
    end

    S.status = 'Pitches applied.'
    S.last_result = table.concat(lines, '\n')
end

----------------------------------------------------------------------
-- Pitch slide scan
----------------------------------------------------------------------
-- Constants for the scan (not user-configurable yet — wait for feedback)

-- Classify the shape of a pitch trajectory from a list of pitch segments.
-- segs: list of {pc, median_midi, ...}, 2 or more entries, adjacent entries
-- always have different pitch classes (guaranteed by the merge step).
-- Returns one of: 'Slide up', 'Slide down', 'Scoop', 'Bend', 'Complex slide'.
local function ClassifySlide(segs)
    local dirs = {}
    for i = 2, #segs do
        local diff = segs[i].median_midi - segs[i - 1].median_midi
        dirs[#dirs + 1] = diff > 0 and 1 or -1
    end

    local all_up, all_down = true, true
    for _, d in ipairs(dirs) do
        if d < 0 then all_up   = false end
        if d > 0 then all_down = false end
    end
    if all_up   then return 'Slide up'   end
    if all_down then return 'Slide down' end

    local first, last = dirs[1], dirs[#dirs]
    if first < 0 and last > 0 then return 'Scoop' end
    if first > 0 and last < 0 then return 'Bend'  end
    return 'Complex slide'
end

local function ScanPitchSlidesAction()
    local tracks = GetTrackList()
    if #tracks == 0 then S.status = 'No tracks in project.'; S.last_result = nil; return end
    if S.audio_idx >= #tracks or S.midi_idx >= #tracks then
        S.status = 'Track selection out of range.'; S.last_result = nil; return
    end

    local audio_track = r.GetTrack(0, tracks[S.audio_idx + 1].idx)
    local midi_track  = r.GetTrack(0, tracks[S.midi_idx  + 1].idx)

    -- Find first audio item on the source track
    local audio_item
    for i = 0, r.CountTrackMediaItems(audio_track) - 1 do
        local item = r.GetTrackMediaItem(audio_track, i)
        local take = r.GetActiveTake(item)
        if take and not r.TakeIsMIDI(take) then audio_item = item; break end
    end
    if not audio_item then
        S.status = 'Error'
        S.last_result = 'No audio item found on the source track.'
        return
    end

    -- Find MIDI item and establish scan range (respects time selection)
    local sel_start, sel_end = GetTimeSelection()

    if not sel_start then
        local proceed = r.ShowMessageBox(
            'No time selection is active.\n\n' ..
            'Scan pitch slides will process the entire destination MIDI item.\n' ..
            'On a full song this can take 20 seconds or more, and the UI\n' ..
            'will be unresponsive until the scan completes.\n\n' ..
            'Save your project first in case of an unexpected crash.\n\n' ..
            'Press OK to continue, or Cancel to set a time selection first.',
            'Scan pitch slides — no time selection', 1)
        if proceed ~= 1 then return end
    end

    local midi_item, midi_take, range_start, range_end, has_sel

    if sel_start then
        for i = 0, r.CountTrackMediaItems(midi_track) - 1 do
            local item = r.GetTrackMediaItem(midi_track, i)
            local take = r.GetActiveTake(item)
            if take and r.TakeIsMIDI(take) then
                local pos = r.GetMediaItemInfo_Value(item, 'D_POSITION')
                local len = r.GetMediaItemInfo_Value(item, 'D_LENGTH')
                if pos < sel_end and pos + len > sel_start then
                    midi_item = item; midi_take = take
                    range_start = sel_start; range_end = sel_end
                    has_sel = true; break
                end
            end
        end
    end
    if not midi_item then
        midi_item, midi_take = FindFirstMIDIItem(midi_track)
        if not midi_item then
            S.status = 'Error'
            S.last_result = 'No MIDI item found on the destination track.'
            return
        end
        range_start = r.GetMediaItemInfo_Value(midi_item, 'D_POSITION')
        range_end   = range_start + r.GetMediaItemInfo_Value(midi_item, 'D_LENGTH')
        has_sel = false
    end

    -- Build PPQ -> lyric lookup from type-5 text events
    local lyric_at = {}
    local _, _, _, n_text = r.MIDI_CountEvts(midi_take)
    for i = 0, n_text - 1 do
        local ok, _, _, ppq, typ, msg = r.MIDI_GetTextSysexEvt(midi_take, i)
        if ok and typ == 5 then lyric_at[ppq] = msg end
    end

    -- Read notes in range (RB3 vocal pitch range only)
    local _, n_notes = r.MIDI_CountEvts(midi_take)
    local notes = {}
    for i = 0, n_notes - 1 do
        local ok, _, _, sppq, eppq, _, pitch = r.MIDI_GetNote(midi_take, i)
        if ok then
            local s_t = r.MIDI_GetProjTimeFromPPQPos(midi_take, sppq)
            local e_t = r.MIDI_GetProjTimeFromPPQPos(midi_take, eppq)
            if s_t >= range_start - 0.001 and s_t < range_end + 0.001
            and pitch >= RB3_MIN_PITCH and pitch <= RB3_MAX_PITCH then
                notes[#notes + 1] = {
                    s = s_t, e = e_t, pitch = pitch, lyric = lyric_at[sppq],
                }
            end
        end
    end

    if #notes == 0 then
        S.status = 'No notes in range.'
        S.last_result = ('Range: %s - %s%s\nNo notes to scan.'):format(
            FormatTime(range_start), FormatTime(range_end),
            has_sel and ' [time selection]' or ' [whole MIDI item]')
        return
    end

    local yctx, yerr = OpenYINContext(audio_item)
    if not yctx then S.status = 'Error'; S.last_result = yerr; return end

    local slide_results = {}
    local n_scanned, n_too_short, n_stable = 0, 0, 0

    for _, note in ipairs(notes) do
        local dur = note.e - note.s
        if dur < S.slide_min_note_ms * 0.001 then
            n_too_short = n_too_short + 1
        else
            n_scanned = n_scanned + 1
            local slide_win_s  = S.slide_win_ms  * 0.001
            local slide_step_s = S.slide_step_ms * 0.001
            local slide_skip_s = S.slide_skip_ms * 0.001

            -- Collect YIN samples every slide_step_s, skipping note edges
            local scan_s = note.s + slide_skip_s
            local scan_e = note.e - slide_skip_s
            local raw = {}
            local t = scan_s
            while t + slide_win_s <= scan_e do
                local p = SampleYINAt(yctx, t, slide_win_s)
                raw[#raw + 1] = {
                    t = t, midi = p, pc = p and (p % 12) or nil,
                }
                t = t + slide_step_s
            end

            -- Group consecutive valid samples by pitch class
            local segs = {}
            local cur
            for _, sp in ipairs(raw) do
                if sp.pc then
                    if not cur or cur.pc ~= sp.pc then
                        cur = {
                            pc = sp.pc, midi_list = { sp.midi },
                            t_start = sp.t, t_end = sp.t + slide_win_s,
                        }
                        segs[#segs + 1] = cur
                    else
                        cur.midi_list[#cur.midi_list + 1] = sp.midi
                        cur.t_end = sp.t + slide_win_s
                    end
                else
                    cur = nil  -- gap resets the current segment
                end
            end

            -- Compute median MIDI note and duration per segment
            for _, seg in ipairs(segs) do
                table.sort(seg.midi_list)
                seg.median_midi = seg.midi_list[math.floor(#seg.midi_list / 2) + 1]
                seg.duration = seg.t_end - seg.t_start
            end

            -- Filter: discard segments shorter than slide_min_seg_s
            local filtered = {}
            for _, seg in ipairs(segs) do
                if seg.duration >= S.slide_min_seg_ms * 0.001 then
                    filtered[#filtered + 1] = seg
                end
            end

            -- Merge adjacent segments that share a pitch class (after gap filtering)
            local merged = {}
            for _, seg in ipairs(filtered) do
                if #merged > 0 and merged[#merged].pc == seg.pc then
                    local last = merged[#merged]
                    for _, v in ipairs(seg.midi_list) do
                        last.midi_list[#last.midi_list + 1] = v
                    end
                    last.t_end    = seg.t_end
                    last.duration = last.t_end - last.t_start
                    table.sort(last.midi_list)
                    last.median_midi =
                        last.midi_list[math.floor(#last.midi_list / 2) + 1]
                else
                    merged[#merged + 1] = {
                        pc         = seg.pc,
                        midi_list  = seg.midi_list,
                        t_start    = seg.t_start,
                        t_end      = seg.t_end,
                        duration   = seg.duration,
                        median_midi = seg.median_midi,
                    }
                end
            end

            if #merged < 2 then
                n_stable = n_stable + 1
            else
                local shape  = ClassifySlide(merged)
                local from_p = merged[1].median_midi
                local to_p   = merged[#merged].median_midi

                -- Show the actual turning point, not just the middle index.
                -- Scoop: deepest dip among inner segments.
                -- Bend:  highest peak among inner segments.
                -- Slide up/down and Complex slide: no mid_p (no single
                -- representative point; Complex label conveys the complexity).
                local mid_p, mid_dur = nil, nil
                if shape == 'Scoop' and #merged >= 3 then
                    local min_midi = math.huge
                    for j = 2, #merged - 1 do
                        if merged[j].median_midi < min_midi then
                            min_midi = merged[j].median_midi
                            mid_dur  = merged[j].duration
                        end
                    end
                    mid_p = min_midi
                elseif shape == 'Bend' and #merged >= 3 then
                    local max_midi = -math.huge
                    for j = 2, #merged - 1 do
                        if merged[j].median_midi > max_midi then
                            max_midi = merged[j].median_midi
                            mid_dur  = merged[j].duration
                        end
                    end
                    mid_p = max_midi
                end

                slide_results[#slide_results + 1] = {
                    time       = note.s,
                    note_dur   = note.e - note.s,
                    note_pitch = note.pitch,
                    lyric      = note.lyric,
                    shape      = shape,
                    from_p     = from_p,
                    from_dur   = merged[1].duration,
                    to_p       = to_p,
                    to_dur     = merged[#merged].duration,
                    mid_p      = mid_p,
                    mid_dur    = mid_dur,
                }
            end
        end
    end

    CloseYINContext(yctx)

    -- Format result lines
    local lines = {
        ('Range: %s - %s%s'):format(
            FormatTime(range_start), FormatTime(range_end),
            has_sel and ' [time selection]' or ' [whole MIDI item]'),
        ('%d notes  |  %d scanned  |  %d too short (<%dms)  |  %d stable')
            :format(#notes, n_scanned, n_too_short, S.slide_min_note_ms, n_stable),
    }

    if #slide_results == 0 then
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'No pitch slides detected.'
    else
        lines[#lines + 1] = ('%d slide%s detected:')
            :format(#slide_results, #slide_results == 1 and '' or 's')
        lines[#lines + 1] = ''
        for _, res in ipairs(slide_results) do
            local note_name = PitchName(res.note_pitch)
            local lyric_tag = res.lyric
                and ('(%s "%s") '):format(note_name, res.lyric)
                or  ('(%s) '):format(note_name)
            local nd = res.note_dur
            local function pct(d)
                return math.max(1, math.floor(d / nd * 100 + 0.5))
            end
            local pitch_str
            if res.mid_p then
                pitch_str = ('%s (%d%%) -> %s (%d%%) -> %s (%d%%)'):format(
                    PitchName(res.from_p), pct(res.from_dur),
                    PitchName(res.mid_p),  pct(res.mid_dur),
                    PitchName(res.to_p),   pct(res.to_dur))
            else
                pitch_str = ('%s (%d%%) -> %s (%d%%)'):format(
                    PitchName(res.from_p), pct(res.from_dur),
                    PitchName(res.to_p),   pct(res.to_dur))
            end
            lines[#lines + 1] = ('%-26s  %s%-16s  %s'):format(
                FormatTime(res.time), lyric_tag, res.shape, pitch_str)
        end
    end

    S.status = ('%d pitch slide%s detected'):format(
        #slide_results, #slide_results == 1 and '' or 's')
    S.last_result = table.concat(lines, '\n')
end

local function ClearLyricsAction()
    local tracks = GetTrackList()
    if #tracks == 0 or S.midi_idx >= #tracks then
        S.status = 'Error'; S.last_result = 'Invalid MIDI destination track.'; return
    end
    local midi_track = r.GetTrack(0, tracks[S.midi_idx + 1].idx)
    local _, midi_take = FindFirstMIDIItem(midi_track)
    if not midi_take then
        S.status = 'Error'
        S.last_result = 'No MIDI item found on the destination track.'
        return
    end

    r.PreventUIRefresh(1)
    r.Undo_BeginBlock()
    local cleared = ClearLyricEvents(midi_take)
    r.MIDI_Sort(midi_take)
    r.Undo_EndBlock(('Vocal MIDI: cleared %d lyric events'):format(cleared), -1)
    r.PreventUIRefresh(-1)

    S.status = ('Cleared %d lyric events.'):format(cleared)
    S.last_result = nil
end

local function AssignLyricsAction()
    if S.lyrics_path == '' then
        S.status = 'No lyrics file selected.'
        S.last_result = 'Use Auto-detect or Browse to select a lyrics file first.'
        return
    end

    local lyrics, lerr = ParseLyricsFile(S.lyrics_path)
    if not lyrics then S.status = 'Error'; S.last_result = lerr; return end

    local tracks = GetTrackList()
    if #tracks == 0 or S.midi_idx >= #tracks then
        S.status = 'Error'; S.last_result = 'Invalid MIDI destination track.'; return
    end
    local midi_track = r.GetTrack(0, tracks[S.midi_idx + 1].idx)
    local _, midi_take = FindFirstMIDIItem(midi_track)
    if not midi_take then
        S.status = 'Error'
        S.last_result = 'No MIDI item found on the destination track.'
        return
    end

    -- Read all notes: vocal range + phrase markers (whole take, time selection ignored)
    local scoped = {}
    local phrase_markers = {}
    local _, n_notes = r.MIDI_CountEvts(midi_take)
    for i = 0, n_notes - 1 do
        local ok, _, _, sppq, eppq, _, p = r.MIDI_GetNote(midi_take, i)
        if ok then
            local s_t = r.MIDI_GetProjTimeFromPPQPos(midi_take, sppq)
            local e_t = r.MIDI_GetProjTimeFromPPQPos(midi_take, eppq)
            if p >= RB3_MIN_PITCH and p <= RB3_MAX_PITCH then
                scoped[#scoped + 1] = { s = s_t, e = e_t }
            elseif p == RB3_PHRASE_PITCH then
                phrase_markers[#phrase_markers + 1] = { s = s_t }
            end
        end
    end
    table.sort(scoped,         function(a, b) return a.s < b.s end)
    table.sort(phrase_markers, function(a, b) return a.s < b.s end)

    if #scoped == 0 then
        S.status = 'No notes in range.'
        S.last_result = 'No notes in the RB3 vocal range found on the destination take.'
        return
    end

    r.PreventUIRefresh(1)
    r.Undo_BeginBlock()

    local cleared = ClearLyricEvents(midi_take)

    local assigned = {}  -- { s, lyric } for validation
    local inserted = 0
    for i, n in ipairs(scoped) do
        local lyric = lyrics[i]
        if lyric then
            local ppq = r.MIDI_GetPPQPosFromProjTime(midi_take, n.s)
            r.MIDI_InsertTextSysexEvt(midi_take, false, false, ppq, 5, lyric)
            inserted = inserted + 1
        end
        assigned[i] = { s = n.s, lyric = lyric }
    end
    r.MIDI_Sort(midi_take)
    r.Undo_EndBlock(('Vocal MIDI: assigned %d lyrics'):format(inserted), -1)
    r.PreventUIRefresh(-1)

    -- Build result
    local lines = {}
    lines[#lines + 1] = ('Lyrics assigned: %d syllables added'):format(inserted)
    lines[#lines + 1] = 'Scope: whole take'
    lines[#lines + 1] = ('Cleared %d existing lyric events first'):format(cleared)

    -- Count mismatch
    local n_notes_in = #scoped
    local n_lyrics_in = #lyrics
    if n_notes_in ~= n_lyrics_in then
        lines[#lines + 1] = ''
        if n_notes_in > n_lyrics_in then
            lines[#lines + 1] = ('Warning: %d notes, %d lyrics — last %d notes have no lyric')
                :format(n_notes_in, n_lyrics_in, n_notes_in - n_lyrics_in)
        else
            lines[#lines + 1] = ('Warning: %d notes, %d lyrics — last %d lyrics are unused')
                :format(n_notes_in, n_lyrics_in, n_lyrics_in - n_notes_in)
        end
    end

    -- Phrase capitalization check
    lines[#lines + 1] = ''
    if #phrase_markers == 0 then
        lines[#lines + 1] = 'Phrase markers: none found — cannot validate capitalization.'
    else
        local violations = {}
        for _, pm in ipairs(phrase_markers) do
            for _, a in ipairs(assigned) do
                if a.s >= pm.s - 0.001 and a.lyric then
                    local first = a.lyric:sub(1, 1)
                    if first ~= first:upper() then
                        violations[#violations + 1] = { s = a.s, lyric = a.lyric }
                    end
                    break
                end
            end
        end
        if #violations == 0 then
            lines[#lines + 1] = ('Phrase capitalization: OK — all %d phrases start with a capital letter.')
                :format(#phrase_markers)
        else
            lines[#lines + 1] = ('Phrase capitalization: %d violation(s):'):format(#violations)
            for _, v in ipairs(violations) do
                lines[#lines + 1] = ('  %s  "%s"'):format(FormatTime(v.s), v.lyric)
            end
        end
    end

    S.status = ('Lyrics assigned: %d notes.'):format(inserted)
    S.last_result = table.concat(lines, '\n')
end

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local function SectionHeader(title, reset_label, reset_fn, reset_tip)
    r.ImGui_Text(ctx, title)
    r.ImGui_SameLine(ctx)
    local avail_x = r.ImGui_GetContentRegionAvail(ctx)
    local btn_w = 80
    if avail_x > btn_w + 4 then
        r.ImGui_SetCursorPosX(ctx, r.ImGui_GetCursorPosX(ctx) + (avail_x - btn_w))
    end
    if r.ImGui_SmallButton(ctx, reset_label) then
        reset_fn()
    end
    Tooltip(reset_tip)
end

local _active_proj = r.EnumProjects(-1, '')

local function Loop()
    -- Detect project switch (tabs). Reinitialize if the active project changed.
    local proj = r.EnumProjects(-1, '')
    if proj ~= _active_proj then
        _active_proj  = proj
        S.audio_idx   = 0
        S.midi_idx    = 0
        S.ref_idx     = 0
        S.lyrics_path = ''
        S.last_result = nil
        local loaded = LoadSettings()
        S.status = loaded and 'Project switched: loaded saved settings.'
                           or 'Project switched.'
        SetDefaultTracks()
        AutoDetectLyricsFile()
    end

    local tracks = GetTrackList()
    local sel_s, sel_e = GetTimeSelection()

    r.ImGui_SetNextWindowSize(ctx, 580, 1060, r.ImGui_Cond_FirstUseEver())
    local visible, open = r.ImGui_Begin(ctx, 'Vocal MIDI Generator', true)
    if visible then
        ----------------------------------------------------------------
        -- Global: track selectors (MIDI first, then audio source)
        ----------------------------------------------------------------
        r.ImGui_Text(ctx, 'MIDI destination track  (must already contain a MIDI item)')
        S.midi_idx = TrackCombo('##midi', S.midi_idx, tracks)

        r.ImGui_Spacing(ctx)
        r.ImGui_Text(ctx, 'Audio source track')
        S.audio_idx = TrackCombo('##audio', S.audio_idx, tracks)

        if sel_s then
            r.ImGui_Spacing(ctx)
            r.ImGui_Text(ctx, ('Time selection: %s — %s'):format(FormatTime(sel_s), FormatTime(sel_e)))
        end

        r.ImGui_Separator(ctx)

        ----------------------------------------------------------------
        -- Button widths — computed once, used across all tabs
        ----------------------------------------------------------------
        local _bp    = 40
        local bw_at  = r.ImGui_CalcTextSize(ctx, 'Auto-tune from reference') + _bp
        local bw_ayt = r.ImGui_CalcTextSize(ctx, 'Auto-tune YIN from reference') + _bp
        local bw_dry = r.ImGui_CalcTextSize(ctx, 'Dry run') + _bp
        local bw_gen = r.ImGui_CalcTextSize(ctx, 'Generate (append)') + _bp
        local bw_grp = r.ImGui_CalcTextSize(ctx, 'Generate (replace)') + _bp
        local bw_app = r.ImGui_CalcTextSize(ctx, 'Apply pitch changes') + _bp
        local bw_und = r.ImGui_CalcTextSize(ctx, 'Undo') + _bp
        local bw_sld = r.ImGui_CalcTextSize(ctx, 'Scan pitch slides') + _bp
        local bw_lad = r.ImGui_CalcTextSize(ctx, 'Auto-detect') + _bp
        local bw_lbr = r.ImGui_CalcTextSize(ctx, 'Browse...') + _bp
        local bw_lcl = r.ImGui_CalcTextSize(ctx, 'Clear lyrics') + _bp
        local bw_las = r.ImGui_CalcTextSize(ctx, 'Assign lyrics') + _bp

        ----------------------------------------------------------------
        -- Tab bar
        ----------------------------------------------------------------
        if r.ImGui_BeginTabBar(ctx, 'MainTabs') then

            ------------------------------------------------------------
            -- Tab: General
            ------------------------------------------------------------
            if r.ImGui_BeginTabItem(ctx, 'General') then
                r.ImGui_Spacing(ctx)
                r.ImGui_Text(ctx, 'Settings')
                if r.ImGui_Button(ctx, 'Save', 90, 24) then
                    SaveSettings()
                    S.status = 'Settings saved to project.'
                end
                Tooltip(TIPS.save_settings)
                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, 'Load', 90, 24) then
                    if LoadSettings() then
                        S.status = 'Settings loaded from project.'
                    else
                        S.status = 'No saved settings found in this project.'
                    end
                end
                Tooltip(TIPS.load_settings)
                r.ImGui_EndTabItem(ctx)
            end

            ------------------------------------------------------------
            -- Tab: Note Placement
            ------------------------------------------------------------
            if r.ImGui_BeginTabItem(ctx, 'Note Placement') then
                r.ImGui_Spacing(ctx)
                SectionHeader('Note Placement', 'Reset##det', ResetDetection, TIPS.reset_detection)

                if r.ImGui_Button(ctx, 'Auto-tune from reference', bw_at, 24) then
                    RunAutoTune()
                end
                Tooltip(TIPS.autotune)
                r.ImGui_Spacing(ctx)

                local _
                _, S.rms_threshold = r.ImGui_SliderDouble(ctx, 'RMS threshold',
                    S.rms_threshold, 0.001, 0.5, '%.4f')
                SliderTooltip(TIPS.rms_threshold)

                local lpf_fmt = (S.lpf_cutoff_hz > 0) and '%.0f Hz' or 'Off'
                _, S.lpf_cutoff_hz = r.ImGui_SliderDouble(ctx, 'Low-pass cutoff',
                    S.lpf_cutoff_hz, 0, 8000, lpf_fmt)
                SliderTooltip(TIPS.lpf_cutoff)

                local split_fmt = (S.split_ratio > 0) and '%.0f%%' or 'Off'
                _, S.split_ratio = r.ImGui_SliderDouble(ctx, 'Peak-split ratio',
                    S.split_ratio, 0, 95, split_fmt)
                SliderTooltip(TIPS.split_ratio)

                _, S.min_offset_ms = r.ImGui_SliderDouble(ctx, 'Min offset to next note (ms)',
                    S.min_offset_ms, 0, 500, '%.0f')
                SliderTooltip(TIPS.min_offset_ms)

                _, S.min_note_ms = r.ImGui_SliderDouble(ctx, 'Min note length (ms)',
                    S.min_note_ms, 10, 500, '%.0f')
                SliderTooltip(TIPS.min_note_ms)

                _, S.window_ms = r.ImGui_SliderDouble(ctx, 'RMS window (ms)',
                    S.window_ms, 5, 100, '%.0f')
                SliderTooltip(TIPS.window_ms)

                r.ImGui_Separator(ctx)
                SectionHeader('MIDI output', 'Reset##midi', ResetMIDIOutput, TIPS.reset_midi)
                _, S.velocity = r.ImGui_SliderInt(ctx, 'Velocity', S.velocity, 1, 127)
                SliderTooltip(TIPS.velocity)

                local pfmt = ('%%d  (%s)'):format(PitchName(S.pitch))
                _, S.pitch = r.ImGui_SliderInt(ctx, 'Default pitch', S.pitch, RB3_MIN_PITCH, RB3_MAX_PITCH, pfmt)
                SliderTooltip(TIPS.pitch)

                r.ImGui_Separator(ctx)
                if r.ImGui_Button(ctx, 'Dry run', bw_dry, 24) then
                    Preview()
                end
                Tooltip(TIPS.preview)

                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, 'Generate (append)', bw_gen, 24) then
                    Generate()
                end
                Tooltip(TIPS.generate)

                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, 'Generate (replace)', bw_grp, 24) then
                    Generate(true)
                end
                Tooltip(TIPS.generate_replace)

                local undo_str = r.Undo_CanUndo2(0) or ''
                local can_undo = undo_str ~= ''
                r.ImGui_SameLine(ctx)
                if not can_undo then r.ImGui_BeginDisabled(ctx) end
                if r.ImGui_Button(ctx, 'Undo', bw_und, 24) then
                    r.Undo_DoUndo2(0)
                end
                if not can_undo then r.ImGui_EndDisabled(ctx) end
                if can_undo then Tooltip('Undo: ' .. undo_str) end

                r.ImGui_EndTabItem(ctx)
            end

            ------------------------------------------------------------
            -- Tab: Pitch
            ------------------------------------------------------------
            if r.ImGui_BeginTabItem(ctx, 'Pitch') then
                r.ImGui_Spacing(ctx)
                SectionHeader('Pitch', 'Reset##pitch', ResetPitch, TIPS.reset_pitch)

                r.ImGui_Text(ctx, 'Pitch source:')
                if r.ImGui_RadioButton(ctx, 'Built-in detection', S.pitch_mode == MODE_YIN) then
                    S.pitch_mode = MODE_YIN
                end
                Tooltip(TIPS.pitch_mode_yin)
                r.ImGui_SameLine(ctx)
                if r.ImGui_RadioButton(ctx, 'Reference MIDI', S.pitch_mode == MODE_REFERENCE) then
                    S.pitch_mode = MODE_REFERENCE
                end
                Tooltip(TIPS.pitch_mode_reference)

                local yin_disabled = (S.pitch_mode ~= MODE_YIN)
                if yin_disabled then r.ImGui_BeginDisabled(ctx) end

                r.ImGui_Spacing(ctx)
                r.ImGui_Text(ctx, 'Built-in detection settings')
                if r.ImGui_Button(ctx, 'Auto-tune YIN from reference', bw_ayt, 24) then
                    RunAutoTuneYIN()
                end
                Tooltip(TIPS.autotune_yin)
                r.ImGui_Spacing(ctx)

                local _
                _, S.yin_threshold = r.ImGui_SliderDouble(ctx, 'YIN threshold',
                    S.yin_threshold, 0.01, 0.5, '%.3f')
                SliderTooltip(TIPS.yin_threshold)
                _, S.yin_min_freq = r.ImGui_SliderInt(ctx, 'Min frequency (Hz)',
                    S.yin_min_freq, 40, 400)
                SliderTooltip(TIPS.yin_min_freq)
                _, S.yin_max_freq = r.ImGui_SliderInt(ctx, 'Max frequency (Hz)',
                    S.yin_max_freq, 200, 2000)
                SliderTooltip(TIPS.yin_max_freq)
                if S.yin_min_freq >= S.yin_max_freq then S.yin_max_freq = S.yin_min_freq + 1 end
                _, S.yin_window_ms = r.ImGui_SliderDouble(ctx, 'YIN window (ms)',
                    S.yin_window_ms, 10, 100, '%.0f')
                SliderTooltip(TIPS.yin_window_ms)

                if yin_disabled then r.ImGui_EndDisabled(ctx) end

                local ref_disabled = (S.pitch_mode ~= MODE_REFERENCE)
                if ref_disabled then r.ImGui_BeginDisabled(ctx) end

                r.ImGui_Spacing(ctx)
                r.ImGui_Text(ctx, 'Reference MIDI track')
                S.ref_idx = TrackCombo('##refmidi', S.ref_idx, tracks)
                Tooltip(TIPS.ref_track)

                _, S.ref_search_ms = r.ImGui_SliderDouble(ctx, 'Search tolerance (ms)',
                    S.ref_search_ms, 50, 2000, '%.0f')
                SliderTooltip(TIPS.ref_search)

                if ref_disabled then r.ImGui_EndDisabled(ctx) end

                r.ImGui_Spacing(ctx)
                r.ImGui_Text(ctx, 'Pitch range constraints')

                local cb_changed
                cb_changed, S.min_pitch_enabled = r.ImGui_Checkbox(ctx, '##minpe', S.min_pitch_enabled)
                Tooltip(TIPS.min_pitch_enabled)
                r.ImGui_SameLine(ctx)
                if not S.min_pitch_enabled then r.ImGui_BeginDisabled(ctx) end
                local minfmt = ('%%d  (%s)'):format(PitchName(S.min_pitch))
                _, S.min_pitch = r.ImGui_SliderInt(ctx, 'Min pitch', S.min_pitch, RB3_MIN_PITCH, RB3_MAX_PITCH, minfmt)
                SliderTooltip(TIPS.min_pitch)
                if not S.min_pitch_enabled then r.ImGui_EndDisabled(ctx) end

                cb_changed, S.max_pitch_enabled = r.ImGui_Checkbox(ctx, '##maxpe', S.max_pitch_enabled)
                Tooltip(TIPS.max_pitch_enabled)
                r.ImGui_SameLine(ctx)
                if not S.max_pitch_enabled then r.ImGui_BeginDisabled(ctx) end
                local maxfmt = ('%%d  (%s)'):format(PitchName(S.max_pitch))
                _, S.max_pitch = r.ImGui_SliderInt(ctx, 'Max pitch', S.max_pitch, RB3_MIN_PITCH, RB3_MAX_PITCH, maxfmt)
                SliderTooltip(TIPS.max_pitch)
                if not S.max_pitch_enabled then r.ImGui_EndDisabled(ctx) end

                if S.min_pitch_enabled and S.max_pitch_enabled and S.min_pitch > S.max_pitch then
                    S.max_pitch = S.min_pitch
                end

                r.ImGui_Separator(ctx)
                if r.ImGui_Button(ctx, 'Apply pitch changes', bw_app, 24) then
                    ApplyPitchChangesAction()
                end
                Tooltip(TIPS.apply_pitch)

                local undo_str = r.Undo_CanUndo2(0) or ''
                local can_undo = undo_str ~= ''
                r.ImGui_SameLine(ctx)
                if not can_undo then r.ImGui_BeginDisabled(ctx) end
                if r.ImGui_Button(ctx, 'Undo', bw_und, 24) then
                    r.Undo_DoUndo2(0)
                end
                if not can_undo then r.ImGui_EndDisabled(ctx) end
                if can_undo then Tooltip('Undo: ' .. undo_str) end

                r.ImGui_EndTabItem(ctx)
            end

            ------------------------------------------------------------
            -- Tab: Lyrics
            ------------------------------------------------------------
            if r.ImGui_BeginTabItem(ctx, 'Lyrics') then
                r.ImGui_Spacing(ctx)

                local lyric_basename = S.lyrics_path ~= ''
                    and (S.lyrics_path:match('[/\\]([^/\\]+)$') or S.lyrics_path)
                    or '(no file selected)'
                r.ImGui_TextDisabled(ctx, 'File: ' .. lyric_basename)
                if S.lyrics_path ~= '' then Tooltip(S.lyrics_path) end

                if r.ImGui_Button(ctx, 'Auto-detect', bw_lad, 24) then
                    local proj_path = r.GetProjectPath('')
                    if proj_path and proj_path ~= '' then
                        local sep = (proj_path:sub(-1) == '/' or proj_path:sub(-1) == '\\') and '' or '/'
                        local candidate = proj_path .. sep .. 'lyrics.txt'
                        local f = io.open(candidate, 'r')
                        if f then
                            f:close()
                            S.lyrics_path = candidate
                            S.status = 'Lyrics file found: lyrics.txt'
                            S.last_result = nil
                        else
                            S.status = 'No lyrics.txt found in project folder.'
                            S.last_result = nil
                        end
                    else
                        S.status = 'Project has no saved path — save the project first.'
                        S.last_result = nil
                    end
                end
                Tooltip(TIPS.lyrics_auto_detect)

                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, 'Browse...', bw_lbr, 24) then
                    _browse_tooltip_suppressed = true
                    local proj_path = r.GetProjectPath('')
                    local start = ''
                    if proj_path and proj_path ~= '' then
                        local sep = (proj_path:sub(-1) == '/' or proj_path:sub(-1) == '\\') and '' or '\\'
                        start = proj_path .. sep
                    end
                    local ok, path = r.GetUserFileNameForRead(start, 'Select lyrics file', 'txt')
                    if ok and path and path ~= '' then
                        if not path:match('%.[Tt][Xx][Tt]$') then
                            S.status = 'Invalid file — please select a .txt file.'
                            S.last_result = nil
                        else
                            S.lyrics_path = path
                            S.status = 'Lyrics file: ' .. (path:match('[/\\]([^/\\]+)$') or path)
                            S.last_result = nil
                        end
                    end
                end
                if r.ImGui_IsItemHovered(ctx) and not r.ImGui_IsItemActive(ctx) and not _browse_tooltip_suppressed then
                    r.ImGui_SetTooltip(ctx, TIPS.lyrics_browse)
                elseif not r.ImGui_IsItemHovered(ctx) then
                    _browse_tooltip_suppressed = false
                end

                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, 'Clear lyrics', bw_lcl, 24) then
                    ClearLyricsAction()
                end
                Tooltip(TIPS.lyrics_clear)

                local assign_disabled = (S.lyrics_path == '')
                r.ImGui_SameLine(ctx)
                if assign_disabled then r.ImGui_BeginDisabled(ctx) end
                if r.ImGui_Button(ctx, 'Assign lyrics', bw_las, 24) then
                    AssignLyricsAction()
                end
                if assign_disabled then r.ImGui_EndDisabled(ctx) end
                Tooltip(TIPS.lyrics_assign)

                r.ImGui_EndTabItem(ctx)
            end

            ------------------------------------------------------------
            -- Tab: Pitch slide
            ------------------------------------------------------------
            if r.ImGui_BeginTabItem(ctx, 'Pitch slide') then
                r.ImGui_Spacing(ctx)
                SectionHeader('Slide Scan', 'Reset##slides', ResetSlides, TIPS.reset_slides)
                _, S.slide_min_note_ms = r.ImGui_SliderInt(ctx, 'Min note length (ms)##sld', S.slide_min_note_ms, 20, 500)
                S.slide_min_note_ms = math.max(20,  math.floor(S.slide_min_note_ms / 10 + 0.5) * 10)
                SliderTooltip(TIPS.slide_min_note_ms)
                _, S.slide_min_seg_ms  = r.ImGui_SliderInt(ctx, 'Min segment (ms)##sld',     S.slide_min_seg_ms,   5, 100)
                S.slide_min_seg_ms  = math.max(5,   math.floor(S.slide_min_seg_ms  /  5 + 0.5) *  5)
                SliderTooltip(TIPS.slide_min_seg_ms)
                _, S.slide_skip_ms     = r.ImGui_SliderInt(ctx, 'Edge skip (ms)##sld',       S.slide_skip_ms,      0,  50)
                S.slide_skip_ms     = math.max(0,   math.floor(S.slide_skip_ms     /  5 + 0.5) *  5)
                SliderTooltip(TIPS.slide_skip_ms)
                _, S.slide_step_ms     = r.ImGui_SliderInt(ctx, 'Sample step (ms)##sld',     S.slide_step_ms,      5,  50)
                S.slide_step_ms     = math.max(5,   math.floor(S.slide_step_ms     /  5 + 0.5) *  5)
                SliderTooltip(TIPS.slide_step_ms)
                _, S.slide_win_ms      = r.ImGui_SliderInt(ctx, 'Sample window (ms)##sld',   S.slide_win_ms,      10,  50)
                S.slide_win_ms      = math.max(10,  math.floor(S.slide_win_ms      /  5 + 0.5) *  5)
                SliderTooltip(TIPS.slide_win_ms)
                local min_slidable_ms = S.slide_skip_ms * 2 + S.slide_min_seg_ms * 2
                if min_slidable_ms > S.slide_min_note_ms then
                    r.ImGui_Spacing(ctx)
                    r.ImGui_TextColored(ctx, 0xFFAA00FF,
                        ('! Min segment \xc3\x972 + Edge skip \xc3\x972 = %dms exceeds Min note length (%dms).')
                            :format(min_slidable_ms, S.slide_min_note_ms))
                    r.ImGui_TextColored(ctx, 0xFFAA00FF,
                        '  No slides can be detected with these settings.')
                end
                r.ImGui_Separator(ctx)
                SectionHeader('YIN Detection', 'Reset##yin', ResetYIN, TIPS.reset_yin)
                _, S.yin_threshold = r.ImGui_SliderDouble(ctx, 'YIN threshold',
                    S.yin_threshold, 0.01, 0.5, '%.3f')
                SliderTooltip(TIPS.yin_threshold)
                _, S.yin_min_freq = r.ImGui_SliderInt(ctx, 'Min frequency (Hz)',
                    S.yin_min_freq, 40, 400)
                SliderTooltip(TIPS.yin_min_freq)
                _, S.yin_max_freq = r.ImGui_SliderInt(ctx, 'Max frequency (Hz)',
                    S.yin_max_freq, 200, 2000)
                SliderTooltip(TIPS.yin_max_freq)
                if S.yin_min_freq >= S.yin_max_freq then S.yin_max_freq = S.yin_min_freq + 1 end
                r.ImGui_Separator(ctx)
                if r.ImGui_Button(ctx, 'Scan pitch slides', bw_sld, 24) then
                    ScanPitchSlidesAction()
                end
                Tooltip(TIPS.scan_slides)
                r.ImGui_EndTabItem(ctx)
            end

            r.ImGui_EndTabBar(ctx)
        end

        ----------------------------------------------------------------
        -- Global: status and result panel
        ----------------------------------------------------------------
        r.ImGui_Spacing(ctx)
        r.ImGui_Text(ctx, S.status)
        if S.last_result then
            r.ImGui_Separator(ctx)
            for line in S.last_result:gmatch('([^\n]*)\n?') do
                if line ~= '' then
                    r.ImGui_Text(ctx, line)
                else
                    r.ImGui_Spacing(ctx)
                end
            end
        end

        r.ImGui_End(ctx)
    end

    if open then r.defer(Loop) end
end

r.defer(Loop)
