// Copyright 2026 Кислов Роман Сергеевич
// SPDX-License-Identifier: Apache-2.0

#ifndef SCALER_BRIDGE_H
#define SCALER_BRIDGE_H
#include <stdint.h>
typedef struct { char name[16]; uint32_t index; uint64_t received, sent; } ScalerCounter;
int scaler_socket_counters(uint64_t *rx, uint64_t *tx);
void scaler_socket_stop(void);
int scaler_counters(ScalerCounter *out, int capacity);
unsigned int scaler_default_index(int family);
const char *scaler_status_title(void);
double scaler_status_width(void);
int scaler_login_status(void);
void scaler_request_quit(void);
void scaler_run(void);
void scaler_graph(double down, double up, int valid);
void scaler_display(const char *title, const char *details, const char *error);
#endif
