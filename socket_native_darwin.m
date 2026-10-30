// Copyright 2026 Кислов Роман Сергеевич
// SPDX-License-Identifier: Apache-2.0
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include "bridge.h"

// Optional private framework: load dynamically and check the selectors we use.
// No descriptors, addresses or process names are requested or retained.
@protocol ScalerStats <NSObject>
- (id)initWithQueue:(dispatch_queue_t)queue;
- (void)setDelegate:(id)delegate;
- (BOOL)addAllTCP:(uint64_t)filter;
- (BOOL)addAllUDP:(uint64_t)filter;
- (void)queryAllCounts:(id)completion;
- (void)invalidate;
- (id)currentSnapshot;
- (uint64_t)sourceIdentifier;
- (uint64_t)rxWiFiBytes;
- (uint64_t)txWiFiBytes;
- (uint64_t)rxWiredBytes;
- (uint64_t)txWiredBytes;
- (uint64_t)rxCellularBytes;
- (uint64_t)txCellularBytes;
@end
@interface ScalerSocketCollector : NSObject {
@public
 NSMutableDictionary *previous;
 uint64_t received, sent;
 BOOL valid;
}
@end
@implementation ScalerSocketCollector
- (id)init { if ((self=[super init])) { previous=[NSMutableDictionary new]; valid=YES; } return self; }
- (void)dealloc { [previous release]; [super dealloc]; }
- (void)statisticsManager:(id)m didAddSource:(id<ScalerStats>)source { [source setDelegate:self]; }
- (void)statisticsManager:(id)m didRemoveSource:(id<ScalerStats>)source {
 [self sourceDidReceiveCounts:source];
 [previous removeObjectForKey:@([source sourceIdentifier])];
}
- (void)sourceDidReceiveDescription:(id)source {}
- (void)sourceDidReceiveCounts:(id<ScalerStats>)source {
 id<ScalerStats> snapshot=[source currentSnapshot];
 if (!snapshot) return;
 for (NSString *name in @[@"rxWiFiBytes",@"txWiFiBytes",@"rxWiredBytes",@"txWiredBytes",@"rxCellularBytes",@"txCellularBytes"]) {
  if (![(id)snapshot respondsToSelector:NSSelectorFromString(name)]) { valid=NO; return; }
 }
 uint64_t rx=[snapshot rxWiFiBytes]+[snapshot rxWiredBytes]+[snapshot rxCellularBytes];
 uint64_t tx=[snapshot txWiFiBytes]+[snapshot txWiredBytes]+[snapshot txCellularBytes];
 NSNumber *key=@([source sourceIdentifier]);
 NSArray *old=previous[key];
 if (old) {
  uint64_t a=[old[0] unsignedLongLongValue], b=[old[1] unsignedLongLongValue];
  if(rx>=a) received+=rx-a;
  if(tx>=b) sent+=tx-b;
 }
 previous[key]=@[@(rx),@(tx)];
}
@end
static dispatch_queue_t statsQueue;
static id<ScalerStats> statsManager;
static ScalerSocketCollector *collector;
static BOOL queryPending;
static uint64_t generation;
static void prepareQueue(void) {
 static dispatch_once_t once;
 dispatch_once(&once, ^{ statsQueue=dispatch_queue_create("local.gscaller.statistics", DISPATCH_QUEUE_SERIAL); });
}
int scaler_socket_counters(uint64_t *rx,uint64_t *tx) {
 prepareQueue();
 __block int status=0;
 dispatch_sync(statsQueue, ^{
  @autoreleasepool {
   if (!statsManager) {
    static void *framework;
    if (!framework) framework=dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics",RTLD_LAZY|RTLD_LOCAL);
    Class cls=NSClassFromString(@"NWStatisticsManager");
    for(NSString *name in @[@"initWithQueue:",@"setDelegate:",@"addAllTCP:",@"addAllUDP:",@"queryAllCounts:",@"invalidate"]) {
     if(![cls instancesRespondToSelector:NSSelectorFromString(name)]) {status=-1;return;}
    }
    statsManager=[(id<ScalerStats>)[cls alloc] initWithQueue:statsQueue];
    collector=[ScalerSocketCollector new];
    [statsManager setDelegate:collector];
    if(![statsManager addAllTCP:0] || ![statsManager addAllUDP:0]) { collector->valid=NO; status=-1;return;}
   }
   if(!collector->valid) {status=-1;return;}
   *rx=collector->received; *tx=collector->sent;
   if(!queryPending) {
    queryPending=YES;
    uint64_t current=generation;
    [statsManager queryAllCounts:^{ if(current==generation) queryPending=NO; }];
   }
  }
 });
 return status;
}
void scaler_socket_stop(void) {
 prepareQueue();
 dispatch_sync(statsQueue, ^{
  generation++;
  [statsManager invalidate]; [(id)statsManager release]; statsManager=nil;
  [collector release]; collector=nil;
  queryPending=NO;
 });
}
