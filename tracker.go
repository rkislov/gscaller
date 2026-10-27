// Copyright 2026 Кислов Роман Сергеевич
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type counter struct {
	Name           string
	Index          uint32
	Received, Sent uint64
}
type usage struct {
	Day           string `json:"day"`
	DayReceived   uint64 `json:"day_received"`
	DaySent       uint64 `json:"day_sent"`
	TotalReceived uint64 `json:"total_received"`
	TotalSent     uint64 `json:"total_sent"`
}
type tracker struct {
	Usage                        usage
	baseline                     map[string]counter
	previous                     time.Time
	sessionReceived, sessionSent uint64
}

func newTracker() *tracker { return &tracker{} }
func (t *tracker) sample(now time.Time, values []counter, resetSpeed bool) (float64, float64) {
	day := now.Format("2006-01-02")
	if t.Usage.Day != day {
		t.Usage.Day = day
		t.Usage.DayReceived = 0
		t.Usage.DaySent = 0
	}
	next := make(map[string]counter, len(values))
	var received, sent uint64
	for _, v := range values {
		next[v.Name] = v
		if old, ok := t.baseline[v.Name]; ok && old.Index == v.Index {
			if v.Received >= old.Received {
				received += v.Received - old.Received
			}
			if v.Sent >= old.Sent {
				sent += v.Sent - old.Sent
			}
		}
	}
	t.baseline = next
	elapsed := now.Sub(t.previous).Seconds()
	t.previous = now
	t.Usage.DayReceived += received
	t.Usage.DaySent += sent
	t.Usage.TotalReceived += received
	t.Usage.TotalSent += sent
	t.sessionReceived += received
	t.sessionSent += sent
	if resetSpeed || elapsed <= 0 {
		return 0, 0
	}
	return float64(received) / elapsed, float64(sent) / elapsed
}
func (u *usage) load(path string) error {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	return json.Unmarshal(data, u)
}
func (u usage) save(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	data, err := json.Marshal(u)
	if err != nil {
		return err
	}
	// Rename within the same directory keeps the previous file intact on failure.
	f, err := os.CreateTemp(filepath.Dir(path), ".usage-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}
func amount(n uint64) string { return units(float64(n)) }
func rate(n float64) string  { return units(n) + "/с" }
func units(n float64) string {
	labels := []string{"Б", "КиБ", "МиБ", "ГиБ", "ТиБ", "ПиБ", "ЭиБ"}
	i := 0
	for n >= 1024 && i < len(labels)-1 {
		n /= 1024
		i++
	}
	if i == 0 {
		return fmt.Sprintf("%.0f %s", n, labels[i])
	}
	return fmt.Sprintf("%.1f %s", n, labels[i])
}
func interfaceNames(values []counter) string {
	names := make([]string, len(values))
	for i, v := range values {
		names[i] = v.Name
	}
	if len(names) == 0 {
		return "нет активной сети"
	}
	return strings.Join(names, ", ")
}

// Prefer default-route tunnels exclusively, avoiding encrypted + cleartext
// double counting. Without a default VPN, retain physical Wi-Fi/Ethernet.
func selectCounters(all []counter, routes []uint32) []counter {
	var tunnels, physical []counter
	for _, v := range all {
		if strings.HasPrefix(v.Name, "en") {
			physical = append(physical, v)
		}
		if strings.HasPrefix(v.Name, "utun") || strings.HasPrefix(v.Name, "ppp") || strings.HasPrefix(v.Name, "ipsec") {
			for _, index := range routes {
				if index != 0 && v.Index == index {
					tunnels = append(tunnels, v)
					break
				}
			}
		}
	}
	if len(tunnels) > 0 {
		return tunnels
	}
	return physical
}
func compactRate(n float64) string {
	labels := []string{"B/s", "KB/s", "MB/s", "GB/s", "TB/s"}
	i := 0
	for n >= 1024 && i < len(labels)-1 {
		n /= 1024
		i++
	}
	var number string
	if n < 10 {
		number = fmt.Sprintf("%.2f", n)
	} else {
		number = fmt.Sprintf("%.1f", n)
	}
	return fmt.Sprintf("%5s %-4s", number, labels[i])
}
