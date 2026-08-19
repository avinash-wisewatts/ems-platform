from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[2]
DATASOURCE = (
    ROOT
    / "grafana"
    / "plugin-src"
    / "wisewatts-live-datasource"
    / "src"
    / "datasource.ts"
)


def test_wisewatts_datasource_keeps_explicit_single_argument_constructor():
    """
    Grafana 11.6 inspects DataSourceClass.length.

    WiseWatts Live must expose a constructor with exactly one declared
    argument so Grafana uses:

        new DataSourceClass(instanceSettings)

    rather than its dependency-injection instantiate() path.

    Removing this seemingly redundant constructor causes the browser error:

        TypeError: ...instantiate is not a function
    """
    source = DATASOURCE.read_text()

    match = re.search(
        r"constructor\s*\(\s*"
        r"([A-Za-z_$][A-Za-z0-9_$]*)"
        r"\s*(?::[^)]*)?\)",
        source,
    )

    assert match is not None, (
        "WiseWatts Live DataSource must retain its explicit "
        "one-argument constructor. Grafana 11.6 relies on "
        "DataSourceClass.length === 1."
    )

    constructor = match.group(0)

    assert "," not in constructor, (
        "WiseWatts Live DataSource constructor must have exactly "
        "one declared argument."
    )

    assert "super(" in source, (
        "WiseWatts Live DataSource constructor must call super(instanceSettings)."
    )


def test_wisewatts_datasource_documents_constructor_requirement():
    source = DATASOURCE.read_text()

    assert "DataSourceClass.length" in source
    assert "instantiate() path" in source
    assert "Keep this constructor" in source
