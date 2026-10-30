// Copyright 2026 Кислов Роман Сергеевич
// SPDX-License-Identifier: Apache-2.0
#import "traffic_graph.h"
#include <math.h>

typedef struct { double time, down, up; BOOL valid; } GraphSample;
@implementation TrafficGraph {
    GraphSample samples[320];
    NSUInteger count;
}
- (BOOL)isFlipped { return YES; }
- (void)addDownload:(double)download upload:(double)upload valid:(BOOL)valid {
    if (count == 320) { memmove(samples, samples+1, sizeof(GraphSample)*319); count--; }
    samples[count++] = (GraphSample){NSProcessInfo.processInfo.systemUptime, fmax(0,download), fmax(0,upload), valid};
    if (self.window.visible) self.needsDisplay = YES;
}
static NSString *graphRate(double value) {
    NSArray *units=@[@"Б/с",@"КиБ/с",@"МиБ/с",@"ГиБ/с"];
    NSUInteger unit=0;
    while(value>=1024 && unit<3) { value/=1024; unit++; }
    return [NSString stringWithFormat:unit ? @"%.1f %@" : @"%.0f %@",value,units[unit]];
}
- (void)text:(NSString *)text at:(NSPoint)point color:(NSColor *)color size:(CGFloat)size {
    [text drawAtPoint:point withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:size], NSForegroundColorAttributeName:color}];
}
- (void)drawRect:(NSRect)dirty {
    [super drawRect:dirty];
    double now=NSProcessInfo.processInfo.systemUptime;
    [self text:@"АКТИВНОСТЬ СЕТИ · 5 МИНУТ" at:NSMakePoint(18,8) color:NSColor.secondaryLabelColor size:10];
    for(int series=0;series<2;series++) {
        CGFloat top=32+series*110;
        NSRect plot=NSMakeRect(18,top+25,self.bounds.size.width-36,66);
        NSColor *color=series ? NSColor.systemOrangeColor : NSColor.systemBlueColor;
        double peak=0;
        for(NSUInteger i=0;i<count;i++) if(samples[i].valid && samples[i].time>=now-300) peak=fmax(peak,series ? samples[i].up : samples[i].down);
        double scale=fmax(1024,peak*1.1);
        NSString *current=@"—";
        if(count && samples[count-1].valid && now-samples[count-1].time<=60) current=graphRate(series ? samples[count-1].up : samples[count-1].down);
        [self text:[NSString stringWithFormat:@"%@  %@",series ? @"↑ Отдача" : @"↓ Загрузка",current] at:NSMakePoint(18,top) color:color size:12];
        NSString *maximum=[NSString stringWithFormat:@"макс. %@",graphRate(peak)];
        NSSize width=[maximum sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:10]}];
        [self text:maximum at:NSMakePoint(NSMaxX(plot)-width.width,top+2) color:NSColor.secondaryLabelColor size:10];
        [[NSColor.separatorColor colorWithAlphaComponent:0.5] setStroke];
        NSBezierPath *grid=[NSBezierPath bezierPath]; grid.lineWidth=0.5;
        for(int j=0;j<3;j++) { CGFloat y=plot.origin.y+j*plot.size.height/2; [grid moveToPoint:NSMakePoint(plot.origin.x,y)]; [grid lineToPoint:NSMakePoint(NSMaxX(plot),y)]; }
        [grid stroke];
        NSBezierPath *line=[NSBezierPath bezierPath]; line.lineWidth=1.6;
        BOOL connected=NO;
        [NSGraphicsContext saveGraphicsState]; NSRectClip(plot);
        for(NSUInteger i=0;i<count;i++) {
            GraphSample s=samples[i];
            if(s.time<now-300 || !s.valid) { connected=NO; continue; }
            if(i && s.time-samples[i-1].time>60) connected=NO;
            double value=series ? s.up : s.down;
            NSPoint point=NSMakePoint(plot.origin.x+(s.time-(now-300))/300*plot.size.width,NSMaxY(plot)-value/scale*plot.size.height);
            if(connected) [line lineToPoint:point]; else [line moveToPoint:point];
            connected=YES;
        }
        [color setStroke]; [line stroke];
        [NSGraphicsContext restoreGraphicsState];
    }
    [self text:@"−5 мин" at:NSMakePoint(18,239) color:NSColor.secondaryLabelColor size:10];
    [self text:@"сейчас" at:NSMakePoint(self.bounds.size.width-53,239) color:NSColor.secondaryLabelColor size:10];
}
@end
