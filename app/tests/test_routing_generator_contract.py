"""Contract tests for the Phase 4 offline routing generator.

Covers (design checkpoint Part 8, acceptance items for the generator):
  * deterministic output / stable ordering
  * generated artifact == a fresh render of the committed spec + template
  * Gate A (repo level): the generated procedure BODY is token-stream identical
    to the deployed migration-226 body; the COMMENT gains exactly one appended
    Phase-4 provenance sentence and nothing else
  * no runtime-dynamic SQL in the generated body; the parameterised LATERAL
    probe shape is preserved
  * invalid / ambiguous specs fail closed (SpecError -> exit 2)
  * --check detects drift
  * the committed spec carries exactly the 12 pivot routing rows + the single
    BATTERY_VOLTAGE legacy compatibility alias, and they match the
    migration-227 seed VALUES block
  * migration 227 registers in the manifest, redefines no *_route view, and its
    embedded procedure body equals the committed generated artifact
"""
from __future__ import annotations

import copy
import importlib.util
import json
import re
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
GEN_PY = REPO / "scripts" / "codegen" / "generate_routing_procedure.py"
SPEC = REPO / "scripts" / "codegen" / "routing" / "environment_measurements.routing.json"
TMPL = REPO / "scripts" / "codegen" / "templates" / "load_environment_measurements_incremental.sql.tmpl"
ARTIFACT = REPO / "scripts" / "codegen" / "generated" / "load_environment_measurements_incremental.generated.sql"
MIG_226 = REPO / "postgres" / "migrations" / "226_environment_space_binding.sql"
MIG_227 = REPO / "postgres" / "migrations" / "227_parameter_routing_foundation.sql"
MIG_228 = REPO / "postgres" / "migrations" / "228_device_specific_asset_space_point_binding.sql"
MIG_267 = REPO / "postgres" / "migrations" / "267_routing_bounded_window_end.sql"
MANIFEST = REPO / "postgres" / "restructure_manifest.csv"

# The Phase 2 amendment (migration 228) adds exactly one predicate to the
# generated Space-resolution sub-select; every other token of the body is still
# the verbatim migration-226 body.
_MIG_228_EXTRA_TOKENS = ["AND", "sp", ".", "device_id", "=", "ranked", ".", "device_id"]

# Migration 267 replaces exactly one block -- the window-end lookup -- with the
# event_time-bounded lookup plus the global fallback. Reverting that block must
# give back the pre-267 body exactly.
_MIG_267_OLD_BLOCK = (
    "    SELECT max(platform_received_at) INTO v_window_end\n"
    "    FROM telemetry.normalized_points\n"
    "    WHERE platform_received_at IS NOT NULL;"
)
_MIG_267_NEW_BLOCK = (
    "    -- Migration 267: bound the window-end lookup to recent event_time so it only\n"
    "    -- reads uncompressed chunks (normalized_points compress_after = 1 day). The\n"
    "    -- bounded max can only be lower than the global max, which delays -- never\n"
    "    -- skips -- rows; the global lookup remains the fallback when no row has a\n"
    "    -- recent event_time.\n"
    "    SELECT max(platform_received_at) INTO v_window_end\n"
    "    FROM telemetry.normalized_points\n"
    "    WHERE platform_received_at IS NOT NULL\n"
    "      AND event_time >= now() - INTERVAL '1 day';\n"
    "    IF v_window_end IS NULL THEN\n"
    "      SELECT max(platform_received_at) INTO v_window_end\n"
    "      FROM telemetry.normalized_points\n"
    "      WHERE platform_received_at IS NOT NULL;\n"
    "    END IF;"
)


def _find_sublist(hay: list[str], needle: list[str]) -> int:
    for i in range(len(hay) - len(needle) + 1):
        if hay[i:i + len(needle)] == needle:
            return i
    return -1


def _load_generator():
    spec = importlib.util.spec_from_file_location("routing_generator", GEN_PY)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


gen = _load_generator()


def _spec() -> dict:
    return json.loads(SPEC.read_text(encoding="utf-8"))


def _template() -> str:
    return TMPL.read_text(encoding="utf-8")


def _split_body_comment(sql: str) -> tuple[str, str]:
    i = sql.index("COMMENT ON PROCEDURE")
    return sql[:i], sql[i:]


_TOK = re.compile(r"'(?:[^']|'')*'|[A-Za-z_][A-Za-z0-9_]*|::|:=|=>|<=|>=|<>|[(),.;*<>=+/-]|\S")


def _tokens(s: str) -> list[str]:
    return _TOK.findall(s)


