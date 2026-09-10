/**
 * Shared time-range control. Presents user-facing ranges only; the caller
 * decides how (or whether) a preset maps to a Phase 7 request via the helpers
 * in ../time/ranges.
 */

import { PRESET_LABELS, TIME_RANGE_PRESETS } from "../time/ranges";
import type { DataKind, TimeRangePreset } from "../time/ranges";
import { isPresetSupported } from "../time/ranges";

export function TimeRangePicker({
  value,
  onChange,
  /** When set, presets the Phase 7 API can't serve for this data kind are
   *  shown disabled rather than silently misbehaving. */
  dataKind,
  now,
}: {
  value: TimeRangePreset;
  onChange: (preset: TimeRangePreset) => void;
  dataKind?: DataKind;
  now?: Date;
}) {
  return (
    <div className="time-range-picker" role="group" aria-label="Time range">
      {TIME_RANGE_PRESETS.map((preset) => {
        const disabled = dataKind ? !isPresetSupported(preset, dataKind, now) : false;
        return (
          <button
            key={preset}
            type="button"
            className="time-range-option"
            aria-pressed={value === preset}
            disabled={disabled}
            title={disabled ? "Not available for this data at present" : undefined}
            onClick={() => onChange(preset)}
          >
            {PRESET_LABELS[preset]}
          </button>
        );
      })}
    </div>
  );
}
