package main

import (
	"bytes"
	"compress/zlib"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/grafana/grafana-plugin-sdk-go/backend"
	"github.com/grafana/grafana-plugin-sdk-go/backend/instancemgmt"
	"github.com/grafana/grafana-plugin-sdk-go/data"
	"nhooyr.io/websocket"
)

type Datasource struct{}

type queryModel struct {
	AssetID       string `json:"assetId"`
	LogicalPoints string `json:"logicalPoints"`
}

type liveMessage struct {
	Type    string      `json:"type"`
	AssetID string      `json:"asset_id"`
	Points  []livePoint `json:"points"`
}

type livePoint struct {
	LogicalPoint string   `json:"logical_point"`
	NumericValue *float64 `json:"numeric_value"`
	UnitSymbol   *string  `json:"unit_symbol"`
	EventTime    string   `json:"event_time"`
	Freshness    string   `json:"freshness_state"`
	QualityCode  string   `json:"quality_code"`
}

func NewDatasource(_ context.Context, _ backend.DataSourceInstanceSettings) (instancemgmt.Instance, error) {
	return &Datasource{}, nil
}

func (d *Datasource) Dispose() {}

func (d *Datasource) CheckHealth(_ context.Context, _ *backend.CheckHealthRequest) (*backend.CheckHealthResult, error) {
	if strings.TrimSpace(os.Getenv("EMS_GRAFANA_STREAM_TOKEN")) == "" {
		return &backend.CheckHealthResult{Status: backend.HealthStatusError, Message: "EMS_GRAFANA_STREAM_TOKEN is not configured"}, nil
	}
	return &backend.CheckHealthResult{Status: backend.HealthStatusOk, Message: "WiseWatts live adapter ready"}, nil
}

