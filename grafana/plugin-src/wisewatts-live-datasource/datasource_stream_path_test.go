package main

import (
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestStreamPathSinglePointRoundTrip(t *testing.T) {
	path := streamPath(
		"33d2e6d1-cb5c-4fe9-9626-15172d27ed79",
		[]string{"FREQUENCY"},
	)

	if strings.Contains(path, "?") {
		t.Fatalf("Grafana Live channel must not contain query string: %q", path)
	}

	if !strings.Contains(path, "/points/") {
		t.Fatalf("expected point-selection path: %q", path)
	}

	assetID, points, err := parseStreamPath(path)
	if err != nil {
		t.Fatalf("parseStreamPath returned error: %v", err)
	}

	if assetID != "33d2e6d1-cb5c-4fe9-9626-15172d27ed79" {
		t.Fatalf("unexpected asset ID: %q", assetID)
	}

	expected := []string{"FREQUENCY"}

	if !reflect.DeepEqual(points, expected) {
		t.Fatalf("points mismatch: got %v want %v", points, expected)
	}
}

func TestStreamPathMultiplePointsRoundTrip(t *testing.T) {
	path := streamPath(
		"33d2e6d1-cb5c-4fe9-9626-15172d27ed79",
		normalizePoints(
			"VOLTAGE_LN_AVG,FREQUENCY,CURRENT_TOTAL,FREQUENCY",
		),
	)

	_, points, err := parseStreamPath(path)
	if err != nil {
		t.Fatalf("parseStreamPath returned error: %v", err)
	}

	expected := []string{
		"CURRENT_TOTAL",
		"FREQUENCY",
		"VOLTAGE_LN_AVG",
	}

	if !reflect.DeepEqual(points, expected) {
		t.Fatalf("points mismatch: got %v want %v", points, expected)
	}
}

func TestStreamPathWithoutPointFilterStillWorks(t *testing.T) {
	path := streamPath(
		"33d2e6d1-cb5c-4fe9-9626-15172d27ed79",
		nil,
	)

	assetID, points, err := parseStreamPath(path)
	if err != nil {
		t.Fatalf("parseStreamPath returned error: %v", err)
	}

	if assetID != "33d2e6d1-cb5c-4fe9-9626-15172d27ed79" {
		t.Fatalf("unexpected asset ID: %q", assetID)
	}

	if len(points) != 0 {
		t.Fatalf("expected no point filter, got %v", points)
	}
}

func TestStreamPathRejectsMalformedPointSelection(t *testing.T) {
	_, _, err := parseStreamPath(
		"asset/33d2e6d1-cb5c-4fe9-9626-15172d27ed79/points",
	)

	if err == nil {
		t.Fatal("expected malformed point-selection path to be rejected")
	}
}

func TestStablePointFrameContainsEveryRequestedField(t *testing.T) {
	points := []string{
		"VOLTAGE_LL_AVG",
		"VOLTAGE_L12",
		"VOLTAGE_L23",
		"VOLTAGE_L31",
	}

	frame := stablePointFrame(
		points,
		time.Unix(0, 0),
		nil,
	)

	got := make([]string, 0, len(frame.Fields))
	for _, field := range frame.Fields {
		got = append(got, field.Name)
	}

	expected := []string{
		"time",
		"__frame_ready",
		"VOLTAGE_L12",
		"VOLTAGE_L23",
		"VOLTAGE_L31",
		"VOLTAGE_LL_AVG",
	}

	if !reflect.DeepEqual(got, expected) {
		t.Fatalf(
			"stable frame fields mismatch: got %v want %v",
			got,
			expected,
		)
	}
}

func TestStablePointFrameKeepsMissingRequestedFields(t *testing.T) {
	voltage := 415.2

	frame := stablePointFrame(
		[]string{
			"VOLTAGE_LL_AVG",
			"VOLTAGE_L12",
			"VOLTAGE_L23",
		},
		time.Unix(0, 0),
		map[string]*float64{
			"VOLTAGE_LL_AVG": &voltage,
		},
	)

	got := make([]string, 0, len(frame.Fields))
	for _, field := range frame.Fields {
		got = append(got, field.Name)
	}

	expected := []string{
		"time",
		"__frame_ready",
		"VOLTAGE_L12",
		"VOLTAGE_L23",
		"VOLTAGE_LL_AVG",
	}

	if !reflect.DeepEqual(got, expected) {
		t.Fatalf(
			"partial snapshot dropped requested fields: got %v want %v",
			got,
			expected,
		)
	}
}
