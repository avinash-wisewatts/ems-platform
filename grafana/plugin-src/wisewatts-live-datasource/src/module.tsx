import { DataSourcePlugin } from '@grafana/data';
import { ConfigEditor } from './ConfigEditor';
import { DataSource } from './datasource';
import { QueryEditor } from './QueryEditor';
import type { WiseWattsLiveOptions, WiseWattsLiveQuery } from './types';

export const plugin = new DataSourcePlugin<DataSource, WiseWattsLiveQuery, WiseWattsLiveOptions>(DataSource)
  .setConfigEditor(ConfigEditor)
  .setQueryEditor(QueryEditor);
