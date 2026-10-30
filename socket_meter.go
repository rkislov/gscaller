package main

/*
#include "bridge.h"
*/
import "C"
import "fmt"

func socketCounters() ([]counter, error) {
	var rx, tx C.uint64_t
	if C.scaler_socket_counters(&rx, &tx) != 0 {
		return nil, fmt.Errorf("Статистика TCP/UDP недоступна в этой версии macOS")
	}
	return []counter{{Name: "TCP/UDP", Index: 1, Received: uint64(rx), Sent: uint64(tx)}}, nil
}
func stopSockets() { C.scaler_socket_stop() }