func normalizePoints(raw string) []string {
	seen := map[string]struct{}{}
	var out []string
	for _, part := range strings.Split(raw, ",") {
		p := strings.TrimSpace(part)
		if p == "" {
			continue
		}
		if _, ok := seen[p]; ok {
			continue
		}
		seen[p] = struct{}{}
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// stablePointFrame creates a live frame whose schema always contains
// every explicitly requested logical point.
//
// Grafana Canvas binds elements to field names. During an asset-variable
// change QueryData runs before the new Live stream has delivered telemetry.
// Returning the requested fields immediately prevents Canvas from briefly
// rendering "Field not found".
func stablePointFrame(
	points []string,
	eventTime time.Time,
	values map[string]*float64,
) *data.Frame {
	frame := data.NewFrame("live")

	if eventTime.IsZero() {
		eventTime = time.Now()
	}

	frame.Fields = append(
		frame.Fields,
		data.NewField("time", nil, []time.Time{eventTime}),
	)

	// Keep the frame non-empty while requested telemetry values are still
	// null during an asset/subscription transition. Canvas elements do not
	// bind to this internal field, but its presence prevents Grafana from
	// replacing the panel with the generic "No data" state.
	frame.Fields = append(
		frame.Fields,
		data.NewField("__frame_ready", nil, []int64{1}),
	)

	for _, name := range normalizePoints(strings.Join(points, ",")) {
		var value *float64

		if values != nil {
			value = values[name]
		}

		frame.Fields = append(
			frame.Fields,
			data.NewField(name, nil, []*float64{value}),
		)
	}

	return frame
}

func encodePointSelection(points []string) (string, error) {
	if len(points) == 0 {
		return "", nil
	}

	raw := []byte(strings.Join(points, ","))

	var compressed bytes.Buffer
	writer := zlib.NewWriter(&compressed)

	if _, err := writer.Write(raw); err != nil {
		return "", fmt.Errorf("compress point selection: %w", err)
	}
	if err := writer.Close(); err != nil {
		return "", fmt.Errorf("close point-selection compressor: %w", err)
	}

	return base64.RawURLEncoding.EncodeToString(compressed.Bytes()), nil
}

func decodePointSelection(token string) ([]string, error) {
	encoded, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil {
		return nil, errors.New("invalid logical-point token")
	}

	reader, err := zlib.NewReader(bytes.NewReader(encoded))
	if err != nil {
		return nil, errors.New("invalid compressed logical-point token")
	}
	defer reader.Close()

	decoded, err := io.ReadAll(io.LimitReader(reader, 64*1024))
	if err != nil {
		return nil, errors.New("invalid compressed logical-point selection")
	}

	points := normalizePoints(string(decoded))
	if len(points) == 0 {
		return nil, errors.New("empty logical-point selection")
	}

	return points, nil
}

func streamPath(assetID string, points []string) string {
	if len(points) == 1 && points[0] == statusLastSeenPoint {
		return statusStreamPath(assetID)
	}

	p := "asset/" + url.PathEscape(assetID)

	if len(points) == 0 {
		return p
	}

	token, err := encodePointSelection(points)
	if err != nil {
		return p
	}

	return p + "/points/" + token
}

func (d *Datasource) QueryData(_ context.Context, req *backend.QueryDataRequest) (*backend.QueryDataResponse, error) {
	resp := backend.NewQueryDataResponse()

	if req.PluginContext.DataSourceInstanceSettings == nil {
		return resp, errors.New("datasource settings unavailable")
	}

	uid := req.PluginContext.DataSourceInstanceSettings.UID

	for _, q := range req.Queries {
		var model queryModel

		if err := json.Unmarshal(q.JSON, &model); err != nil {
			resp.Responses[q.RefID] = backend.ErrDataResponse(
				backend.StatusBadRequest,
				"invalid query JSON",
			)
			continue
		}

		assetID := strings.TrimSpace(model.AssetID)

		if assetID == "" {
			resp.Responses[q.RefID] = backend.ErrDataResponse(
				backend.StatusBadRequest,
				"assetId is required",
			)
			continue
		}

		selected := normalizePoints(model.LogicalPoints)

		// Immediately expose every requested field to Grafana Canvas.
		// Values are nullable until the Live stream supplies telemetry.
		var frame *data.Frame

		if len(selected) == 1 &&
			selected[0] == statusLastSeenPoint {

			frame = stableLastSeenFrame(
				time.Now(),
				"Last Updated: —",
			)
		} else {
			frame = stablePointFrame(
				selected,
				time.Now(),
				nil,
			)
		}

		frame.Meta = &data.FrameMeta{
			Channel: fmt.Sprintf(
				"ds/%s/%s",
				uid,
				streamPath(assetID, selected),
			),
		}

		resp.Responses[q.RefID] = backend.DataResponse{
			Frames: data.Frames{frame},
		}
	}

	return resp, nil
}

func (d *Datasource) SubscribeStream(_ context.Context, req *backend.SubscribeStreamRequest) (*backend.SubscribeStreamResponse, error) {
	if !strings.HasPrefix(req.Path, "asset/") {
		return &backend.SubscribeStreamResponse{Status: backend.SubscribeStreamStatusPermissionDenied}, nil
	}
	return &backend.SubscribeStreamResponse{Status: backend.SubscribeStreamStatusOK}, nil
}

func parseStreamPath(raw string) (string, []string, error) {
	path := strings.Trim(strings.TrimSpace(raw), "/")
	parts := strings.Split(path, "/")

	if len(parts) < 2 || parts[0] != "asset" {
		return "", nil, errors.New("invalid stream path")
	}

	assetID, err := url.PathUnescape(parts[1])
	if err != nil || strings.TrimSpace(assetID) == "" {
		return "", nil, errors.New("invalid asset id")
	}

	if len(parts) == 2 {
		return assetID, nil, nil
	}

	if len(parts) != 4 || parts[2] != "points" {
		return "", nil, errors.New("invalid point-selection path")
	}

	token := strings.TrimSpace(parts[3])
	if token == "" {
		return "", nil, errors.New("empty logical-point token")
	}

	selected, err := decodePointSelection(token)
	if err != nil {
		return "", nil, err
	}

	return assetID, selected, nil
}

func (d *Datasource) RunStream(ctx context.Context, req *backend.RunStreamRequest, sender *backend.StreamSender) error {
	statusAssetID, isStatus, statusErr := parseStatusStreamPath(req.Path)

	if statusErr != nil {
		return statusErr
	}

	if isStatus {
		return d.runStatusStream(
			ctx,
			req,
			sender,
			statusAssetID,
		)
	}

	assetID, selected, err := parseStreamPath(req.Path)
	if err != nil {
		return err
	}

	token := strings.TrimSpace(os.Getenv("EMS_GRAFANA_STREAM_TOKEN"))
	if token == "" {
		return errors.New("EMS_GRAFANA_STREAM_TOKEN is not configured")
	}

	base := strings.TrimRight(
		strings.TrimSpace(os.Getenv("EMS_LIVE_TELEMETRY_WS_BASE_URL")),
		"/",
	)

	if base == "" {
		base = "ws://live-telemetry:8090"
	}

	endpoint := fmt.Sprintf(
		"%s/api/live/grafana/%d/assets/%s/ws",
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
			"connect live telemetry websocket: %w",
			err,
		)
	}

	// Canonical live snapshots may exceed nhooyr's default 32 KiB read limit.
	// Keep the connection bounded at 1 MiB.
	conn.SetReadLimit(1 << 20)

	defer conn.Close(
		websocket.StatusNormalClosure,
		"stream closed",
	)

	selectedSet := map[string]struct{}{}

	for _, p := range selected {
		selectedSet[p] = struct{}{}
	}

	for {
		_, payload, err := conn.Read(ctx)
		if err != nil {
			return err
		}

		var msg liveMessage

		if err := json.Unmarshal(payload, &msg); err != nil {
			continue
		}

		values := map[string]*float64{}
		eventTimes := map[string]time.Time{}

		for _, point := range msg.Points {
			if len(selectedSet) > 0 {
				if _, ok := selectedSet[point.LogicalPoint]; !ok {
					continue
				}
			}

			if point.NumericValue != nil {
				value := *point.NumericValue
				values[point.LogicalPoint] = &value
			}

			if t, err := time.Parse(
				time.RFC3339Nano,
				point.EventTime,
			); err == nil {
				eventTimes[point.LogicalPoint] = t
			}
		}

		eventTime := time.Now()

		// Explicit point selections must keep a stable field schema even
		// when a particular live snapshot omits one or more values.
		if len(selected) > 0 {
			for _, name := range selected {
				if t, ok := eventTimes[name]; ok && !t.IsZero() {
					eventTime = t
					break
				}
			}

			frame := stablePointFrame(
				selected,
				eventTime,
				values,
			)

			if err := sender.SendFrame(
				frame,
				data.IncludeAll,
			); err != nil {
				return err
			}

			continue
		}

		// Queries without an explicit point selection retain the existing
		// dynamic behaviour.
		if len(values) == 0 {
			continue
		}

		names := make([]string, 0, len(values))

		for name := range values {
			names = append(names, name)
		}

		sort.Strings(names)

		for _, name := range names {
			if t, ok := eventTimes[name]; ok && !t.IsZero() {
				eventTime = t
				break
			}
		}

		frame := stablePointFrame(
			names,
			eventTime,
			values,
		)

		if err := sender.SendFrame(
			frame,
			data.IncludeAll,
		); err != nil {
			return err
		}
	}
}

func (d *Datasource) PublishStream(_ context.Context, _ *backend.PublishStreamRequest) (*backend.PublishStreamResponse, error) {
	return &backend.PublishStreamResponse{Status: backend.PublishStreamStatusPermissionDenied}, nil
}
