import type { DataQuery, DataSourceJsonData } from '@grafana/data';

export interface WiseWattsLiveQuery extends DataQuery {
  assetId?: string;
  logicalPoints?: string;
}

export interface WiseWattsLiveOptions extends DataSourceJsonData {}
