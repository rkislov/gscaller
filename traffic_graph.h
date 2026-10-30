// Copyright 2026 Кислов Роман Сергеевич
// SPDX-License-Identifier: Apache-2.0
#import <Cocoa/Cocoa.h>

@interface TrafficGraph : NSView
- (void)addDownload:(double)download upload:(double)upload valid:(BOOL)valid;
@end
