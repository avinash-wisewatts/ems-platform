System.register(
  ["@grafana/data", "@grafana/runtime", "react", "@grafana/ui"],
  function (exports) {
    "use strict";

    var DataSourcePlugin;
    var DataSourceWithBackend;
    var getTemplateSrv;
    var React;
    var Alert;
    var InlineField;
    var Input;

    return {
      setters: [
        function (grafanaData) {
          DataSourcePlugin = grafanaData.DataSourcePlugin;
        },

        function (grafanaRuntime) {
          DataSourceWithBackend = grafanaRuntime.DataSourceWithBackend;
          getTemplateSrv = grafanaRuntime.getTemplateSrv;
        },

        function (react) {
          React = react;
        },

        function (grafanaUi) {
          Alert = grafanaUi.Alert;
          InlineField = grafanaUi.InlineField;
          Input = grafanaUi.Input;
        }
      ],

      execute: function () {

        class DataSource extends DataSourceWithBackend {
          applyTemplateVariables(query, scopedVars) {
            return Object.assign({}, query, {
              assetId: getTemplateSrv().replace(
                query.assetId || "",
                scopedVars
              ),

              logicalPoints: getTemplateSrv().replace(
                query.logicalPoints || "",
                scopedVars
              )
            });
          }
        }


        function QueryEditor(props) {
          var query = props.query;
          var onChange = props.onChange;
          var onRunQuery = props.onRunQuery;

          return React.createElement(
            React.Fragment,
            null,

            React.createElement(
              InlineField,
              {
                label: "Asset ID",
                labelWidth: 18,
                grow: true
              },

              React.createElement(Input, {
                value: query.assetId || "",
                placeholder: "$asset_id",

                onChange: function (event) {
                  onChange(
                    Object.assign({}, query, {
                      assetId: event.currentTarget.value
                    })
                  );
                },

                onBlur: onRunQuery
              })
            ),

            React.createElement(
              InlineField,
              {
                label: "Logical points",
                labelWidth: 18,
                grow: true
              },

              React.createElement(Input, {
                value: query.logicalPoints || "",
                placeholder: "FREQUENCY,VOLTAGE_LL_AVG",

                onChange: function (event) {
                  onChange(
                    Object.assign({}, query, {
                      logicalPoints: event.currentTarget.value
                    })
                  );
                },

                onBlur: onRunQuery
              })
            )
          );
        }


        function ConfigEditor() {
          return React.createElement(
            Alert,
            {
              title: "WiseWatts Live",
              severity: "info"
            },

            "The backend adapter connects server-side to the WiseWatts Live Telemetry WebSocket API. No MQTT credentials or browser-side service tokens are used."
          );
        }


        var plugin = new DataSourcePlugin(DataSource)
          .setConfigEditor(ConfigEditor)
          .setQueryEditor(QueryEditor);

        exports("plugin", plugin);
      }
    };
  }
);
