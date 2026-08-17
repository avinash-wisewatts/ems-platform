# Migration 009 — Selected-sample direct normalization

Forward performance fix for the site-frequency normalizer introduced by 007/008.

008 made site capture selection set-based, but still re-entered telemetry.v_normalized_points once per selected sample. On production this spilled to temporary files (BufFileRead) and did not finish in five minutes.

009 preserves the set-based site/bucket/device selection and replaces only the expansion stage. It parses the already-selected raw messages, isolates the selected device element, joins enabled profile/device mappings directly, and writes the resulting canonical logical points. The global normalized view is not scanned.

No retention, bucket, late-arrival, routing, failure, recovery, or connectivity semantics change in 009.
