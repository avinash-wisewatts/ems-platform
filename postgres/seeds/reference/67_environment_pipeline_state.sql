INSERT INTO telemetry.pipeline_state
(
    pipeline_name
)
VALUES
(
    'environment_measurements'
)
ON CONFLICT (pipeline_name)
DO NOTHING;
