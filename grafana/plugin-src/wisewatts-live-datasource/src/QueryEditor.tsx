import * as React from 'react';
import type { QueryEditorProps } from '@grafana/data';
import { InlineField, Input } from '@grafana/ui';
import type { DataSource } from './datasource';
import type { WiseWattsLiveOptions, WiseWattsLiveQuery } from './types';

type Props = QueryEditorProps<DataSource, WiseWattsLiveQuery, WiseWattsLiveOptions>;

export function QueryEditor({ query, onChange, onRunQuery }: Props) {
  return (
    <>
      <InlineField label="Asset ID" labelWidth={18} grow>
        <Input
          value={query.assetId ?? ''}
          placeholder="$asset_id"
          onChange={(e) => onChange({ ...query, assetId: e.currentTarget.value })}
          onBlur={onRunQuery}
        />
      </InlineField>
      <InlineField label="Logical points" labelWidth={18} grow>
        <Input
          value={query.logicalPoints ?? ''}
          placeholder="FREQUENCY,VOLTAGE_LL_AVG"
          onChange={(e) => onChange({ ...query, logicalPoints: e.currentTarget.value })}
          onBlur={onRunQuery}
        />
      </InlineField>
    </>
  );
}
