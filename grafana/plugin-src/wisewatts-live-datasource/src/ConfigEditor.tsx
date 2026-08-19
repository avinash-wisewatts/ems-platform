import * as React from 'react';
import type { DataSourcePluginOptionsEditorProps } from '@grafana/data';
import { Alert } from '@grafana/ui';
import type { WiseWattsLiveOptions } from './types';

export function ConfigEditor(_props: DataSourcePluginOptionsEditorProps<WiseWattsLiveOptions>) {
  return (
    <Alert title="WiseWatts Live" severity="info">
      The backend adapter connects server-side to the WiseWatts Live Telemetry WebSocket API. No MQTT credentials or browser-side service tokens are used.
    </Alert>
  );
}
