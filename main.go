// Copyright 2026 Кислов Роман Сергеевич
// SPDX-License-Identifier: Apache-2.0

package main

/*
#cgo CFLAGS: -mmacosx-version-min=12.0
#cgo LDFLAGS: -framework Cocoa -framework ServiceManagement -mmacosx-version-min=12.0
#include <stdlib.h>
#include <sys/socket.h>
#include "bridge.h"
*/
import "C"

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"syscall"
	"time"
	"unsafe"
)

var meter = newTracker()
var statePath string
var lastSave time.Time
var savedUsage usage
var storageError string
var showSpeed bool
var diagnosticFile *os.File

func allCounters() ([]counter, error) {
	var raw [128]C.ScalerCounter
	n := int(C.scaler_counters(&raw[0], C.int(len(raw))))
	if n < 0 {
		return nil, fmt.Errorf("не удалось прочитать сетевые счётчики (код %d)", -n)
	}
	result := make([]counter, n)
	for i := range result {
		result[i] = counter{Name: C.GoString(&raw[i].name[0]), Index: uint32(raw[i].index), Received: uint64(raw[i].received), Sent: uint64(raw[i].sent)}
	}
	return result, nil
}

func counters() ([]counter, error) {
	all, err := allCounters()
	if err != nil {
		return nil, err
	}
	indices := []uint32{uint32(C.scaler_default_index(C.AF_INET)), uint32(C.scaler_default_index(C.AF_INET6))}
	selected := selectCounters(all, indices)
	for _, v := range selected {
		if len(v.Name) >= 2 && v.Name[:2] != "en" {
			stopSockets()
			return selected, nil
		}
	}
	return socketCounters()
}

//export scaler_tick
func scaler_tick(resetSpeed C.int) {
	now := time.Now()
	values, err := counters()
	if err != nil {
		meter.baseline = nil
		display("↕ —", "Счётчики временно недоступны", err.Error())
		return
	}
	down, up := meter.sample(now, values, resetSpeed != 0)
	if now.Sub(lastSave) >= time.Minute {
		save()
	}
	title := fmt.Sprintf("↓ %s\n↑ %s", compactRate(down), compactRate(up))
	if !showSpeed {
		title = fmt.Sprintf("↓ %s\n↑ %s", amount(meter.Usage.DayReceived), amount(meter.Usage.DaySent))
	}
	details := fmt.Sprintf("Скорость: ↓ %s  ↑ %s\nСегодня: ↓ %s  ↑ %s\nВсего: ↓ %s  ↑ %s\nЗа сеанс: ↓ %s  ↑ %s\nИнтерфейсы: %s", rate(down), rate(up), amount(meter.Usage.DayReceived), amount(meter.Usage.DaySent), amount(meter.Usage.TotalReceived), amount(meter.Usage.TotalSent), amount(meter.sessionReceived), amount(meter.sessionSent), interfaceNames(values))
	display(title, details, storageError)
	if diagnosticFile != nil {
		_ = json.NewEncoder(diagnosticFile).Encode(struct {
			At       time.Time
			Counters []counter
			Down, Up float64
			Usage    usage
			Title    string
			Width    float64
		}{now, values, down, up, meter.Usage, C.GoString(C.scaler_status_title()), float64(C.scaler_status_width())})
	}
}

//export scaler_set_mode
func scaler_set_mode(speed C.int) { showSpeed = speed != 0 }

//export scaler_save
func scaler_save() { save(); stopSockets() }

func save() {
	if statePath == "" {
		return
	}
	if meter.Usage == savedUsage {
		lastSave = time.Now()
		return
	}
	if err := meter.Usage.save(statePath); err != nil {
		storageError = "Ошибка сохранения: " + err.Error()
	} else {
		storageError = ""
		savedUsage = meter.Usage
	}
	lastSave = time.Now()
}

func display(title, details, problem string) {
	a, b, c := C.CString(title), C.CString(details), C.CString(problem)
	defer C.free(unsafe.Pointer(a))
	defer C.free(unsafe.Pointer(b))
	defer C.free(unsafe.Pointer(c))
	C.scaler_display(a, b, c)
}

func main() {
	runtime.LockOSThread()
	defer stopSockets()
	sample := flag.Bool("sample", false, "Вывести системные счётчики и завершить")
	diagnosticPath := flag.String("diagnostics", "", "Записывать контрольные снимки в JSONL (только для проверки)")
	loginStatus := flag.Bool("login-status", false, "Показать системное состояние автозапуска")
	flag.Parse()
	if *loginStatus {
		states := map[int]string{-1: "unsupported", 0: "disabled", 1: "enabled", 2: "requires-approval", 3: "not-found"}
		fmt.Println(states[int(C.scaler_login_status())])
		return
	}
	if *diagnosticPath != "" {
		var err error
		diagnosticFile, err = os.OpenFile(*diagnosticPath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		defer diagnosticFile.Close()
	}
	if *sample {
		values, err := counters()
		for attempts := 0; err != nil && attempts < 25; attempts++ {
			time.Sleep(time.Second)
			values, err = counters()
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		for _, v := range values {
			fmt.Printf("%s: received=%d sent=%d\n", v.Name, v.Received, v.Sent)
		}
		return
	}
	dir, err := os.UserConfigDir()
	if err == nil {
		statePath = filepath.Join(dir, "Scaler", "usage.json")
		if err := meter.Usage.load(statePath); err != nil {
			storageError = "Ошибка чтения статистики: " + err.Error()
			statePath = ""
		}
	} else {
		storageError = "Каталог статистики недоступен: " + err.Error()
	}
	savedUsage = meter.Usage
	lastSave = time.Now()
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	go func() { <-signals; C.scaler_request_quit() }()
	C.scaler_run()
	signal.Stop(signals)
}
