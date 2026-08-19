package main

import (
	"reflect"
	"testing"
	"time"
)

func TestStatusStreamPathRoundTrip(t *testing.T) {
	assetID := "33d2e6d1-cb5c-4fe9-9626-15172d27ed79"

	path := statusStreamPath(assetID)

	gotAssetID, isStatus, err := parseStatusStreamPath(path)

	if err != nil {
		t.Fatalf("parse status path: %v", err)
	}

	if !isStatus {
		t.Fatalf("expected status path: %q", path)
	}

	if gotAssetID != assetID {
		t.Fatalf(
			"asset mismatch: got %q want %q",
			gotAssetID,
			assetID,
		)
	}
}

func TestNormalPointPathIsNotStatus(t *testing.T) {
	path := streamPath(
		"33d2e6d1-cb5c-4fe9-9626-15172d27ed79",
		[]string{"FREQUENCY"},
	)

	_, isStatus, err := parseStatusStreamPath(path)

	if err != nil {
		t.Fatalf("unexpected status parse error: %v", err)
	}

	if isStatus {
		t.Fatalf(
			"numeric telemetry path incorrectly classified as status: %q",
			path,
		)
	}
}

func TestReservedStatusSelectionUsesStatusPath(t *testing.T) {
	path := streamPath(
		"33d2e6d1-cb5c-4fe9-9626-15172d27ed79",
		[]string{statusLastSeenPoint},
	)

	expected :=
		"asset/33d2e6d1-cb5c-4fe9-9626-15172d27ed79/status"

	if path != expected {
		t.Fatalf(
			"status path mismatch: got %q want %q",
			path,
			expected,
		)
	}
}

func TestStableLastSeenFrameSchema(t *testing.T) {
	frame := stableLastSeenFrame(
		time.Unix(0, 0),
		"Last Updated: 3 sec ago",
	)

	got := make([]string, 0, len(frame.Fields))

	for _, field := range frame.Fields {
		got = append(got, field.Name)
	}

	expected := []string{
		"time",
		"__frame_ready",
		"Last Seen Line",
	}

	if !reflect.DeepEqual(got, expected) {
		t.Fatalf(
			"status frame mismatch: got %v want %v",
			got,
			expected,
		)
	}
}

func TestFormatLastSeenLine(t *testing.T) {
	latest := time.Unix(100, 0)

	tests := []struct {
		name string
		now  time.Time
		want string
	}{
		{
			name: "seconds",
			now:  time.Unix(112, 0),
			want: "Last Updated: 12 sec ago",
		},
		{
			name: "minutes",
			now:  time.Unix(225, 0),
			want: "Last Updated: 2 min ago",
		},
		{
			name: "hours",
			now:  time.Unix(7300, 0),
			want: "Last Updated: 2 hr ago",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := formatLastSeenLine(
				latest,
				tt.now,
			)

			if got != tt.want {
				t.Fatalf(
					"got %q want %q",
					got,
					tt.want,
				)
			}
		})
	}
}
