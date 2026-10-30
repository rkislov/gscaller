// Copyright 2026 Кислов Роман Сергеевич
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestAccounting(t *testing.T) {
	now := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
	m := newTracker()
	m.sample(now, []counter{{"en0", 1, 1000, 500}}, false)
	down, up := m.sample(now.Add(5*time.Second), []counter{{"en0", 1, 1500, 750}}, false)
	if down != 100 || up != 50 || m.Usage.DayReceived != 500 {
		t.Fatalf("bad delta: %v %v %+v", down, up, m.Usage)
	}
	// New interfaces must establish a baseline instead of importing lifetime bytes.
	m.sample(now.Add(10*time.Second), []counter{{"en0", 1, 1600, 800}, {"en1", 2, 90000, 80000}}, false)
	if m.Usage.TotalReceived != 600 {
		t.Fatal(m.Usage)
	}
	// A reset must not underflow; an interface with a reused name/new index is new.
	m.sample(now.Add(15*time.Second), []counter{{"en0", 1, 1, 2}, {"en1", 3, 999999, 999999}}, false)
	if m.Usage.TotalReceived != 600 {
		t.Fatal(m.Usage)
	}
	// Disappearance followed by return must establish a new baseline.
	m.sample(now.Add(20*time.Second), nil, false)
	m.sample(now.Add(25*time.Second), []counter{{"en0", 1, 5000, 5000}}, false)
	if m.Usage.TotalReceived != 600 {
		t.Fatal(m.Usage)
	}
}
func TestWakeAndDayRollover(t *testing.T) {
	m := newTracker()
	now := time.Date(2026, 10, 27, 23, 59, 50, 0, time.UTC)
	m.sample(now, []counter{{"en0", 1, 10, 10}}, false)
	down, up := m.sample(now.Add(20*time.Second), []counter{{"en0", 1, 110, 60}}, true)
	if down != 0 || up != 0 || m.Usage.Day != "2026-10-28" || m.Usage.DayReceived != 100 || m.sessionReceived != 100 {
		t.Fatal(m, down, up)
	}
	m.sample(now.Add(24*time.Hour), []counter{{"en0", 1, 210, 70}}, false)
	m.sample(now.Add(48*time.Hour), []counter{{"en0", 1, 260, 90}}, false)
	if m.Usage.DayReceived != 50 || m.Usage.TotalReceived != 250 {
		t.Fatal(m.Usage)
	}
}
func TestPersistenceAndRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "Scaler", "usage.json")
	original := usage{Day: "2026-10-27", DayReceived: 123, TotalReceived: 456}
	if err := original.save(path); err != nil {
		t.Fatal(err)
	}
	m := newTracker()
	if err := m.Usage.load(path); err != nil {
		t.Fatal(err)
	}
	if m.Usage != original {
		t.Fatal(m.Usage)
	}
	m.sample(time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC), []counter{{"en0", 1, 90000, 80000}}, false)
	if m.Usage != original {
		t.Fatal("restart imported lifetime counters", m.Usage)
	}
	if err := os.WriteFile(path, []byte("broken"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := m.Usage.load(path); err == nil {
		t.Fatal("corrupt statistics accepted")
	}
}
func TestNativeSnapshot(t *testing.T) {
	values, err := allCounters()
	if err != nil {
		t.Fatal(err)
	}
	if len(values) == 0 {
		t.Fatal("empty native snapshot")
	}
}
func BenchmarkNativeSnapshot(b *testing.B) {
	for i := 0; i < b.N; i++ {
		if _, err := counters(); err != nil {
			b.Fatal(err)
		}
	}
}

func TestDefaultVPNSelection(t *testing.T) {
	all := []counter{{"en0", 1, 1000, 500}, {"utun0", 2, 200, 100}, {"utun4", 3, 900, 450}, {"lo0", 4, 100, 100}}
	values := selectCounters(all, []uint32{3, 0})
	if len(values) != 1 || values[0].Name != "utun4" {
		t.Fatal(values)
	}
	values = selectCounters(all, []uint32{1, 0})
	if len(values) != 1 || values[0].Name != "en0" {
		t.Fatal(values)
	}
	m := newTracker()
	now := time.Now()
	m.sample(now, selectCounters(all, []uint32{1}), false)
	down, up := m.sample(now.Add(time.Second), selectCounters(all, []uint32{3}), false)
	if down != 0 || up != 0 {
		t.Fatal("switch imported historic traffic")
	}
	all[2].Received += 300
	all[2].Sent += 100
	down, up = m.sample(now.Add(2*time.Second), selectCounters(all, []uint32{3}), false)
	if down != 300 || up != 100 {
		t.Fatal(down, up)
	}
}

func TestCompactColumns(t *testing.T) {
	cases := []struct {
		rate float64
		want string
	}{{0, " 0.00 B/s "}, {1.35 * 1024 * 1024, " 1.35 MB/s"}, {220.6 * 1024, "220.6 KB/s"}}
	for _, c := range cases {
		if got := compactRate(c.rate); got != c.want {
			t.Fatalf("got %q want %q", got, c.want)
		}
	}
}
