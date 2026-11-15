#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Compile production queue methods against Foundation/IOSurface, without GUI."""
from pathlib import Path
import argparse
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=Path, help="Prepared Wine 11.22 source tree")
parser.add_argument("--sanitize-address", action="store_true")
args = parser.parse_args()
ROOT = args.source.resolve()
s=(ROOT/'dlls/winemac.drv/cocoa_window.m').read_text()
start=s.index('    - (void) queueIOSurface:',s.index('@implementation WineWindow'))
methods=s[start:s.index('\n@end',start)]
harness=r'''
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <IOSurface/IOSurfaceObjC.h>
#import <CoreGraphics/CoreGraphics.h>
#include <assert.h>
static NSMutableArray *mainBlocks;
static unsigned int windowDeallocations;
static CGRect cgrect_mac_from_win(CGRect rect) { return rect; }
static void OnMainThreadAsync(void (^block)(void)) { id copied=[block copy]; [mainBlocks addObject:copied]; [copied release]; }
static void drain(void)
{
    while ([mainBlocks count])
    {
        void (^block)(void) = [[mainBlocks objectAtIndex:0] retain];
        [mainBlocks removeObjectAtIndex:0];
        block();
        [block release];
    }
}
@interface WineContentView : NSObject
{
@public IOSurface *surface;
@public BOOL hasShape;
@public CGRect rect, dirty;
@public unsigned int surfaceUpdates, shapeUpdates, displays;
}
- (void)setIOSurface:(IOSurface*)value;
- (void)setSurfaceRect:(CGRect)value;
- (void)setNeedsDisplayInRect:(NSRect)value;
- (void)setHasShape:(BOOL)value;
- (void)setNeedsDisplay:(BOOL)value;
@end
@implementation WineContentView
- (void)setIOSurface:(IOSurface*)value { [value retain]; [surface release]; surface=value; surfaceUpdates++; }
- (void)setSurfaceRect:(CGRect)value { rect=value; }
- (void)setNeedsDisplayInRect:(NSRect)value { dirty=NSRectToCGRect(value); displays++; }
- (void)setHasShape:(BOOL)value { hasShape=value; shapeUpdates++; }
- (void)setNeedsDisplay:(BOOL)value { if (value) displays++; }
- (void)dealloc { [surface release]; [super dealloc]; }
@end
@interface WineWindow : NSObject
{
    NSLock* surfaceUpdateLock;
    IOSurface* pendingIOSurface;
    BOOL pendingHasShape;
    CGRect pendingSurfaceRect, pendingDirtyRect;
    BOOL pendingColorUpdate, pendingShapeUpdate, surfaceUpdateScheduled, surfaceUpdatesClosed;
    BOOL closing;
@public WineContentView *testView;
@public unsigned int transparencyChecks;
}
@property BOOL closing;
- (WineContentView*)contentView;
- (void)checkTransparency;
- (void)queueIOSurface:(IOSurface*)surface rect:(CGRect)rect dirty:(CGRect)dirty;
- (void)queueHasShape:(BOOL)hasShape;
- (void)applyPendingSurfaceUpdates;
- (void)discardPendingSurfaceUpdates;
@end
@implementation WineWindow
@synthesize closing;
- (instancetype)init { if ((self=[super init])) { surfaceUpdateLock=[NSLock new]; testView=[WineContentView new]; } return self; }
- (WineContentView*)contentView { return testView; }
- (void)checkTransparency { transparencyChecks++; }
- (void)dealloc { windowDeallocations++; [pendingIOSurface release]; [surfaceUpdateLock release]; [testView release]; [super dealloc]; }
METHODS
@end
static IOSurfaceRef makeSurface(void)
{
    return IOSurfaceCreate((CFDictionaryRef)@{ (id)kIOSurfaceWidth:@8, (id)kIOSurfaceHeight:@8, (id)kIOSurfaceBytesPerElement:@4 });
}
int main(void)
{
    @autoreleasepool
    {
        mainBlocks=[NSMutableArray new];
        IOSurfaceRef a=makeSurface(), b=makeSurface();
        assert(a && b);
        CFIndex ar=CFGetRetainCount(a), br=CFGetRetainCount(b);
        WineWindow *window=[WineWindow new];
        CGRect rect=CGRectMake(0,0,8,8);
        for (unsigned int i=0; i<1000; i++)
        {
            [window queueIOSurface:(IOSurface*)(i%2 ? b : a) rect:rect dirty:CGRectMake(i%8,0,1,1)];
            [window queueHasShape:(i==999)];
        }
        assert([mainBlocks count]==1);
        assert(CFGetRetainCount(a)==ar && CFGetRetainCount(b)==br+1);
        drain();
        assert(window->testView->surface==(IOSurface*)b);
        assert(window->testView->surfaceUpdates==1 && window->testView->shapeUpdates==1);
        assert(window->testView->hasShape && window->transparencyChecks==1);
        assert(CGRectEqualToRect(window->testView->dirty,CGRectMake(0,0,8,1)));
        assert(CFGetRetainCount(a)==ar && CFGetRetainCount(b)==br+1);
        [window queueHasShape:NO];
        drain();
        assert(!window->testView->hasShape && window->testView->surfaceUpdates==1);
        [window queueIOSurface:(IOSurface*)a rect:rect dirty:rect];
        assert(CFGetRetainCount(a)==ar+1);
        window.closing=YES;
        [window discardPendingSurfaceUpdates];
        assert(CFGetRetainCount(a)==ar);
        [window queueIOSurface:(IOSurface*)a rect:rect dirty:rect];
        [window queueHasShape:YES];
        assert([mainBlocks count]==1 && CFGetRetainCount(a)==ar);
        drain();
        assert(window->testView->surfaceUpdates==1 && window->testView->shapeUpdates==2);
        [window release];
        assert(CFGetRetainCount(a)==ar && CFGetRetainCount(b)==br);
        window=[WineWindow new];
        [window queueIOSurface:(IOSurface*)a rect:rect dirty:rect];
        [window release];
        /* The production asynchronous block must own the window until drain. */
        assert(windowDeallocations==1);
        drain();
        assert(windowDeallocations==2);
        CFRelease(a); CFRelease(b);
        [mainBlocks release];
        puts("PASS: IOSurface latest-frame/shape coalescing, dirty union, close barrier and pending ownership");
    }
    assert(windowDeallocations==2);
    return 0;
}
'''.replace('METHODS',methods)
with tempfile.TemporaryDirectory(prefix='macgacha-surface-', dir='/tmp') as tmp:
    output = Path(tmp)
    source = output / 'surface-queue-harness.m'
    source.write_text(harness)
    exe = output / 'surface-queue-harness'
    flags = ['-fsanitize=address'] if args.sanitize_address else []
    subprocess.run(['/usr/bin/clang', '-std=gnu11', '-fblocks', '-fno-objc-arc',
                    '-Wall', '-Wextra', '-Werror', *flags,
                    '-framework', 'Foundation', '-framework', 'CoreGraphics',
                    '-framework', 'IOSurface', str(source), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
