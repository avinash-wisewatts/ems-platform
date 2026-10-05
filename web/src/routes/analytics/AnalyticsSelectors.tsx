/**
 * Analytics filter-panel sections (F4): Assets, Data points, Resolution,
 * Phase type and the disabled Comparison placeholder. Each section is a
 * collapsible row -- title on the left, the current choice on the right --
 * over a controlled view of the F3 draft; the rules live in selectorGroups.ts
 * and analyticsQuery.ts. Screen specification:
 * docs/07-features/analytics/README.md; visual reference: the Analytics View
 * requirements document (sidebar rows, group checkboxes, toggle buttons).
 */
import { useEffect, useId, useMemo, useRef, useState, type ReactNode } from "react";
import type {
  AnalyticsCatalogAsset,
  AnalyticsCatalogResponse,
  AnalyticsPhase,
  AnalyticsRequestedResolution,
} from "../../api/types";
import type { CalendarRange } from "../../time/calendarRanges";
import { MESSAGES, RESOLUTION_OPTIONS, isResolutionAvailable } from "./analyticsQuery";
import {
  dataPointVisualOrder,
  fillToLimit,
  groupAssets,
  groupDataPoints,
  siteDataPoints,
  visualOrder,
  type AssetGrouping,
} from "./selectorGroups";

// ---- Shared pieces ----------------------------------------------------------------