def _strip_line_comments(sql: str) -> str:
    # Drop whole-line "--" comments so a comparison sees behaviour, not prose.
    # (The generated body's only comments are full-line; the migration-228
    # amendment adds several explanatory comment lines around its one predicate.)
    return "\n".join(
        ln for ln in sql.splitlines() if not ln.lstrip().startswith("--")
    )


def _revert_267_text(sql: str) -> str:
    assert sql.count(_MIG_267_NEW_BLOCK) == 1, "the migration-267 window-end block must appear exactly once"
    return sql.replace(_MIG_267_NEW_BLOCK, _MIG_267_OLD_BLOCK)


def _revert_267_tokens(tokens: list[str]) -> list[str]:
    new = _tokens(_strip_line_comments(_MIG_267_NEW_BLOCK))
    old = _tokens(_MIG_267_OLD_BLOCK)
    i = _find_sublist(tokens, new)
    assert i != -1, "the migration-267 window-end block is missing from the generated body"
    return tokens[:i] + old + tokens[i + len(new):]


# --------------------------------------------------------------------------- #
# generator output / determinism
# --------------------------------------------------------------------------- #

def test_generated_artifact_matches_fresh_render():
    rendered = gen.render(_spec(), _template())
    assert rendered == ARTIFACT.read_text(encoding="utf-8"), (
        "scripts/codegen/generated/... is stale -- re-run the generator"
    )


def test_render_is_deterministic():
    a = gen.render(_spec(), _template())
    b = gen.render(json.loads(SPEC.read_text(encoding="utf-8")), _template())
    assert a == b


def test_render_ignores_dict_key_order():
    s = _spec()
    shuffled = {k: s[k] for k in reversed(list(s.keys()))}
    assert gen.render(shuffled, _template()) == gen.render(s, _template())


# --------------------------------------------------------------------------- #
# Gate A -- repo-level parity with the deployed migration-226 body, plus the
# single migration-228 (Phase 2 amendment) device predicate and nothing else
# --------------------------------------------------------------------------- #

def test_generated_body_is_migration_226_plus_only_the_228_predicate_and_267_window_end():
    body226 = "\n".join(MIG_226.read_text(encoding="utf-8").splitlines()[110:413])
    gen_full = ARTIFACT.read_text(encoding="utf-8")
    b226, _ = _split_body_comment(body226)
    bgen, _ = _split_body_comment(gen_full)
    tb226 = _tokens(_strip_line_comments(b226))
    tbgen = _revert_267_tokens(_tokens(_strip_line_comments(bgen)))

    i = _find_sublist(tbgen, _MIG_228_EXTRA_TOKENS)
    assert i != -1, (
        "Gate A: the migration-228 device predicate (AND sp.device_id = "
        "ranked.device_id) is missing from the generated body"
    )
    assert tbgen[:i] + tbgen[i + len(_MIG_228_EXTRA_TOKENS):] == tb226, (
        "Gate A: the generated procedure body diverges from (migration-226 body "
        "+ the single migration-228 device predicate) by more than whitespace"
    )


def test_generated_comment_is_226_plus_exactly_one_phase4_sentence():
    body226 = "\n".join(MIG_226.read_text(encoding="utf-8").splitlines()[110:413])
    _, c226 = _split_body_comment(body226)
    _, cgen = _split_body_comment(ARTIFACT.read_text(encoding="utf-8"))
    lits = re.compile(r"'(?:[^']|'')*'")
    p226 = lits.findall(c226)
    pgen = lits.findall(cgen)
    assert len(pgen) == len(p226) + 1, "COMMENT should gain exactly one appended literal"
    # first N-1 literals identical except a single trailing space added to join
    for a, b in zip(p226[:-1], pgen[:-1]):
        assert a == b
    assert p226[-1].rstrip("'") + " '" == pgen[-2]  # last old literal + join space
    assert "Phase 4 (migration 227)" in pgen[-1]


def test_no_runtime_dynamic_sql_in_generated_body():
    body, _ = _split_body_comment(ARTIFACT.read_text(encoding="utf-8"))
    assert "EXECUTE " not in body
    assert "format(" not in body
    assert "CROSS JOIN LATERAL" in body
    assert "OFFSET 0" in body
    assert "MATERIALIZED" in body


def test_generated_body_does_not_read_the_routing_table():
    body, _ = _split_body_comment(ARTIFACT.read_text(encoding="utf-8"))
    assert "config.parameter_routing" not in body


