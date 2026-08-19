import type { ScopedVars } from '@grafana/data';
import { DataSourceWithBackend, getTemplateSrv } from '@grafana/runtime';
import type { WiseWattsLiveOptions, WiseWattsLiveQuery } from './types';

export class DataSource extends DataSourceWithBackend<WiseWattsLiveQuery, WiseWattsLiveOptions> {
  // IMPORTANT:
  // Grafana 11.6 uses DataSourceClass.length to choose how a datasource is
  // instantiated. This explicit single-argument constructor MUST remain.
  //
  // Without it, DataSource.length is not 1 and Grafana incorrectly takes its
  // dependency-injection instantiate() path, causing:
  //   TypeError: ...instantiate is not a function
  //
  // Keep this constructor even if it appears redundant.
  constructor(instanceSettings: any) {
    super(instanceSettings);
  }

  applyTemplateVariables(query: WiseWattsLiveQuery, scopedVars: ScopedVars): WiseWattsLiveQuery {
    return {
      ...query,
      assetId: getTemplateSrv().replace(query.assetId ?? '', scopedVars),
      logicalPoints: getTemplateSrv().replace(query.logicalPoints ?? '', scopedVars),
    };
  }
}