export function Chevron({ open }: { open: boolean }) {
  return (
    <svg
      className={`analytics-chevron${open ? " analytics-chevron--open" : ""}`}
      viewBox="0 0 16 16"
      width="14"
      height="14"
      aria-hidden="true"
    >
      <path d="M4 6l4 4 4-4" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

/** One collapsible sidebar row: title, current choice, chevron; body below. */
export function FilterSection({
  id,
  title,
  summary,
  summaryTestId,
  defaultOpen = false,
  children,
}: {
  id: string;
  title: string;
  summary: ReactNode;
  summaryTestId?: string;
  defaultOpen?: boolean;
  children: ReactNode;
}) {
  const [open, setOpen] = useState(defaultOpen);
  const bodyId = `${useId()}-body`;
  return (
    <section className={`filter-section${open ? " filter-section--open" : ""}`} data-testid={`filter-section-${id}`}>
      <h3 className="filter-section__heading">
        <button
          type="button"
          className="filter-section__toggle"
          aria-expanded={open}
          aria-controls={bodyId}
          onClick={() => setOpen((o) => !o)}
        >
          <span className="filter-section__title">{title}</span>
          <span className="filter-section__summary" data-testid={summaryTestId}>
            {summary}
          </span>
          <Chevron open={open} />
        </button>
      </h3>
      {open ? (
        <div className="filter-section__body" id={bodyId}>
          {children}
        </div>
      ) : null}
    </section>
  );
}

function GroupCheckbox({
  checked,
  indeterminate,
  label,
  onChange,
}: {
  checked: boolean;
  indeterminate: boolean;
  label: string;
  onChange: () => void;
}) {
  const ref = useRef<HTMLInputElement>(null);
  useEffect(() => {
    if (ref.current) ref.current.indeterminate = indeterminate;
  }, [indeterminate]);
  return <input ref={ref} type="checkbox" className="analytics-check" checked={checked} aria-label={label} onChange={onChange} />;
}

function useExpanded() {
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(new Set());
  const toggle = (key: string) =>
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  return { expanded, toggle };
}

function SearchBox({ label, placeholder, value, onChange }: { label: string; placeholder: string; value: string; onChange: (v: string) => void }) {
  return (
    <div className="analytics-search">
      <svg className="analytics-search__icon" viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
        <circle cx="7" cy="7" r="4.5" fill="none" stroke="currentColor" strokeWidth="1.5" />
        <path d="M10.5 10.5L14 14" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
      </svg>
      <input
        type="search"
        className="analytics-search__input"
        placeholder={placeholder}
        aria-label={label}
        value={value}
        onChange={(e) => onChange(e.target.value)}
      />
    </div>
  );
}

function BulkActions({ onSelectAll, onClearAll }: { onSelectAll: () => void; onClearAll: () => void }) {
  return (
    <div className="analytics-bulk">
      <button type="button" className="analytics-link" onClick={onSelectAll}>
        Select All
      </button>
      <button type="button" className="analytics-link" onClick={onClearAll}>
        Clear All
      </button>
    </div>
  );
}

/** A single-choice set of toggle buttons (native radios, styled). */
function Segmented<T extends string>({
  name,
  label,
  options,
  value,
  onChange,
  isDisabled,
  variant = "row",
}: {
  name: string;
  label: string;
  options: readonly { value: T; label: string; accessibleName?: string }[];
  value: T;
  onChange: (value: T) => void;
  isDisabled?: (value: T) => boolean;
  variant?: "row" | "grid";
}) {
  const groupName = `${useId()}-${name}`;
  return (
    <div className={`analytics-segmented analytics-segmented--${variant}`} role="radiogroup" aria-label={label}>
      {options.map((option) => {
        const checked = option.value === value;
        const disabled = isDisabled?.(option.value) ?? false;
        return (
          <label
            key={option.value}
            className={`analytics-segmented__option${checked ? " is-checked" : ""}${disabled ? " is-disabled" : ""}`}
          >
            <input
              type="radio"
              className="visually-hidden"
              name={groupName}
              checked={checked}
              disabled={disabled}
              aria-label={option.accessibleName}
              onChange={() => onChange(option.value)}
            />
            {option.label}
          </label>
        );
      })}
    </div>
  );
}

// ---- Assets (D37, D38, D44, D65, D71, D72) -------------------------------------

function assetSummary(assets: readonly AnalyticsCatalogAsset[], selected: readonly string[]): string {
  if (selected.length === 0) return "None";
  if (selected.length === 1) return assets.find((a) => a.asset_id === selected[0])?.asset_name ?? "1 asset";
  return `${selected.length} of ${assets.length}`;
}

export function AssetSelector({
  assets,
  selected,
  maxAssets,
  onToggle,
  onSetAssets,
}: {
  assets: readonly AnalyticsCatalogAsset[];
  selected: readonly string[];
  maxAssets: number;
  onToggle: (assetId: string) => void;
  onSetAssets: (assetIds: string[]) => void;
}) {
  const [grouping, setGrouping] = useState<AssetGrouping>("space");
  const [search, setSearch] = useState("");
  const { expanded, toggle } = useExpanded();
  const groups = useMemo(() => groupAssets(assets, grouping, search), [assets, grouping, search]);
  const atLimit = selected.length >= maxAssets;
  const searching = search.trim() !== "";

  return (
    <FilterSection id="assets" title="Assets" summary={assetSummary(assets, selected)} summaryTestId="asset-selected-count" defaultOpen>
      <div className="analytics-selector" data-testid="asset-selector">
        <SearchBox label="Search assets" placeholder="Search assets…" value={search} onChange={setSearch} />
        <BulkActions
          onSelectAll={() => onSetAssets(fillToLimit(selected, visualOrder(groups), maxAssets).selection)}
          onClearAll={() => onSetAssets([])}
        />
        <div className="analytics-selector__grouping">
          <span className="analytics-selector__caption" aria-hidden="true">
            Group by
          </span>
          <Segmented<AssetGrouping>
            name="asset-grouping"
            label="Asset grouping"
            options={[
              { value: "space", label: "Space", accessibleName: "Group by Space" },
              { value: "assetType", label: "Asset Type", accessibleName: "Group by Asset Type" },
            ]}
            value={grouping}
            onChange={setGrouping}
          />
        </div>
        {atLimit ? (
          <p className="analytics-selector__limit" role="status" data-testid="asset-limit-reached">
            {MESSAGES.assetLimitReached}
          </p>
        ) : null}
        <ul className="analytics-tree">
          {groups.map((group) => {
            const ids = group.assets.map((a) => a.asset_id);
            const count = ids.filter((id) => selected.includes(id)).length;
            const open = searching || expanded.has(group.key);
            return (
              <li key={group.key} className="analytics-tree__group" data-testid={`asset-group-${group.name}`}>
                <div className="analytics-tree__row analytics-tree__row--group">
                  <GroupCheckbox
                    checked={count === ids.length}
                    indeterminate={count > 0 && count < ids.length}
                    label={`Select group ${group.name}`}
                    onChange={() =>
                      onSetAssets(
                        count === ids.length ? selected.filter((id) => !ids.includes(id)) : fillToLimit(selected, ids, maxAssets).selection,
                      )
                    }
                  />
                  <button type="button" className="analytics-tree__expand" aria-expanded={open} onClick={() => toggle(group.key)}>
                    <span className="analytics-tree__name">{group.name}</span>
                    <span className="analytics-tree__count">
                      {count > 0 ? `${count}/${ids.length}` : ids.length}
                    </span>
                    <Chevron open={open} />
                  </button>
                </div>
                {open ? (
                  <ul className="analytics-tree__items">
                    {group.assets.map((asset) => {
                      const isSelected = selected.includes(asset.asset_id);
                      return (
                        <li key={asset.asset_id}>
                          <label className={`analytics-tree__row analytics-tree__item${!isSelected && atLimit ? " is-locked" : ""}`}>
                            <input
                              type="checkbox"
                              className="analytics-check"
                              checked={isSelected}
                              disabled={!isSelected && atLimit}
                              onChange={() => onToggle(asset.asset_id)}
                            />
                            <span>{asset.asset_name}</span>
                          </label>
                        </li>
                      );
                    })}
                  </ul>
                ) : null}
              </li>
            );
          })}
        </ul>
        {groups.length === 0 ? <p className="analytics-selector__none">No matching assets.</p> : null}
      </div>
    </FilterSection>
  );
}

// ---- Data points (D39-D42, D59, D66, D67, D75) -----------------------------------

export function DataPointSelector({
  catalog,
  selected,
  maxDataPoints,
  onToggle,
  onSetDataPoints,
}: {
  catalog: AnalyticsCatalogResponse | null;
  selected: readonly string[];
  maxDataPoints: number;
  onToggle: (code: string) => void;
  onSetDataPoints: (codes: string[]) => void;
}) {
  const [search, setSearch] = useState("");
  const { expanded, toggle } = useExpanded();
  const points = useMemo(() => siteDataPoints(catalog), [catalog]);
  const groups = useMemo(() => groupDataPoints(points, search), [points, search]);
  const atLimit = selected.length >= maxDataPoints;
  const searching = search.trim() !== "";
  const summary =
    selected.length === 0
      ? "None"
      : selected.length === 1
        ? (points.find((p) => p.code === selected[0])?.label ?? "1 data point")
        : `${selected.length} data points`;

  return (
    <FilterSection id="data-points" title="Data points" summary={summary} summaryTestId="data-point-selected-count" defaultOpen>
      <div className="analytics-selector" data-testid="data-point-selector">
        <SearchBox label="Search data points" placeholder="Search data points…" value={search} onChange={setSearch} />
        <BulkActions
          onSelectAll={() => onSetDataPoints(fillToLimit(selected, dataPointVisualOrder(groups), maxDataPoints).selection)}
          onClearAll={() => onSetDataPoints([])}
        />
        {atLimit ? (
          <p className="analytics-selector__limit" role="status" data-testid="data-point-limit-reached">
            {MESSAGES.dataPointLimitReached}
          </p>
        ) : null}
        <ul className="analytics-tree">
          {groups.map((group) => {
            const open = searching || expanded.has(group.name);
            const count = group.points.filter((p) => selected.includes(p.code)).length;
            return (
              <li key={group.name} className="analytics-tree__group" data-testid={`data-point-group-${group.name}`}>
                {/* Organizational only: no group-level checkbox (D39, D59). */}
                <button
                  type="button"
                  className="analytics-tree__expand analytics-tree__expand--heading"
                  aria-expanded={open}
                  onClick={() => toggle(group.name)}
                >
                  <span className="analytics-tree__name">{group.name}</span>
                  <span className="analytics-tree__count">
                    {count > 0 ? `${count}/${group.points.length}` : group.points.length}
                  </span>
                  <Chevron open={open} />
                </button>
                {open ? (
                  <ul className="analytics-tree__items analytics-tree__items--flat">
                    {group.points.map((point) => {
                      const isSelected = selected.includes(point.code);
                      return (
                        <li key={point.code}>
                          <label className={`analytics-tree__row analytics-tree__item${!isSelected && atLimit ? " is-locked" : ""}`}>
                            <input
                              type="checkbox"
                              className="analytics-check"
                              checked={isSelected}
                              disabled={!isSelected && atLimit}
                              onChange={() => onToggle(point.code)}
                            />
                            <span>{point.label}</span>
                          </label>
                        </li>
                      );
                    })}
                  </ul>
                ) : null}
              </li>
            );
          })}
        </ul>
        {groups.length === 0 ? <p className="analytics-selector__none">No matching data points.</p> : null}
      </div>
    </FilterSection>
  );
}

// ---- Resolution (EMS-REQ-134, D9, D68) -------------------------------------------

export function ResolutionSelector({
  value,
  range,
  catalog,
  onChange,
}: {
  value: AnalyticsRequestedResolution;
  range: CalendarRange;
  catalog: AnalyticsCatalogResponse | null;
  onChange: (resolution: AnalyticsRequestedResolution) => void;
}) {
  const label = RESOLUTION_OPTIONS.find((o) => o.value === value)?.label ?? value;
  return (
    <FilterSection id="resolution" title="Resolution" summary={label} summaryTestId="resolution-summary">
      <div data-testid="resolution-selector">
        <Segmented<AnalyticsRequestedResolution>
          name="resolution"
          label="Resolution"
          variant="grid"
          options={RESOLUTION_OPTIONS}
          value={value}
          onChange={onChange}
          isDisabled={(option) => !isResolutionAvailable(option, range, catalog)}
        />
      </div>
    </FilterSection>
  );
}

// ---- Phase type (D53, D54) ---------------------------------------------------------

const PHASE_OPTIONS = [
  { value: "system", label: "System" },
  { value: "three_phase", label: "3 Phase" },
] as const satisfies readonly { value: AnalyticsPhase; label: string }[];

export function PhaseTypeSelector({ value, onChange }: { value: AnalyticsPhase; onChange: (phase: AnalyticsPhase) => void }) {
  const label = PHASE_OPTIONS.find((o) => o.value === value)?.label ?? value;
  return (
    <FilterSection id="phase-type" title="Phase type" summary={label} summaryTestId="phase-type-summary">
      <div data-testid="phase-type-selector">
        <Segmented<AnalyticsPhase> name="phase-type" label="Phase type" options={PHASE_OPTIONS} value={value} onChange={onChange} />
      </div>
    </FilterSection>
  );
}

// ---- Comparison (D52) ------------------------------------------------------------------

export function ComparisonPlaceholder() {
  return (
    <section className="filter-section filter-section--disabled" data-testid="filter-section-comparison">
      <h3 className="filter-section__heading">
        <button type="button" className="filter-section__toggle" disabled data-testid="comparison-placeholder">
          <span className="filter-section__title">Comparison</span>
          <span className="filter-section__summary">{MESSAGES.comparisonComingSoon}</span>
        </button>
      </h3>
    </section>
  );
}
