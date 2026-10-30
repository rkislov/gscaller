package main

import (
	"os"
	"testing"
	"time"
)

func TestLiveSocketSource(t *testing.T) {
	if os.Getenv("GSCALLER_LIVE_TEST") != "1" {
		t.Skip("opt-in system integration")
	}
	defer stopSockets()
	deadline := time.Now().Add(22 * time.Second)
	for time.Now().Before(deadline) {
		values, err := socketCounters()
		if err == nil && len(values) == 1 && values[0].Received > 0 {
			t.Logf("received=%d sent=%d", values[0].Received, values[0].Sent)
			return
		}
		time.Sleep(time.Second)
	}
	t.Fatal("no incoming socket traffic observed")
}

func TestSocketCollectorStopAndRestart(t *testing.T) {
	for i := 0; i < 2; i++ {
		_, err := socketCounters()
		if err != nil {
			t.Fatal(err)
		}
		stopSockets()
	}
}