# --------------------------------------------------------------------------- #
# spec content -- 12 pivots + one legacy alias
# --------------------------------------------------------------------------- #

def test_spec_has_exactly_12_pivot_routing_rows():
    rows = gen.routing_rows(_spec())
    assert len(rows) == 12
    assert all(r["destination_table"] == "telemetry.environment_measurements" for r in rows)


def test_spec_has_exactly_one_legacy_alias_on_battery_voltage():
    rows = [r for r in gen.routing_rows(_spec()) if r["legacy_source_aliases"]]
    assert len(rows) == 1
    assert rows[0]["logical_point"] == "DEVICE_BATTERY_VOLTAGE"
    assert rows[0]["destination_column"] == "battery_voltage_v"
    assert rows[0]["legacy_source_aliases"] == ["BATTERY_VOLTAGE"]


def test_spec_pivot_names_match_prefilter_exactly():
    s = _spec()
    canon = [c["logical_point"] for c in s["payload_columns"] if c["kind"] == "pivot"]
    aliases = [a for c in s["payload_columns"] for a in (c.get("legacy_source_aliases") or [])]
    assert set(s["prefilter_logical_points"]) == set(canon) | set(aliases)
    assert len(s["prefilter_logical_points"]) == 13


def test_six_pivots_carry_a_parameter_code():
    rows = gen.routing_rows(_spec())
    assert sum(1 for r in rows if r["parameter_code"]) == 6
    assert "BATTERY_VOLTAGE" not in [r["parameter_code"] for r in rows if r["logical_point"] == "PULSE_INPUT_1_RAW"]


# --------------------------------------------------------------------------- #
# fail-closed on invalid / ambiguous specs
# --------------------------------------------------------------------------- #

def _mutate(**patch):
    s = copy.deepcopy(_spec())
    for k, v in patch.items():
        s[k] = v
    return s


def test_unknown_value_transform_fails_closed():
    s = _mutate()
    s["payload_columns"][0]["value_transform"] = "MULTIPLY_BY_SCALE"
    with pytest.raises(gen.SpecError):
        gen.render(s, _template())


def test_duplicate_destination_column_fails_closed():
    s = _mutate()
    s["payload_columns"][1]["destination_column"] = s["payload_columns"][0]["destination_column"]
    with pytest.raises(gen.SpecError):
        gen.render(s, _template())


def test_duplicate_logical_point_fails_closed():
    s = _mutate()
    s["payload_columns"][1]["logical_point"] = s["payload_columns"][0]["logical_point"]
    with pytest.raises(gen.SpecError):
        gen.render(s, _template())


def test_prefilter_missing_a_name_fails_closed():
    s = _mutate()
    s["prefilter_logical_points"] = s["prefilter_logical_points"][:-1]
    with pytest.raises(gen.SpecError):
        gen.render(s, _template())


def test_prefilter_extra_name_fails_closed():
    s = _mutate()
    s["prefilter_logical_points"] = s["prefilter_logical_points"] + ["NOT_A_ROUTED_POINT"]
    with pytest.raises(gen.SpecError):
        gen.render(s, _template())


def test_empty_legacy_alias_fails_closed():
    s = _mutate()
    s["payload_columns"][5]["legacy_source_aliases"] = [""]
    with pytest.raises(gen.SpecError):
        gen.render(s, _template())


def test_disallowed_destination_table_fails_closed():
    s = _mutate(destination_table="telemetry.energy_measurements")
    with pytest.raises(gen.SpecError):
        gen.render(s, _template())


def test_main_exits_2_on_invalid_spec(tmp_path):
    bad = tmp_path / "bad.json"
    s = _spec()
    s["payload_columns"][0]["value_transform"] = "NOPE"
    bad.write_text(json.dumps(s), encoding="utf-8")
    rc = gen.main(["--spec", str(bad), "--template", str(TMPL), "--out", str(tmp_path / "o.sql")])
    assert rc == 2


# --------------------------------------------------------------------------- #
# --check mode
# --------------------------------------------------------------------------- #

def test_check_mode_passes_for_committed_artifact():
    rc = gen.main(["--spec", str(SPEC), "--template", str(TMPL), "--out", str(ARTIFACT), "--check"])
    assert rc == 0


def test_check_mode_detects_drift(tmp_path):
    stale = tmp_path / "stale.sql"
    stale.write_text(ARTIFACT.read_text(encoding="utf-8") + "\n-- drift\n", encoding="utf-8")
    rc = gen.main(["--spec", str(SPEC), "--template", str(TMPL), "--out", str(stale), "--check"])
    assert rc == 1


