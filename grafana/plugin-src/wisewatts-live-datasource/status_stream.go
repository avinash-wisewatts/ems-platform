package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/grafana/grafana-plugin-sdk-go/backend"
	"github.com/grafana/grafana-plugin-sdk-go/data"
	"nhooyr.io/websocket"
)

// Reserved logical-point token used only to request the isolated
// status stream. It never enters the normal numeric-point path.
const statusLastSeenPoint = "__STATUS_LAST_SEEN"

type liveStatusMessage struct {
	Type                    string `json:"type"`
	AssetID                 string `json:"asset_id"`
	LatestReceivedTimestamp string `json:"latest_received_timestamp"`
	ConnectivityState       string `json:"connectivity_state"`
}

func statusStreamPath(assetID string) string {
	return "asset/" + url.PathEscape(assetID) + "/status"
}

func parseStatusStreamPath(raw string) (string, bool, error) {
	path := strings.Trim(strings.TrimSpace(raw), "/")
	parts := strings.Split(path, "/")

	if len(parts) != 3 || parts[0] != "asset" || parts[2] != "status" {
		return "", false, nil
	}

	assetID, err := url.PathUnescape(parts[1])
	if err != nil || strings.TrimSpace(assetID) == "" {
		return "", true, errors.New("invalid status asset id")
	}

	return assetID, true, nil
}

func formatLastSeenLine(latest time.Time, now time.Time) string {
	if latest.IsZero() {
		return "Last Updated: Never"
	}

	age := now.Sub(latest)

	if age < 0 {
		age = 0
	}

	seconds := int64(age / time.Second)

	switch {
	case seconds < 60:
		return fmt.Sprintf("Last Updated: %d sec ago", seconds)

	case seconds < 3600:
		return fmt.Sprintf(
			"Last Updated: %d min ago",
			seconds/60,
		)

	case seconds < 86400:
		return fmt.Sprintf(
			"Last Updated: %d hr ago",
			seconds/3600,
		)

	default:
		return fmt.Sprintf(
			"Last Updated: %d d ago",
			seconds/86400,
		)
	}
}

func stableLastSeenFrame(
	eventTime time.Time,
	line string,
) *data.Frame {
	if eventTime.IsZero() {
		eventTime = time.Now()
	}

	return data.NewFrame(
		"live-status",
		data.NewField(
			"time",
			nil,
			[]time.Time{eventTime},
		),
		data.NewField(
			"__frame_ready",
			nil,
			[]int64{1},
		),
		data.NewField(
			"Last Seen Line",
			nil,
			[]string{line},
		),
	)
}

func (d *Datasource) runStatusStream(
	ctx context.Context,
	req *backend.RunStreamRequest,
	sender *backend.StreamSender,
	assetID string,
) error {
	token := strings.TrimSpace(
		os.Getenv("EMS_GRAFANA_STREAM_TOKEN"),
	)

	if token == "" {
		return errors.New(
			"EMS_GRAFANA_STREAM_TOKEN is not configured",
		)
	}

	base := strings.TrimRight(
		strings.TrimSpace(
			os.Getenv("EMS_LIVE_TELEMETRY_WS_BASE_URL"),
		),
		"/",
	)

	if base == "" {
		base = "ws://live-telemetry:8090"
	}

	endpoint := fmt.Sprintf(
		"%s/api/live/grafana/%d/assets/%s/status/ws",
		base,
		req.PluginContext.OrgID,
		url.PathEscape(assetID),
	)

	headers := http.Header{}
	headers.Set("Authorization", "Bearer "+token)

	conn, _, err := websocket.Dial(
		ctx,
		endpoint,
		&websocket.DialOptions{
			HTTPHeader: headers,
		},
	)

	if err != nil {
		return fmt.Errorf(
			"connect isolated asset status websocket: %w",
			err,
		)
	}

	defer conn.Close(
		websocket.StatusNormalClosure,
		"status stream closed",
	)

	type readResult struct {
		payload []byte
		err     error
	}

	reads := make(chan readResult, 1)

	go func() {
		for {
			_, payload, err := conn.Read(ctx)

			select {
			case reads <- readResult{
				payload: payload,
				err:     err,
			}:
			case <-ctx.Done():
				return
			}

			if err != nil {
				return
			}
		}
	}()

	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()

	var latestReceived time.Time

	send := func(now time.Time) error {
		return sender.SendFrame(
			stableLastSeenFrame(
				now,
				formatLastSeenLine(
					latestReceived,
					now,
				),
			),
			data.IncludeAll,
		)
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()

		case result := <-reads:
			if result.err != nil {
				return result.err
			}

			var msg liveStatusMessage

			if err := json.Unmarshal(
				result.payload,
				&msg,
			); err != nil {
				continue
			}

			raw := strings.TrimSpace(
				msg.LatestReceivedTimestamp,
			)

			if raw != "" {
				parsed, err := time.Parse(
					time.RFC3339Nano,
					raw,
				)

				if err == nil {
					latestReceived = parsed
				}
			}

			if err := send(time.Now()); err != nil {
				return err
			}

		case now := <-ticker.C:
			if err := send(now); err != nil {
				return err
			}
		}
	}
}
