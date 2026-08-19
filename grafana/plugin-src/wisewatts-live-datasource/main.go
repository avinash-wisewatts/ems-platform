package main

import (
    "os"

    "github.com/grafana/grafana-plugin-sdk-go/backend/datasource"
    "github.com/grafana/grafana-plugin-sdk-go/backend/log"
)

func main() {
    if err := datasource.Manage("wisewatts-live-datasource", NewDatasource, datasource.ManageOpts{}); err != nil {
        log.DefaultLogger.Error("failed to start datasource", "error", err)
        os.Exit(1)
    }
}