# --------------------------------------------------------------------------- #
# migration 227 wiring
# --------------------------------------------------------------------------- #

def test_manifest_registers_migration_227():
    import csv

    rows = list(csv.DictReader(MANIFEST.read_text(encoding="utf-8").splitlines()))
    by_src = {r["source_file"]: r for r in rows}
    assert "227_parameter_routing_foundation.sql" in by_src
    r = by_src["227_parameter_routing_foundation.sql"]
    assert r["target_category"] == "migration"
    assert r["target_path"] == "postgres/migrations/227_parameter_routing_foundation.sql"


def test_migration_267_embedded_body_equals_generated_artifact():
    # Migration 267 now owns the deployed body: it CREATE OR REPLACEs the
    # loader with the current generated artifact, verbatim.
    mig = MIG_267.read_text(encoding="utf-8")
    art = ARTIFACT.read_text(encoding="utf-8").rstrip("\n")
    start = mig.index("CREATE OR REPLACE PROCEDURE telemetry.load_environment_measurements_incremental")
    end = mig.index("read at runtime.';") + len("read at runtime.';")
    assert mig[start:end] == art


def test_migration_228_embedded_body_is_the_artifact_before_the_267_window_end():
    # Migration 228's embedded body is the pre-267 artifact: identical to the
    # current generated artifact except for the migration-267 window-end block.
    mig = MIG_228.read_text(encoding="utf-8")
    art = ARTIFACT.read_text(encoding="utf-8").rstrip("\n")
    start = mig.index("CREATE OR REPLACE PROCEDURE telemetry.load_environment_measurements_incremental")
    end = mig.index("read at runtime.';") + len("read at runtime.';")
    assert mig[start:end] == _revert_267_text(art)


def test_migration_227_embedded_body_is_the_228_body_minus_the_device_predicate():
    # Migration 227's embedded body is the pre-amendment artifact: identical to
    # the current generated artifact except for the migration-228 device
    # predicate + its comment block.
    mig = MIG_227.read_text(encoding="utf-8")
    start = mig.index("CREATE OR REPLACE PROCEDURE telemetry.load_environment_measurements_incremental")
    end = mig.index("read at runtime.';") + len("read at runtime.';")
    body227, _ = _split_body_comment(mig[start:end])
    bgen, _ = _split_body_comment(ARTIFACT.read_text(encoding="utf-8"))
    t227 = _tokens(_strip_line_comments(body227))
    tgen = _revert_267_tokens(_tokens(_strip_line_comments(bgen)))
    i = _find_sublist(tgen, _MIG_228_EXTRA_TOKENS)
    assert i != -1
    assert tgen[:i] + tgen[i + len(_MIG_228_EXTRA_TOKENS):] == t227


def test_migration_227_defines_no_route_view_and_no_dynamic_sql():
    mig = MIG_227.read_text(encoding="utf-8")
    # no CREATE VIEW statement touching a *_route view (prose mentions in the
    # header comment are fine -- they document what is deliberately untouched)
    assert not re.search(r"CREATE\s+(OR\s+REPLACE\s+)?VIEW\s+\S*_route", mig, re.IGNORECASE)
    body, _ = _split_body_comment(mig[mig.index("CREATE OR REPLACE PROCEDURE"):])
    assert "EXECUTE " not in body and "format(" not in body


def test_migration_227_seed_matches_spec():
    mig = MIG_227.read_text(encoding="utf-8")
    block = mig[mig.index("FROM (VALUES"):mig.index(") AS v(logical_point_name")]
    tuples = re.findall(
        r"\('([A-Z0-9_]+)',\s*(NULL|'[A-Z0-9_]+'),\s*'([a-z0-9_]+)',\s*'([A-Z_]+)',\s*"
        r"(NULL(?:::text\[\])?|ARRAY\['[A-Z0-9_]+'\])\)",
        block,
    )
    assert len(tuples) == 12
    seed = {
        t[0]: {
            "parameter_code": None if t[1] == "NULL" else t[1].strip("'"),
            "destination_column": t[2],
            "value_transform": t[3],
            "aliases": None if t[4].startswith("NULL") else [t[4][t[4].index("[") + 2 : t[4].index("]") - 1]],
        }
        for t in tuples
    }
    for row in gen.routing_rows(_spec()):
        s = seed[row["logical_point"]]
        assert s["parameter_code"] == row["parameter_code"]
        assert s["destination_column"] == row["destination_column"]
        assert s["value_transform"] == row["value_transform"]
        assert s["aliases"] == row["legacy_source_aliases"]
