/* Copyright (C) 2003-2015 LiveCode Ltd.
 
 This file is part of LiveCode.
 
 LiveCode is free software; you can redistribute it and/or modify it under
 the terms of the GNU General Public License v3 as published by the Free
 Software Foundation.
 
 LiveCode is distributed in the hope that it will be useful, but WITHOUT ANY
 WARRANTY; without even the implied warranty of MERCHANTABILITY or
 FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 for more details.
 
 You should have received a copy of the GNU General Public License
 along with LiveCode.  If not see <http://www.gnu.org/licenses/>.  */

#include <Cocoa/Cocoa.h>
#include <Carbon/Carbon.h>

#include "typedefs.h"
#include "platform.h"

#include "mac-internal.h"

#include "graphics_util.h"

#include <objc/objc-runtime.h>

////////////////////////////////////////////////////////////////////////////////

enum
{
	kMCMacPlatformBreakEvent = 0,
	kMCMacPlatformMouseSyncEvent = 1,
};

////////////////////////////////////////////////////////////////////////////////

@implementation com_runrev_livecode_MCApplication

- (void)sendEvent:(NSEvent *)p_event
{
    MCApplicationDelegate * t_delegate = [self delegate];
    if (!static_cast<MCMacPlatformCore *>(t_delegate.platform) -> ApplicationSendEvent(p_event))
	{
        [super sendEvent: p_event];
    }
}

@end

bool MCMacPlatformCore::ApplicationSendEvent(NSEvent *p_event)
{
    if ([p_event type] == NSApplicationDefined &&
        [p_event subtype] == kMCMacPlatformMouseSyncEvent)
	{
        HandleMouseSync();
		return true;
	}

	// MW-2014-08-14: [[ Bug 13016 ]] Whilst the windowserver moves a window
	//   we intercept mouseDragged events so we can keep script informed.
	NSWindow *t_window;
	t_window = [p_event window];
    
    MCMacPlatformWindow * t_platform_window = static_cast<MCMacPlatformWindow *>(m_moving_window);
    
	if (m_moving_window != nil &&
		t_window == t_platform_window -> GetHandle())
	{
		if ([p_event type] == NSLeftMouseDragged)
			t_platform_window -> WindowMoved(t_window);
		else if ([p_event type] == NSLeftMouseUp)
			ApplicationWindowStoppedMoving(m_moving_window);
	}
	
	return false;
}

bool MCMacPlatformCore::ApplicationWindowIsMoving(MCPlatformWindowRef p_window)
{
    return p_window == m_moving_window;
}

void MCMacPlatformCore::ApplicationWindowStartedMoving(MCPlatformWindowRef p_window)
{
    if (m_moving_window != nil)
        ApplicationWindowStoppedMoving(m_moving_window);
    
    p_window -> Retain();
    m_moving_window = p_window;
}

void MCMacPlatformCore::ApplicationWindowStoppedMoving(MCPlatformWindowRef p_window)
{
    if (m_moving_window == nil)
        return;
    
	// IM-2014-10-29: [[ Bug 13814 ]] Call windowMoveFinished to signal end of dragging,
	//   which is not reported to the delegate when the window doesn't actually move.
	[[((MCMacPlatformWindow*)m_moving_window)->GetHandle() delegate] windowMoveFinished];

    m_moving_window -> Release();
    m_moving_window = nil;
}

void MCMacPlatformCore::ApplicationBecomePseudoModalFor(NSWindow *p_window)
{
    // MERG-2016-03-04: ensure pseudo modals open above any calling modals
    [p_window setLevel: kCGPopUpMenuWindowLevel];
    m_pseudo_modal_for = p_window;
}

NSWindow *MCMacPlatformCore::ApplicationPseudoModalFor(void)
{
    // MERG-2016-03-04: ensure pseudo modals remain above any calling modals
    // If we need to check whether we're pseudo-modal, it means we're in a
    // situation where that window needs to be forced to the front
    if (m_pseudo_modal_for != nil)
        [m_pseudo_modal_for orderFrontRegardless];
    
    return m_pseudo_modal_for;
}

////////////////////////////////////////////////////////////////////////////////

@implementation com_runrev_livecode_MCPendingAppleEvent

- (id)initWithEvent: (const AppleEvent *)event andReply: (AppleEvent *)reply
{
    self = [super init];
    if (self == nil)
        return nil;
    
    AEDuplicateDesc(event, &m_event);
    AEDuplicateDesc(reply, &m_reply);
    
    return self;
}

- (void)dealloc
{
    AEDisposeDesc(&m_event);
    AEDisposeDesc(&m_reply);
    [super dealloc];
}

- (OSErr)process
{
    return AEResumeTheCurrentEvent(&m_event, &m_reply, (AEEventHandlerUPP)kAEUseStandardDispatch, 0);
}

- (AppleEvent *)getEvent
{
    return &m_event;
}

- (AppleEvent *)getReply
{
    return &m_reply;
}

@end

////////////////////////////////////////////////////////////////////////////////

@implementation com_runrev_livecode_MCApplicationDelegate

@synthesize platform=m_platform;

//////////

- (id)initWithArgc:(int)argc argv:(MCStringRef *)argv envp:(MCStringRef*)envp
{
	self = [super init];
	if (self == nil)
		return nil;
	
	m_argc = argc;
	m_argv = argv;
	m_envp = envp;
	
    m_explicit_quit = false;
    
    m_running = false;
    
    m_pending_apple_events = [[NSMutableArray alloc] initWithCapacity: 0];
    
    m_platform = nil;
    
	return self;
}

//////////

- (void)initializeModules
{
	m_platform->InitializeColorTransform();
	m_platform->InitializeAbortKey();
    m_platform->InitializeMenu();
}

- (void)finalizeModules
{
    m_platform->FinalizeMenu();
	m_platform->FinalizeAbortKey();
	m_platform->FinalizeColorTransform();
}

//////////

- (NSError *)application:(NSApplication *)application willPresentError:(NSError *)error
{
    return error;
}

//////////

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag
{
	return NO;
}

//////////

static OSErr preDispatchAppleEvent(const AppleEvent *p_event, AppleEvent *p_reply, SRefCon p_context)
{
    return [(MCApplicationDelegate*)[NSApp delegate] preDispatchAppleEvent: p_event withReply: p_reply];
}

- (OSErr)preDispatchAppleEvent: (const AppleEvent *)p_event withReply: (AppleEvent *)p_reply
{
    extern OSErr MCAppleEventHandlerDoAEAnswer(const AppleEvent *event, AppleEvent *reply, long refcon);
    extern OSErr MCAppleEventHandlerDoSpecial(const AppleEvent *event, AppleEvent *reply, long refcon);
    extern OSErr MCAppleEventHandlerDoOpenDoc(const AppleEvent *event, AppleEvent *reply, long refcon);
    
    if (!m_running)
    {
        MCPendingAppleEvent *t_event;
        t_event = [[MCPendingAppleEvent alloc] initWithEvent: p_event andReply: p_reply];
        [m_pending_apple_events addObject: t_event];
        AESuspendTheCurrentEvent(p_event);
        return noErr;
    }
    
	DescType rType;
	Size rSize;
	AEEventClass aeclass;
	AEGetAttributePtr(p_event, keyEventClassAttr, typeType, &rType, &aeclass, sizeof(AEEventClass), &rSize);
    
	AEEventID aeid;
	AEGetAttributePtr(p_event, keyEventIDAttr, typeType, &rType, &aeid, sizeof(AEEventID), &rSize);
    
    // MW-2014-08-12: [[ Bug 13140 ]] Handle the appleEvent to cause a termination otherwise
    //   we don't quit if the app is in the background (I think this is because we roll our
    //   own event handling loop and don't use [NSApp run]).
    if (aeclass == kCoreEventClass && aeid == kAEQuitApplication)
    {
        [NSApp terminate: self];
        return noErr;
    }
    
    if (aeclass == kCoreEventClass && aeid == kAEAnswer)
        return MCAppleEventHandlerDoAEAnswer(p_event, p_reply, 0);
    
    // SN-2014-10-13: [[ Bug 13644 ]] Break the wait loop after we handled the Apple Event
    OSErr t_err;
    t_err = MCAppleEventHandlerDoSpecial(p_event, p_reply, 0);
    if (t_err == errAEEventNotHandled)
    {
        if (aeclass == kCoreEventClass && aeid == kAEOpenDocuments)
            t_err = MCAppleEventHandlerDoOpenDoc(p_event, p_reply, 0);
    }
    
    if (t_err != errAEEventNotHandled)
        m_platform -> BreakWait();
    
    return t_err;
}

- (void)applicationWillFinishLaunching: (NSNotification *)notification
{
    AEInstallSpecialHandler(keyPreDispatch, preDispatchAppleEvent, False);
}

- (void)applicationDidFinishLaunching: (NSNotification *)notification
{	
	// Initialize everything.
	[self initializeModules];
	
	NSAutoreleasePool *t_pool;
	t_pool = [[NSAutoreleasePool alloc] init];
	
    // MW-2014-04-23: [[ Bug 12080 ]] Always create a dummy window which should
    //   always sit at the bottom of our window list so that palettes have something
    //   to float above.
    NSWindow *t_dummy_window;
    t_dummy_window = [[NSWindow alloc] initWithContentRect: NSZeroRect styleMask: NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:YES];
    [t_dummy_window orderFront: nil];
    
	// Dispatch the startup callback.
	int t_error_code;
	MCAutoStringRef t_error_message;
	m_platform -> GetCallback() -> SendApplicationStartup(m_argc, m_argv, m_envp, t_error_code, &t_error_message);
	
	[t_pool release];
	
	// If the error code is non-zero, startup failed so quit.
	if (t_error_code != 0)
	{
		// If the error message is non-nil, report it in a suitable way.
		if (*t_error_message != nil)
        {
            MCAutoStringRefAsUTF8String t_utf8_message;
            t_utf8_message . Lock(*t_error_message);
			fprintf(stderr, "Startup error - %s\n", *t_utf8_message);
        }
		
		// Finalize everything
		[self finalizeModules];
		
		// Now exit the application with the appropriate code.
		exit(t_error_code);
	}
    
    m_running = true;

    // Dispatch pending apple events
    while([m_pending_apple_events count] > 0)
    {
        MCPendingAppleEvent *t_event;
        t_event = [m_pending_apple_events objectAtIndex: 0];
        [m_pending_apple_events removeObjectAtIndex: 0];
        
        [self preDispatchAppleEvent: [t_event getEvent] withReply: [t_event getReply]];
        AEResumeTheCurrentEvent([t_event getEvent], [t_event getReply], (AEEventHandlerUPP)kAENoDispatch, 0);
        
        //[t_event process];
        
        [t_event release];
    }
    
	// We started up successfully, so queue the root runloop invocation
	// message.
	[self performSelector: @selector(runMainLoop) withObject: nil afterDelay: 0];
}

- (void)runMainLoop
{
    for(;;)
    {
        bool t_continue;
    
        NSAutoreleasePool *t_pool;
        t_pool = [[NSAutoreleasePool alloc] init];
    
        m_platform -> GetCallback() -> SendApplicationRun(t_continue);
        
        [t_pool release];
        
        if (!t_continue)
            break;
    }
    
    // If we get here then it was due to an exit from the main runloop caused
    // by an explicit quit. In this case, then we set a flag so that termination
    // happens without sending messages.
    m_explicit_quit = true;
	
    [NSApp terminate: self];
}

//////////

// This is sent when the last window closes - as LiveCode apps are expected
// to control termination (via quit), we always say 'NO' don't close.
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
	return NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    // If the quit was explicit (runloop exited) then just terminate now.
    if (m_explicit_quit)
        return NSTerminateNow;
    
    if (m_platform -> ApplicationPseudoModalFor() != nil)
        return NSTerminateCancel;
    
    // There is an NSApplicationTerminateReplyLater result code which will place
	// the runloop in a modal loop for exit dialogs. We'll try the simpler
	// option for now of just sending the callback and seeing what AppKit does
	// with the (eventual) event loop that will result...
	bool t_terminate;
	m_platform -> GetCallback() -> SendApplicationShutdownRequest(t_terminate);
	
	if (t_terminate)
		return NSTerminateNow;
	
	return NSTerminateCancel;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
	// Dispatch the shutdown callback.
	int t_exit_code;
	m_platform -> GetCallback() -> SendApplicationShutdown(t_exit_code);
	
	// Finalize everything
	[self finalizeModules];
	
	// Now exit the application with the appropriate code.
	exit(t_exit_code);
}

// Dock menu handling.
- (NSMenu *)applicationDockMenu:(NSApplication *)sender
{
	return static_cast<MCMacPlatformCore *>(m_platform) -> GetIconMenu();
}

//////////

- (void)applicationWillHide:(NSNotification *)notification;
{
}

- (void)applicationDidHide:(NSNotification *)notification;
{
}

- (void)applicationWillUnhide:(NSNotification *)notification;
{
}

- (void)applicationDidUnhide:(NSNotification *)notification
{
}

//////////

- (void)applicationWillBecomeActive:(NSNotification *)notification
{
    // MW-2014-04-23: [[ Bug 12080 ]] Loop through all our windows and any MCPanels
    //   get set to not be floating. This is so that they sit behind the windows
    //   of other applications (like we did before).
    for(NSNumber *t_window_id in [[NSWindow windowNumbersWithOptions: 0] reverseObjectEnumerator])
    {
        NSWindow *t_window;
        t_window = [NSApp windowWithWindowNumber: [t_window_id longValue]];
        if (![t_window isKindOfClass: [com_runrev_livecode_MCPanel class]])
        {
            continue;
        }
        
        [t_window setFloatingPanel: YES];
    }
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
	m_platform -> GetCallback() -> SendApplicationResume();
}

- (void)applicationWillResignActive:(NSNotification *)notification
{
    // MW-2014-04-23: [[ Bug 12080 ]] Loop through all our windows and move any
    //   MCPanels to be above the top-most non-panel.
    NSInteger t_above_window_id;
    for(NSNumber *t_window_id in [[NSWindow windowNumbersWithOptions: 0] reverseObjectEnumerator])
    {
        NSWindow *t_window;
        t_window = [NSApp windowWithWindowNumber: [t_window_id longValue]];
        if (![t_window isKindOfClass: [com_runrev_livecode_MCPanel class]])
        {
            t_above_window_id = [t_window_id longValue];
            continue;
        }
        
        [t_window setFloatingPanel: NO];
        [t_window orderWindow: NSWindowAbove relativeTo: t_above_window_id];
        t_above_window_id = [t_window_id longValue];
    }
}

- (void)applicationDidResignActive:(NSNotification *)notification
{
	m_platform -> GetCallback() -> SendApplicationSuspend();
}

//////////

- (void)applicationWillUpdate:(NSNotification *)notification
{
}

- (void)applicationDidUpdate:(NSNotification *)notification
{
}

//////////

- (void)applicationDidChangeScreenParameters:(NSNotification *)notification
{
	// Make sure we refetch the primary screen height.
    m_platform -> SetHasDesktopHeight(false);
	// Dispatch the notification.
	m_platform -> GetCallback() -> SendScreenParametersChanged();
}

//////////

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename
{
	return NO;
}

- (void)application:(NSApplication *)sender openFiles:(NSArray *)filenames
{
	[NSApp replyToOpenOrPrint: NSApplicationDelegateReplyCancel];
}

- (BOOL)application:(NSApplication *)sender openTempFile:(NSString *)filename
{
	return NO;
}

- (BOOL)applicationShouldOpenUntitledFile:(NSApplication *)sender
{
	return NO;
}

- (BOOL)applicationOpenUntitledFile:(NSApplication *)sender
{
	return NO;
}

- (BOOL)application:(id)sender openFileWithoutUI:(NSString *)filename
{
	return NO;
}

//////////

- (NSApplicationPrintReply)application:(NSApplication *)application printFiles:(NSArray *)fileNames withSettings:(NSDictionary *)printSettings showPrintPanels:(BOOL)showPrintPanels
{
	return NSPrintingCancelled;
}

//////////

@end

////////////////////////////////////////////////////////////////////////////////

void MCMacPlatformCore::GetSystemProperty(MCPlatformSystemProperty p_property, MCPlatformPropertyType p_type, void *r_value)
{
	switch(p_property)
	{
		case kMCPlatformSystemPropertyDoubleClickInterval:
            // Get the double-click interval, in milliseconds
            *(uint16_t *)r_value = uint16_t([NSEvent doubleClickInterval] * 1000.0);
			break;
			
		case kMCPlatformSystemPropertyCaretBlinkInterval:
        {
            // Query the user's settings for the cursor blink rate
            NSInteger t_rate_ms = [[NSUserDefaults standardUserDefaults] integerForKey:@"NSTextInsertionPointBlinkPeriod"];
            
            // If the query failed, use the standard value (this seems to be
            // 567ms on OSX, not that this is documented anywhere).
            if (t_rate_ms == 0)
                t_rate_ms = 567;
            
            *(uint16_t *)r_value = uint16_t(t_rate_ms);
			break;
        }
			
		case kMCPlatformSystemPropertyHiliteColor:
		{
            NSColor *t_color;
            t_color = [[NSColor selectedTextBackgroundColor] colorUsingColorSpaceName: NSCalibratedRGBColorSpace];
			((MCColor *)r_value) -> red = [t_color redComponent] * 65535;
			((MCColor *)r_value) -> green = [t_color greenComponent] * 65535;
			((MCColor *)r_value) -> blue = [t_color blueComponent] * 65535;
		}
		break;
			
		case kMCPlatformSystemPropertyAccentColor:
			((MCColor *)r_value) -> red = 0x0000;
			((MCColor *)r_value) -> green = 0x0000;
			((MCColor *)r_value) -> blue = 0x8080;
			break;
			
		case kMCPlatformSystemPropertyMaximumCursorSize:
			*(int32_t *)r_value = 256;
			break;
		
		case kMCPlatformSystemPropertyCursorImageSupport:
			*(MCPlatformCursorImageSupport *)r_value = kMCPlatformCursorImageSupportAlpha; 
			break;
			
        case kMCPlatformSystemPropertyVolume:
            GetGlobalVolume(*(double *)r_value);
            break;
            
		default:
			assert(false);
			break;
	}
}

void MCMacPlatformCore::SetSystemProperty(MCPlatformSystemProperty p_property, MCPlatformPropertyType p_type, void *p_value)
{
    switch(p_property)
    {
        case kMCPlatformSystemPropertyVolume:
            SetGlobalVolume(*(double *)p_value);
            break;
        
        default:
            assert(false);
            break;
    }
}

////////////////////////////////////////////////////////////////////////////////

void MCMacPlatformCore::BreakWait(void)
{
    [m_callback_lock lock];
	if (m_wait_broken)
    {
        [m_callback_lock unlock];
        return;
    }
    m_wait_broken = true;
	[m_callback_lock unlock];
    
	NSAutoreleasePool *t_pool;
	t_pool = [[NSAutoreleasePool alloc] init];
	
	NSEvent *t_event;
	t_event = [NSEvent otherEventWithType:NSApplicationDefined
								 location:NSMakePoint(0, 0)
							modifierFlags:0
								timestamp:0
							 windowNumber:0
								  context:NULL
								  subtype:kMCMacPlatformBreakEvent
									data1:0
									data2:0];
	
	[NSApp postEvent: t_event
			 atStart: YES];
	
	[t_pool release];
}

static void runloop_observer(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info)
{
    MCMacPlatformCore * t_platform = (MCMacPlatformCore *) info;
    if (t_platform -> InBlockingWait())
    {
        t_platform -> BreakWait();
    }
}

bool MCMacPlatformCore::InBlockingWait(void)
{
    return m_in_blocking_wait;
}

void MCMacPlatformCore::EnableEventChecking(void)
{
	m_event_checking_enabled += 1;
}

void MCMacPlatformCore::DisableEventChecking(void)
{
	m_event_checking_enabled -= 1;
}

bool MCMacPlatformCore::IsEventCheckingEnabled(void)
{
	return m_event_checking_enabled == 0;
}

bool MCMacPlatformCore::WaitForEvent(double p_duration, bool p_blocking)
{
	if (!IsEventCheckingEnabled())
		return false;
	
	// Handle all the pending callbacks.
    MCCallback *t_callbacks;
    uindex_t t_callback_count;
    [m_callback_lock lock];
	m_wait_broken = false;
    t_callbacks = m_callbacks;
    t_callback_count = m_callback_count;
    m_callbacks = nil;
    m_callback_count = 0;
    [m_callback_lock unlock];
    
	for(uindex_t i = 0; i < t_callback_count; i++)
		t_callbacks[i] . method(t_callbacks[i] . context);
	MCMemoryDeleteArray(t_callbacks);
	t_callbacks = nil;
	t_callback_count = 0;
	
	// Make sure we have our observer and install it. This is used when we are
	// blocking and should break the event loop whenever a new event is added
	// to the queue.
	if (m_observer == nil)
	{
        CFRunLoopObserverContext t_context = {0, this, nil, nil, nil};
		m_observer = CFRunLoopObserverCreate(kCFAllocatorDefault, kCFRunLoopAfterWaiting, true, 0, runloop_observer, &t_context);
		CFRunLoopAddObserver([[NSRunLoop currentRunLoop] getCFRunLoop], m_observer, (CFStringRef)NSEventTrackingRunLoopMode);
	}
	
	m_in_blocking_wait = true;
	
	bool t_modal;
	t_modal = m_modal_session_count > 0;
	
	NSAutoreleasePool *t_pool;
	t_pool = [[NSAutoreleasePool alloc] init];
	
    // MW-2014-07-24: [[ Bug 12939 ]] If we are running a modal session, then don't then wait
    //   for events - event handling happens inside the modal session.
    NSEvent *t_event;
    
    // MW-2014-04-09: [[ Bug 10767 ]] Don't run in the modal panel runloop mode as this stops
    //   WebViews from working.    
    // SN-2014-10-02: [[ Bug 13555 ]] We want the event to be sent in case it passes through
    //   the modal session.
    t_event = [NSApp nextEventMatchingMask: p_blocking ? NSApplicationDefinedMask : NSAnyEventMask
                                 untilDate: [NSDate dateWithTimeIntervalSinceNow: p_duration]
                                    inMode: p_blocking ? NSEventTrackingRunLoopMode : NSDefaultRunLoopMode
                                   dequeue: YES];
    
    // Run the modal session, if it has been created yet (it might not if this
    // wait was triggered by reacting to an event caused as part of creating
    // the modal session, e.g. when losing window focus).
	if (t_modal && m_modal_sessions[m_modal_session_count - 1].session != nil)
		[NSApp runModalSession: m_modal_sessions[m_modal_session_count - 1] . session];
    
	m_in_blocking_wait = false;

	if (t_event != nil)
	{
		if ([t_event type] == NSLeftMouseDown || [t_event type] == NSLeftMouseDragged)
		{
			m_last_mouse_event = t_event;
			[t_event retain];
			[NSApp sendEvent: t_event];
		}
		else
		{
			if ([t_event type] == NSLeftMouseUp)
			{
				[m_last_mouse_event release];
				m_last_mouse_event = nil;
			}
			
			[NSApp sendEvent: t_event];
		}
	}
	
	[t_pool release];
    
    m_animation_current_time = CFAbsoluteTimeGetCurrent();
	
	return t_event != nil;
}


void MCMacPlatformCore::BeginModalSession(MCMacPlatformWindow *p_window)
{
    // MW-2014-07-24: [[ Bug 12898 ]] The context of the click is changing, so make sure we sync
    //   mouse state - i.e. send a mouse release if in mouseDown and send a mouseLeave for the
    //   current mouse window.
	SyncMouseBeforeDragging();
    
	/* UNCHECKED */ MCMemoryResizeArray(m_modal_session_count + 1, m_modal_sessions, m_modal_session_count);
	
	m_modal_sessions[m_modal_session_count - 1] . is_done = false;
	m_modal_sessions[m_modal_session_count - 1] . window = p_window;
	p_window -> Retain();
	// IM-2015-01-30: [[ Bug 14140 ]] lock the window frame to prevent it from being centered on the screen.
	p_window->SetFrameLocked(true);
	m_modal_sessions[m_modal_session_count - 1] . session = [NSApp beginModalSessionForWindow: (NSWindow *)(p_window -> GetHandle())];
	p_window->SetFrameLocked(false);
}

void MCMacPlatformCore::EndModalSession(MCMacPlatformWindow *p_window)
{
	uindex_t t_index;
	for(t_index = 0; t_index < m_modal_session_count; t_index++)
		if (m_modal_sessions[t_index] . window == p_window)
			break;
	
	if (t_index == m_modal_session_count)
		return;
	
	m_modal_sessions[t_index] . is_done = true;
	
	for(uindex_t t_final_index = m_modal_session_count; t_final_index > 0; t_final_index--)
	{
		if (!m_modal_sessions[t_final_index - 1] . is_done)
			return;
		
		[NSApp endModalSession: m_modal_sessions[t_final_index - 1] . session];
		[m_modal_sessions[t_final_index - 1] . window -> GetHandle() orderOut: nil];
		m_modal_sessions[t_final_index - 1] . window -> Release();
		m_modal_session_count -= 1;
	}
}

void MCMacPlatformCore::ScheduleCallback(void (*p_callback)(void *), void *p_context)
{
    [m_callback_lock lock];
	/* UNCHECKED */ MCMemoryResizeArray(m_callback_count + 1, m_callbacks, m_callback_count);
	m_callbacks[m_callback_count - 1] . method = p_callback;
	m_callbacks[m_callback_count - 1] . context = p_context;
    [m_callback_lock unlock];
    
    BreakWait();
}

////////////////////////////////////////////////////////////////////////////////

@interface com_runrev_livecode_MCPlatformBaseDeathGrip: NSObject
{
	MCPlatform::Base *m_pointer;
}

- (id)initWithPointer: (MCPlatform::Base *)pointer;
- (void)dealloc;

@end

@implementation com_runrev_livecode_MCPlatformBaseDeathGrip

- (id)initWithPointer: (MCPlatform::Base *)pointer
{
	self = [super init];
	if (self == nil)
		return nil;
	
	m_pointer = pointer;

	return self;
}

- (void)dealloc
{
	m_pointer -> Release();
	[super dealloc];
}

@end

// When an event is dispatched to high-level it is possible for the main object
// to which it refers to be deleted. This can cause problems in the cocoa event
// handling chain. A deathgrip lasts for the scope of the current autorelease
// pool - so means such objects won't get completely destroyed until after event
// handling has completed.
void MCMacPlatformCore::DeathGrip(MCPlatform::Base * p_pointer)
{
	// Retain the pointer.
	p_pointer -> Retain();
	
	// Now push an autorelease object onto the stack that will release the object
	// after event dispatch.
	[[[com_runrev_livecode_MCPlatformBaseDeathGrip alloc] initWithPointer: p_pointer] autorelease];
}

////////////////////////////////////////////////////////////////////////////////

bool MCMacPlatformCore::GetMouseButtonState(uindex_t p_button)
{
	NSUInteger t_buttons;
	t_buttons = [NSEvent pressedMouseButtons];
	if (p_button == 0)
		return t_buttons != 0;
	if (p_button == 1)
		return (t_buttons & (1 << 0)) != 0;
	if (p_button == 2)
		return (t_buttons & (1 << 2)) != 0;
	if (p_button == 3)
		return (t_buttons & (1 << 1)) != 0;
	return (t_buttons & (1 << (p_button - 1))) != 0;
}

MCPlatformModifiers MCMacPlatformCore::GetModifiersState(void)
{
	return MCMacPlatformMapNSModifiersToModifiers([NSEvent modifierFlags]);
}

bool MCMacPlatformCore::GetKeyState(MCPlatformKeyCode*& r_codes, uindex_t& r_code_count)
{
	MCPlatformKeyCode *t_codes;
	if (!MCMemoryNewArray(128, t_codes))
		return false;
	
	bool t_flags;
	t_flags = [NSEvent modifierFlags];
    
	uindex_t t_code_count;
	t_code_count = 0;
	for(uindex_t i = 0; i < 127; i++)
	{
		if (!CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, i))
			continue;
		
		MCPlatformKeyCode t_code;
        if (MCMacPlatformMapKeyCode(i, t_flags, t_code))
			t_codes[t_code_count++] = t_code;
	}
	
	r_codes = t_codes;
	r_code_count = t_code_count;
	
	return true;
}

bool MCMacPlatformCore::GetMouseClick(uindex_t p_button, MCPoint& r_location)
{
	// We want to try and remove a whole click from the queue. Which button
	// is determined by p_button and if zero means any button. So, first
	// we search for a mouseDown.
	
	NSAutoreleasePool *t_pool;
	t_pool = [[NSAutoreleasePool alloc] init];
	
	NSUInteger t_down_mask;
	t_down_mask = 0;
	if (p_button == 0 || p_button == 1) 
		t_down_mask |= NSLeftMouseDownMask;
	if (p_button == 0 || p_button == 3) 
		t_down_mask |= NSRightMouseDownMask;
	if (p_button == 0 || p_button == 2) 
		t_down_mask |= NSOtherMouseDownMask;
	
	NSEvent *t_down_event;
	t_down_event = [NSApp nextEventMatchingMask: t_down_mask untilDate: nil inMode: NSEventTrackingRunLoopMode dequeue: NO];
	
	// If there is no mouse down event then there is no click.
	if (t_down_event == nil)
	{
		[t_pool release];
		return false;
	}
	
	// Now search for a matching mouse up event.
	NSUInteger t_up_mask;
	if ([t_down_event buttonNumber] == 0)
	{
		t_down_mask = NSLeftMouseDownMask;
		t_up_mask = NSLeftMouseUpMask;
	}
	else if ([t_down_event buttonNumber] == 1)
	{
		t_down_mask = NSRightMouseDownMask;
		t_up_mask = NSRightMouseUpMask;
	}
	else
	{
		t_down_mask = NSOtherMouseDownMask;
		t_up_mask = NSOtherMouseUpMask;
	}
	
	NSEvent *t_up_event;
	t_up_event = [NSApp nextEventMatchingMask: t_up_mask untilDate: nil inMode: NSEventTrackingRunLoopMode dequeue: NO];
	
	// If there is no mouse up event then there is no click.
	if (t_up_event == nil)
	{
		[t_pool release];
		return false;
	}
	
	// If the up event preceeds the down event, there is no click.
	if ([t_down_event timestamp] > [t_up_event timestamp])
	{
		[t_pool release];
		return false;
	}
	
	// Otherwise, clear out all dragged / move etc. messages up to the mouse up event.
	[NSApp discardEventsMatchingMask: NSLeftMouseDraggedMask |
										NSRightMouseDraggedMask |
											NSOtherMouseDraggedMask |
												NSMouseMovedMask |
													NSMouseEnteredMask |
														NSMouseExitedMask
						 beforeEvent: t_up_event];
	
	// And finally deque the up event and down event.
	t_down_event = [NSApp nextEventMatchingMask: t_down_mask untilDate: nil inMode: NSEventTrackingRunLoopMode dequeue: YES];
	t_up_event = [NSApp nextEventMatchingMask: t_up_mask untilDate: nil inMode: NSEventTrackingRunLoopMode dequeue: YES];
	
	// Fetch its location.
	NSPoint t_screen_loc;
	if ([t_up_event window] != nil)
		t_screen_loc = [[t_up_event window] convertBaseToScreen: [t_up_event locationInWindow]];
	else
		t_screen_loc = [t_up_event locationInWindow];
	
	MapScreenNSPointToMCPoint(t_screen_loc, r_location);
	
	[t_pool release];
	
	return true;
}

void MCMacPlatformCore::GetMousePosition(MCPoint& r_location)
{
	MapScreenNSPointToMCPoint([NSEvent mouseLocation], r_location);
}

void MCMacPlatformCore::SetMousePosition(MCPoint p_location)
{
	CGPoint t_point;
	t_point . x = p_location . x;
	t_point . y = p_location . y;
	CGWarpMouseCursorPosition(t_point);
}

void MCMacPlatformCore::GetWindowAtPoint(MCPoint p_loc, MCPlatformWindowRef& r_window)
{
	NSPoint t_loc_cocoa;
	MapScreenMCPointToNSPoint(p_loc, t_loc_cocoa);
	
	NSInteger t_number;
	t_number = [NSWindow windowNumberAtPoint: t_loc_cocoa belowWindowWithWindowNumber: 0];
	
	NSWindow *t_window;
	t_window = [NSApp windowWithWindowNumber: t_number];
	NSRect t_content_rect;
    if (t_window != nil && [t_window conformsToProtocol:NSProtocolFromString(@"com_runrev_livecode_MCMovingFrame")])
        t_content_rect = [(NSWindow <com_runrev_livecode_MCMovingFrame>*)t_window movingFrame];
    else
        t_content_rect = [t_window frame];
    
    // MW-2014-05-28: [[ Bug 12437 ]] Seems the window at point uses inclusive co-ords
    //   in the in-rect calculation - so adjust the rect appropriately.
    t_content_rect = [t_window contentRectForFrameRect: t_content_rect];
    
    bool t_is_in_frame;
    t_content_rect . size . width += 1, t_content_rect . size . height += 1;
    t_is_in_frame = NSPointInRect(t_loc_cocoa, t_content_rect);
    
	if (t_window != nil &&
		[[t_window delegate] isKindOfClass: [MCWindowDelegate class]] &&
		t_is_in_frame)
		r_window = [(MCWindowDelegate *)[t_window delegate] platformWindow];
	else
		r_window = nil;
}

// MW-2014-07-15: [[ Bug 12800 ]] Map a window number to a platform window - if there is one.
bool MCMacPlatformCore::GetWindowWithId(uint32_t p_id, MCPlatformWindowRef& r_window)
{
    NSWindow *t_ns_window;
    t_ns_window = [NSApp windowWithWindowNumber: p_id];
    if (t_ns_window == nil)
        return false;
    
    id t_delegate;
    t_delegate = [t_ns_window delegate];
    if (t_delegate == nil)
        return false;
    
    if (![t_delegate isKindOfClass: [MCWindowDelegate class]])
        return false;
    
    r_window = [(MCWindowDelegate *)t_delegate platformWindow];
    
    return true;
}

uint32_t MCMacPlatformCore::GetEventTime(void)
{
	return [[NSApp currentEvent] timestamp] * 1000.0;
}

NSEvent *MCMacPlatformCore::GetLastMouseEvent(void)
{
	return m_last_mouse_event;
}

void MCMacPlatformCore::FlushEvents(MCPlatformEventMask p_mask)
{
	NSUInteger t_ns_mask;
	t_ns_mask = 0;
	if ((p_mask & kMCPlatformEventMouseDown) != 0)
		t_ns_mask |= NSLeftMouseDownMask | NSRightMouseDownMask | NSOtherMouseDownMask;
	if ((p_mask & kMCPlatformEventMouseUp) != 0)
		t_ns_mask |= NSLeftMouseUpMask | NSRightMouseUpMask | NSOtherMouseUpMask;
	if ((p_mask & kMCPlatformEventKeyDown) != 0)
		t_ns_mask |= NSKeyDownMask;
	if ((p_mask & kMCPlatformEventKeyUp) != 0)
		t_ns_mask |= NSKeyUpMask;
	
	NSDate *t_distant_past = [NSDate distantPast];
	for(;;)
	{
		NSEvent *t_event;
		t_event = [NSApp nextEventMatchingMask: t_ns_mask
									untilDate: t_distant_past
									inMode: NSDefaultRunLoopMode
									dequeue: YES];
		if (t_event == nil)
			break;
	}
}

void MCMacPlatformCore::Beep(void)
{
    NSBeep();
}

////////////////////////////////////////////////////////////////////////////////

void MCMacPlatformCore::GetScreenCount(uindex_t& r_count)
{
	r_count = [[NSScreen screens] count];
}

void MCMacPlatformCore::GetScreenViewport(uindex_t p_index, MCRectangle& r_viewport)
{
	NSRect t_viewport;
	t_viewport = [[[NSScreen screens] objectAtIndex: p_index] frame];
	MapScreenNSRectToMCRectangle(t_viewport, r_viewport);
}

void MCMacPlatformCore::GetScreenWorkarea(uindex_t p_index, MCRectangle& r_workarea)
{
	MapScreenNSRectToMCRectangle([[[NSScreen screens] objectAtIndex: p_index] visibleFrame], r_workarea);
}

void MCMacPlatformCore::GetScreenPixelScale(uindex_t p_index, MCGFloat& r_scale)
{
	NSScreen *t_screen;
	t_screen = [[NSScreen screens] objectAtIndex: p_index];
	if ([t_screen respondsToSelector: @selector(backingScaleFactor)])
		r_scale = objc_msgSend_fpret_type<CGFloat>(t_screen, @selector(backingScaleFactor));
	else
		r_scale = 1.0f;
}

////////////////////////////////////////////////////////////////////////////////

void MCMacPlatformCore::SyncBackdrop(void)
{
    if (m_backdrop_window == nil)
        return;
    
    NSWindow *t_backdrop;
    t_backdrop = ((MCMacPlatformWindow *)m_backdrop_window) -> GetHandle();
    
    NSDisableScreenUpdates();
    [t_backdrop orderOut: nil];
    
    // Loop from front to back on our windows, making sure the backdrop window is
    // at the back.
    NSInteger t_window_above_id;
    t_window_above_id = -1;
    for(NSNumber *t_window_id in [NSWindow windowNumbersWithOptions: 0])
    {
        NSWindow *t_window;
        t_window = [NSApp windowWithWindowNumber: [t_window_id longValue]];
        
        if (t_window == t_backdrop)
            continue;
        
        if (t_window_above_id != -1)
            [t_window orderWindow: NSWindowBelow relativeTo: t_window_above_id];
        
        t_window_above_id = [t_window_id longValue];
    }
    
    [t_backdrop orderWindow: NSWindowBelow relativeTo: t_window_above_id];
    
    NSEnableScreenUpdates();
}

void MCMacPlatformCore::ConfigureBackdrop(MCPlatformWindowRef p_backdrop_window)
{
	if (m_backdrop_window != nil)
	{
		m_backdrop_window -> Release();
		m_backdrop_window = nil;
	}
	
	m_backdrop_window = p_backdrop_window;
	
	if (m_backdrop_window != nil)
		m_backdrop_window -> Retain();
	
	SyncBackdrop();
}


////////////////////////////////////////////////////////////////////////////////

// These tables are taken from the Carbon implementation - as keysDown takes into
// account shift states. I'm not sure this is entirely correct, but we must keep
// backwards compat.

static uint4 keysyms[] = {
	0x61, 0x73, 0x64, 0x66, 0x68, 0x67, 0x7A, 0x78, 0x63, 0x76, 0, 0x62,
	0x71, 0x77, 0x65, 0x72, 0x79, 0x74, 0x31, 0x32, 0x33, 0x34, 0x36,
	0x35, 0x3D, 0x39, 0x37, 0x2D, 0x38, 0x30, 0x5D, 0x6F, 0x75, 0x5B,
	0x69, 0x70, 0xFF0D, 0x6C, 0x6A, 0x27, 0x6B, 0x3B, 0x5C, 0x2C, 0x2F,
	0x6E, 0x6D, 0x2E, 0xFF09, 0x20, 0x60, 0xFF08, 0xFF8D, 0xFF1B, 0, 0,
	0xFFE1, 0xFFE5, 0, 0xFFE3, 0, 0, 0, 0, 0, 0xFF9F, 0, 0xFFAA, 0,
	0xFFAB, 0, 0xFF7F, 0, 0, 0, 0xFFAF, 0xFF8D, 0, 0xFFAD, 0, 0, 0xFFBD,
	0xFF9E, 0xFF9C, 0xFF99, 0xFF9B, 0xFF96, 0xFF9D, 0xFF98, 0xFF95, 0,
	0xFF97, 0xFF9A, 0, 0, 0, 0xFFC2, 0xFFC3, 0xFFC4, 0xFFC0, 0xFFC5,
	0xFFC6, 0, 0xFFC8, 0, 0xFFCA, 0xFFCD, 0xFF14, 0, 0xFFC7, 0, 0xFFC9, 0,
	0xFF13, 0xFF6A, 0xFF50, 0xFF55, 0xFFFF, 0xFFC1, 0xFF57, 0xFFBF,
	0xFF56, 0xFFBE, 0xFF51, 0xFF53, 0xFF54, 0xFF52, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
};

static uint4 shift_keysyms[] = {
	0x41, 0x53, 0x44, 0x46, 0x48, 0x47, 0x5A, 0x58, 0x43, 0x56, 0, 0x42,
	0x51, 0x57, 0x45, 0x52, 0x59, 0x54, 0x21, 0x40, 0x23, 0x24, 0x5E,
	0x25, 0x2B, 0x28, 0x26, 0x5F, 0x2A, 0x29, 0x7D, 0x4F, 0x55, 0x7B,
	0x49, 0x50, 0xFF0D, 0x4C, 0x4A, 0x22, 0x4B, 0x3A, 0x7C, 0x3C, 0x3F,
	0x4E, 0x4D, 0x3E, 0xFF09, 0x20, 0x7E, 0xFF08, 0xFF8D, 0xFF1B, 0, 0,
	0xFFE1, 0xFFE5, 0, 0xFFE3, 0, 0, 0, 0, 0, 0xFFAE, 0, 0xFFAA, 0,
	0xFFAB, 0, 0xFF7F, 0, 0, 0, 0xFFAF, 0xFF8D, 0, 0xFFAD, 0, 0, 0xFFBD,
	0xFFB0, 0xFFB1, 0xFFB2, 0xFFB3, 0xFFB4, 0xFFB5, 0xFFB6, 0xFFB7, 0,
	0xFFB8, 0xFFB9, 0, 0, 0, 0xFFC2, 0xFFC3, 0xFFC4, 0xFFC0, 0xFFC5,
	0xFFC6, 0, 0xFFC8, 0, 0xFF62, 0, 0xFF20, 0, 0xFFC7, 0, 0xFFC9, 0,
	0xFF6B, 0xFF6A, 0xFF50, 0xFF55, 0xFFFF, 0xFFC1, 0xFF57, 0xFFBF,
	0xFF56, 0xFFBE, 0xFF51, 0xFF53, 0xFF54, 0xFF52, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
};

static MCPlatformKeyCode s_mac_keycode_map[] =
{
	/* 0x00 */ kMCPlatformKeyCodeA,
	/* 0x01 */ kMCPlatformKeyCodeS,
	/* 0x02 */ kMCPlatformKeyCodeD,
	/* 0x03 */ kMCPlatformKeyCodeF,
	/* 0x04 */ kMCPlatformKeyCodeH,
	/* 0x05 */ kMCPlatformKeyCodeG,
	/* 0x06 */ kMCPlatformKeyCodeZ,
	/* 0x07 */ kMCPlatformKeyCodeX,
	/* 0x08 */ kMCPlatformKeyCodeC,
	/* 0x09 */ kMCPlatformKeyCodeV,
	/* 0x0A */ kMCPlatformKeyCodeISOSection,
	/* 0x0B */ kMCPlatformKeyCodeB,
	/* 0x0C */ kMCPlatformKeyCodeQ,
	/* 0x0D */ kMCPlatformKeyCodeW,
	/* 0x0E */ kMCPlatformKeyCodeE,
	/* 0x0F */ kMCPlatformKeyCodeR,
	/* 0x10 */ kMCPlatformKeyCodeY,
	/* 0x11 */ kMCPlatformKeyCodeT,
	/* 0x12 */ kMCPlatformKeyCode1,
	/* 0x13 */ kMCPlatformKeyCode2,
	/* 0x14 */ kMCPlatformKeyCode3,
	/* 0x15 */ kMCPlatformKeyCode4,
	/* 0x16 */ kMCPlatformKeyCode6,
	/* 0x17 */ kMCPlatformKeyCode5,
	/* 0x18 */ kMCPlatformKeyCodeEqual,
	/* 0x19 */ kMCPlatformKeyCode9,
	/* 0x1A */ kMCPlatformKeyCode7,
	/* 0x1B */ kMCPlatformKeyCodeMinus,
	/* 0x1C */ kMCPlatformKeyCode8,
	/* 0x1D */ kMCPlatformKeyCode0,
	/* 0x1E */ kMCPlatformKeyCodeRightBracket,
	/* 0x1F */ kMCPlatformKeyCodeO,
	/* 0x20 */ kMCPlatformKeyCodeU,
	/* 0x21 */ kMCPlatformKeyCodeLeftBracket,
	/* 0x22 */ kMCPlatformKeyCodeI,
	/* 0x23 */ kMCPlatformKeyCodeP,
	/* 0x24 */ kMCPlatformKeyCodeReturn,
	/* 0x25 */ kMCPlatformKeyCodeL,
	/* 0x26 */ kMCPlatformKeyCodeJ,
	/* 0x27 */ kMCPlatformKeyCodeQuote,
	/* 0x28 */ kMCPlatformKeyCodeK,
	/* 0x29 */ kMCPlatformKeyCodeSemicolon,
	/* 0x2A */ kMCPlatformKeyCodeBackslash,
	/* 0x2B */ kMCPlatformKeyCodeComma,
	/* 0x2C */ kMCPlatformKeyCodeSlash,
	/* 0x2D */ kMCPlatformKeyCodeN,
	/* 0x2E */ kMCPlatformKeyCodeM,
	/* 0x2F */ kMCPlatformKeyCodePeriod,
	/* 0x30 */ kMCPlatformKeyCodeTab,
	/* 0x31 */ kMCPlatformKeyCodeSpace,
	/* 0x32 */ kMCPlatformKeyCodeGrave,
	/* 0x33 */ kMCPlatformKeyCodeBackspace,
	/* 0x34 */ kMCPlatformKeyCodeUndefined,
	/* 0x35 */ kMCPlatformKeyCodeEscape,
	/* 0x36 */ kMCPlatformKeyCodeRightCommand,
	/* 0x37 */ kMCPlatformKeyCodeLeftCommand,
	/* 0x38 */ kMCPlatformKeyCodeLeftShift,
	/* 0x39 */ kMCPlatformKeyCodeCapsLock,
	/* 0x3A */ kMCPlatformKeyCodeLeftOption,
	/* 0x3B */ kMCPlatformKeyCodeLeftControl,
	/* 0x3C */ kMCPlatformKeyCodeRightShift,
	/* 0x3D */ kMCPlatformKeyCodeRightOption,
	/* 0x3E */ kMCPlatformKeyCodeRightControl,
	/* 0x3F */ kMCPlatformKeyCodeFunction,
	/* 0x40 */ kMCPlatformKeyCodeF17,
	/* 0x41 */ kMCPlatformKeyCodeKeypadDecimal,
	/* 0x42 */ kMCPlatformKeyCodeUndefined,
	/* 0x43 */ kMCPlatformKeyCodeKeypadMultiply,
	/* 0x44 */ kMCPlatformKeyCodeUndefined,
	/* 0x45 */ kMCPlatformKeyCodeKeypadAdd,
	/* 0x46 */ kMCPlatformKeyCodeUndefined,
	/* 0x47 */ kMCPlatformKeyCodeNumLock, // COCO-TODO: This should be keypad-clear - double-check!
	/* 0x48 */ kMCPlatformKeyCodeVolumeUp,
	/* 0x49 */ kMCPlatformKeyCodeVolumeDown,
	/* 0x4A */ kMCPlatformKeyCodeMute,
	/* 0x4B */ kMCPlatformKeyCodeKeypadDivide,
	/* 0x4C */ kMCPlatformKeyCodeKeypadEnter,
	/* 0x4D */ kMCPlatformKeyCodeUndefined,
	/* 0x4E */ kMCPlatformKeyCodeKeypadSubtract,
	/* 0x4F */ kMCPlatformKeyCodeF18,
	/* 0x50 */ kMCPlatformKeyCodeF19,
	/* 0x51 */ kMCPlatformKeyCodeKeypadEqual,
	/* 0x52 */ kMCPlatformKeyCodeKeypad0,
	/* 0x53 */ kMCPlatformKeyCodeKeypad1,
	/* 0x54 */ kMCPlatformKeyCodeKeypad2,
	/* 0x55 */ kMCPlatformKeyCodeKeypad3,
	/* 0x56 */ kMCPlatformKeyCodeKeypad4,
	/* 0x57 */ kMCPlatformKeyCodeKeypad5,
	/* 0x58 */ kMCPlatformKeyCodeKeypad6,
	/* 0x59 */ kMCPlatformKeyCodeKeypad7,
	/* 0x5A */ kMCPlatformKeyCodeF20,
	/* 0x5B */ kMCPlatformKeyCodeKeypad8,
	/* 0x5C */ kMCPlatformKeyCodeKeypad9,
	/* 0x5D */ kMCPlatformKeyCodeJISYen,
	/* 0x5E */ kMCPlatformKeyCodeJISUnderscore,
	/* 0x5F */ kMCPlatformKeyCodeJISKeypadComma,
	/* 0x60 */ kMCPlatformKeyCodeF5,
	/* 0x61 */ kMCPlatformKeyCodeF6,
	/* 0x62 */ kMCPlatformKeyCodeF7,
	/* 0x63 */ kMCPlatformKeyCodeF3,
	/* 0x64 */ kMCPlatformKeyCodeF8,
	/* 0x65 */ kMCPlatformKeyCodeF9,
	/* 0x66 */ kMCPlatformKeyCodeJISEisu,
	/* 0x67 */ kMCPlatformKeyCodeF11,
	/* 0x68 */ kMCPlatformKeyCodeJISKana,
	/* 0x69 */ kMCPlatformKeyCodeF13,
	/* 0x6A */ kMCPlatformKeyCodeF16,
	/* 0x6B */ kMCPlatformKeyCodeF14,
	/* 0x6C */ kMCPlatformKeyCodeUndefined,
	/* 0x6D */ kMCPlatformKeyCodeF10,
	/* 0x6E */ kMCPlatformKeyCodeUndefined,
	/* 0x6F */ kMCPlatformKeyCodeF12,
	/* 0x70 */ kMCPlatformKeyCodeUndefined,
	/* 0x71 */ kMCPlatformKeyCodeF15,
	/* 0x72 */ kMCPlatformKeyCodeHelp,
	/* 0x73 */ kMCPlatformKeyCodeBegin,
	/* 0x74 */ kMCPlatformKeyCodePrevious,
	/* 0x75 */ kMCPlatformKeyCodeDelete,
	/* 0x76 */ kMCPlatformKeyCodeF4,
	/* 0x77 */ kMCPlatformKeyCodeEnd,
	/* 0x78 */ kMCPlatformKeyCodeF2,
	/* 0x79 */ kMCPlatformKeyCodeNext,
	/* 0x7A */ kMCPlatformKeyCodeF1,
	/* 0x7B */ kMCPlatformKeyCodeLeft,
	/* 0x7C */ kMCPlatformKeyCodeRight,
	/* 0x7D */ kMCPlatformKeyCodeDown,
	/* 0x7E */ kMCPlatformKeyCodeUp,
	/* 0x7F */ kMCPlatformKeyCodeUndefined,
};

bool MCMacPlatformMapKeyCode(uint32_t p_mac_keycode, uint32_t p_modifier_flags, MCPlatformKeyCode& r_keycode)
{
	if (p_mac_keycode > 0x7f)
		return false;
    
	if (s_mac_keycode_map[p_mac_keycode] == kMCPlatformKeyCodeUndefined)
		return false;
    
    // PLATFORM-TODO: Shifted keysym handling should be in the engine rather than
    //   here.
    bool t_is_shift;
    t_is_shift = (p_modifier_flags & (NSShiftKeyMask | NSAlphaShiftKeyMask)) != 0;
    if (t_is_shift)
        r_keycode = shift_keysyms[p_mac_keycode];
    else
        r_keycode = keysyms[p_mac_keycode];
    
	// r_keycode = s_mac_keycode_map[p_mac_keycode];
    
	return true;
}

////////////////////////////////////////////////////////////////////////////////

// Our mouse handling code relies on getting a stream of mouse move messages
// with screen co-ordinates, and mouse press messages indicating button state
// changes. As we need to handle things like mouse grabbing, and windows popping
// up and moving under the mouse we don't rely on enter/leave from the OS,
// instead we do it ourselves to ensure we never get into unpleasant situations.

// For this to work, we just need the OS to provide us with:
//   - mouse press messages within our own windows
//   - mouse move messages when the mouse moves over our windows *and* when
//     the mouse is down and the mouse is outside our windows.

// COCOA-TODO: Clean up this external dependency.
extern uint2 MCdoubledelta;
extern uint2 MCdoubletime;
extern uint2 MCdragdelta;

void MCMacPlatformCore::LockCursor(void)
{
    m_mouse_cursor_locked = true;
}

void MCMacPlatformCore::UnlockCursor(void)
{
    m_mouse_cursor_locked = false;
    
    if (m_mouse_window == nil)
        ResetCursor();
    else
        HandleMouseCursorChange(m_mouse_window);
}

void MCMacPlatformCore::GrabPointer(MCPlatformWindowRef p_window)
{
	// If we are grabbing for the given window already, do nothing.
	if (m_mouse_grabbed && p_window == m_mouse_window)
	{
		m_mouse_grabbed_explicit = true;
		return;
	}
	
	// If the mouse window is already w, then just grab.
	if (p_window == m_mouse_window)
	{
		m_mouse_grabbed = true;
		m_mouse_grabbed_explicit = true;
		return;
	}
	
	// Otherwise do nothing - the mouse window must be w for us to grab.
	// (If we don't have this rule, then strange things could happen with
	//  mouse presses in different windows!).
}

void MCMacPlatformCore::UngrabPointer(void)
{
	// If buttons are down, then ungrab will happen when they are released.
	if (m_mouse_buttons != 0)
		return;
	
	// Otherwise just turn off the grabbed flag.
	m_mouse_grabbed = false;
	m_mouse_grabbed_explicit = false;
}

void MCMacPlatformCore::HandleMousePress(uint32_t p_button, bool p_new_state)
{
	bool t_state;
	t_state = (m_mouse_buttons & (1 << p_button)) != 0;
	
	// If the state is not different from the new state, do nothing.
	if (p_new_state == t_state)
		return;
	
	// If we are mouse downing with no window, then do nothing.
	if (p_new_state && m_mouse_window == nil)
		return;
	
	// Update the state.
	if (p_new_state)
		m_mouse_buttons |= (1 << p_button);
	else
		m_mouse_buttons &= ~(1 << p_button);
	
	// Record whether it was an explicit grab.
	bool t_grabbed_explicit;
	t_grabbed_explicit = m_mouse_grabbed_explicit;
	
	// If we are grabbed, and mouse buttons are zero, then ungrab.
	// If mouse buttons are zero, then reset the drag button.
	if (m_mouse_buttons == 0)
	{
		m_mouse_grabbed = false;
		m_mouse_grabbed_explicit = false;
		m_mouse_drag_button = 0xffffffff;
	}
		
	// If mouse buttons are non-zero, then grab.
	if (m_mouse_buttons != 0)
		m_mouse_grabbed = true;
	
	// If the control key is down (which we will see as the command key) and if
	// the button is 0, then we actually want to dispatch a button 2.
	if (p_button == 0 &&
		(m_mouse_modifiers & kMCPlatformModifierCommand) != 0 &&
		p_new_state)
	{
		p_button = 2;
		m_mouse_was_control_click = true;
	}
	
	if (!p_new_state &&
		m_mouse_was_control_click && p_button == 0)
		p_button = 2;
		
	// Determine the press state - this can be down, up or release. If
	// the new state is 'up', then we must dispatch a release message
	// if the mouse location is not within the window.
	if (p_new_state)
	{
		// Get the time of the mouse press event.
		uint32_t t_event_time;
		t_event_time = GetEventTime();
		
		// If the click occured within the double click time and double click
		// radius *and* if the button is the same as the last clicked button
		// then increment the click count.
		if (t_event_time - m_mouse_last_click_time < MCdoubletime &&
			MCU_abs(m_mouse_last_click_screen_position . x - m_mouse_screen_position . x) < MCdoubledelta &&
			MCU_abs(m_mouse_last_click_screen_position . y - m_mouse_screen_position . y) < MCdoubledelta &&
			m_mouse_last_click_button == p_button)
			m_mouse_click_count += 1;
		else
			m_mouse_click_count = 0;
		
		// Update the last click position / button.
		m_mouse_last_click_button = p_button;
		m_mouse_last_click_screen_position = m_mouse_screen_position;
		
		m_callback -> SendMouseDown(m_mouse_window, p_button, m_mouse_click_count);
	}
	else
	{
		MCPoint t_global_pos;
		m_mouse_window -> MapPointFromWindowToScreen(m_mouse_position, t_global_pos);
		
		Window t_new_mouse_window;
		GetWindowAtPoint(t_global_pos, t_new_mouse_window);
		
		m_mouse_was_control_click = false;
		
		// If the mouse was grabbed explicitly, we send mouseUp not mouseRelease.
		if (t_new_mouse_window == m_mouse_window || t_grabbed_explicit)
		{
			// If this is the same button as the last mouseDown, then
			// update the click time.
			if (p_button == m_mouse_last_click_button)
				m_mouse_last_click_time = GetEventTime();
			
			m_callback -> SendMouseUp(m_mouse_window, p_button, m_mouse_click_count);
		}
		else
		{
			// Any release causes us to cancel multi-click tracking.
			m_mouse_click_count = 0;
			m_mouse_last_click_time = 0;
			
            // MW-2014-06-11: [[ Bug 12339 ]] Only send a mouseRelease message if this wasn't the result of a popup menu.
			m_callback -> SendMouseRelease(m_mouse_window, p_button, false);
		}
	}
}

void MCMacPlatformCore::HandleMouseCursorChange(MCPlatformWindowRef p_window)
{
    // If the mouse is not currently over the window whose cursor has
    // changed - do nothing.
    if (m_mouse_window != p_window)
        return;
    
    // MW-2014-06-11: [[ Bug 12436 ]] If the cursor is locked, do nothing.
    if (m_mouse_cursor_locked)
        return;
    
    MCMacPlatformWindow *t_window;
    t_window = (MCMacPlatformWindow *)p_window;
    
    // MW-2014-06-11: [[ Bug 12437 ]] Make sure we only check tracking rectangles if we have
    //   a resizable frame.
    bool t_is_resizable;
    p_window -> GetProperty(kMCPlatformWindowPropertyHasSizeWidget, kMCPlatformPropertyTypeBool, &t_is_resizable);
    
    if (t_is_resizable)
    {
        NSArray *t_tracking_areas;
        t_tracking_areas = [[t_window -> GetContainerView() superview] trackingAreas];
        
        NSPoint t_mouse_loc;
        t_mouse_loc = [t_window -> GetView() mapMCPointToNSPoint: m_mouse_position];
        for(uindex_t i = 0; i < [t_tracking_areas count]; i++)
        {
            if (NSPointInRect(t_mouse_loc, [(NSTrackingArea *)[t_tracking_areas objectAtIndex: i] rect]))
                return;
        }
    }
   
    // MW-2014-06-25: [[ Bug 12634 ]] Make sure we only change the cursor if we are not
    //   within a native view.
    if ([t_window -> GetContainerView() hitTest: [t_window -> GetView() mapMCPointToNSPoint: m_mouse_position]] == t_window -> GetView())
    {
        // Show the cursor attached to the window.
        MCPlatformCursorRef t_cursor;
        p_window -> GetProperty(kMCPlatformWindowPropertyCursor, kMCPlatformPropertyTypeCursorRef, &t_cursor);
        
        // PM-2014-04-02: [[ Bug 12082 ]] IDE no longer crashes when changing an applied pattern
        if (t_cursor != nil)
            t_cursor -> Set();
        // SN-2014-10-01: [[ Bug 13516 ]] Hiding a cursor here is not what we want to happen if a cursor hasn't been found
        else
            ResetCursor();
    }
}

void MCMacPlatformCore::HandleMouseAfterWindowHidden(void)
{
	HandleMouseMove(m_mouse_screen_position);
}

// MW-2014-06-27: [[ Bug 13284 ]] When live resizing starts, leave the window, and enter it again when it finishes.
void MCMacPlatformCore::HandleMouseForResizeStart(void)
{
    if (m_mouse_window != nil)
        m_callback -> SendMouseLeave(m_mouse_window);
}

void MCMacPlatformCore::HandleMouseForResizeEnd(void)
{
    if (m_mouse_window != nil)
        m_callback -> SendMouseEnter(m_mouse_window);
}

void MCMacPlatformCore::HandleMouseMove(MCPoint p_screen_loc)
{
	// First compute the window that should be active now.
	MCPlatformWindowRef t_new_mouse_window;
	if (m_mouse_grabbed)
	{
		// If the mouse is grabbed, the mouse window does not change.
		t_new_mouse_window = m_mouse_window;
	}
	else
	{
		// If the mouse is not grabbed, then we must determine which of our
		// window views we are now over.
		GetWindowAtPoint(p_screen_loc, t_new_mouse_window);
	}
	
	// If the mouse window has changed, then we must exit/enter.
	bool t_window_changed;
	t_window_changed = false;
	if (t_new_mouse_window != m_mouse_window)
	{
		if (m_mouse_window != nil)
			m_callback -> SendMouseLeave(m_mouse_window);
		
		if (t_new_mouse_window != nil)
			m_callback -> SendMouseEnter(t_new_mouse_window);
		
		// If there is no mouse window, reset the cursor to default.
		if (t_new_mouse_window == nil)
        {
            // MW-2014-06-11: [[ Bug 12436 ]] If the cursor is locked, do nothing.
            if (!m_mouse_cursor_locked)
                ResetCursor();
        }
			
		if (m_mouse_window != nil)
			m_mouse_window -> Release();
		
		m_mouse_window = t_new_mouse_window;
		
		if (m_mouse_window != nil)
			m_mouse_window -> Retain();
			
		t_window_changed = true;
	}
	
	// Regardless of whether we post a mouse move, update the screen mouse position.
	m_mouse_screen_position = p_screen_loc;
	
	// If we have a new mouse window, then translate screen loc and update.
	if (m_mouse_window != nil)
	{
		MCPoint t_window_loc;
		m_mouse_window -> MapPointFromScreenToWindow(p_screen_loc, t_window_loc);
		
		if (t_window_changed ||
			t_window_loc . x != m_mouse_position . x ||
			t_window_loc . y != m_mouse_position . y)
		{
			m_mouse_position = t_window_loc;
			
			// Send the mouse move.
			m_callback -> SendMouseMove(m_mouse_window, t_window_loc);
			
			// If this is the start of a drag, then send a mouse drag.
			if (m_mouse_buttons != 0 && m_mouse_drag_button == 0xffffffff &&
				(MCU_abs(p_screen_loc . x - m_mouse_last_click_screen_position . x) >= MCdragdelta ||
				 MCU_abs(p_screen_loc . y - m_mouse_last_click_screen_position . y) >= MCdragdelta))
			{
				m_mouse_drag_button = m_mouse_last_click_button;
				m_callback -> SendMouseDrag(m_mouse_window, m_mouse_drag_button);
			}
		}
        
        // MW-2014-04-22: [[ Bug 12253 ]] Ending a drag-drop can cause the mouse window to go.
        // Update the mouse cursor for the mouse window.
        if (m_mouse_window != nil)
            HandleMouseCursorChange(m_mouse_window);
	}
}

void MCMacPlatformCore::HandleMouseScroll(CGFloat dx, CGFloat dy)
{
	if (m_mouse_window == nil)
		return;
	
	if (dx != 0.0 || dy != 0.0)
		m_callback -> SendMouseScroll(m_mouse_window, dx < 0.0 ? -1 : (dx > 0.0 ? 1 : 0), dy < 0.0 ? -1 : (dy > 0.0 ? 1 : 0));
}

void MCMacPlatformCore::HandleMouseSync(void)
{
	if (m_mouse_window != nil)
	{
		for(uindex_t i = 0; i < 3; i++)
			if ((m_mouse_buttons & (1 << i)) != 0)
			{
				m_mouse_buttons &= ~(1 << i);
				
                // MW-2014-06-11: [[ Bug 12339 ]] Don't send a mouseRelease message in this case.
				if (m_mouse_was_control_click &&
					i == 0)
					m_callback -> SendMouseRelease(m_mouse_window, 2, true);
				else
					m_callback -> SendMouseRelease(m_mouse_window, i, true);
			}
	}
	
	m_mouse_grabbed = false;
	m_mouse_drag_button = 0xffffffff;
	m_mouse_click_count = 0;
	m_mouse_last_click_time = 0;
	m_mouse_was_control_click = false;

	MCPoint t_location;
	MapScreenNSPointToMCPoint([NSEvent mouseLocation], t_location);
	
	HandleMouseMove(t_location);
}

void MCMacPlatformCore::SyncMouseBeforeDragging(void)
{
	// Release the mouse.
	uindex_t t_button_to_release;
	if (m_mouse_buttons != 0)
	{
		t_button_to_release = m_mouse_drag_button;
		if (t_button_to_release == 0xffffffffU)
			t_button_to_release = m_mouse_last_click_button;
		
		m_mouse_buttons = 0;
		m_mouse_grabbed = false;
		m_mouse_click_count = 0;
		m_mouse_last_click_time = 0;
		m_mouse_drag_button = 0xffffffff;
		m_mouse_was_control_click = false;
	}
	else
		t_button_to_release = 0xffffffff;
	
	if (m_mouse_window != nil)
	{
        // MW-2014-06-11: [[ Bug 12339 ]] Ensure mouseRelease is sent if drag is starting.
		if (t_button_to_release != 0xffffffff)
			m_callback -> SendMouseRelease(m_mouse_window, t_button_to_release, false);
		m_callback -> SendMouseLeave(m_mouse_window);
		
        // SN-2015-01-13: [[ Bug 14350 ]] The user can close the stack in
        //  a mouseLeave handler
        if (m_mouse_window != nil)
        {
            m_mouse_window -> Release();
            m_mouse_window = nil;
        }
	}
}

void MCMacPlatformCore::SyncMouseAfterTracking(void)
{
	NSEvent *t_event;
	t_event = [NSEvent otherEventWithType:NSApplicationDefined
								 location:NSMakePoint(0, 0)
							modifierFlags:0
								timestamp:0
							 windowNumber:0
								  context:NULL
								  subtype:kMCMacPlatformMouseSyncEvent
									data1:0
									data2:0];
	[NSApp postEvent: t_event atStart: YES];
}

////////////////////////////////////////////////////////////////////////////////

void MCMacPlatformCore::HandleModifiersChanged(MCPlatformModifiers p_modifiers)
{
	if (m_mouse_modifiers != p_modifiers)
	{
		m_mouse_modifiers = p_modifiers;
		m_callback -> SendModifiersChanged(p_modifiers);
	}
}
	
////////////////////////////////////////////////////////////////////////////////

MCPlatformModifiers MCMacPlatformMapNSModifiersToModifiers(NSUInteger p_modifiers)
{
	MCPlatformModifiers t_modifiers;
	t_modifiers = 0;
	
	if ((p_modifiers & NSShiftKeyMask) != 0)
		t_modifiers |= kMCPlatformModifierShift;
	if ((p_modifiers & NSAlternateKeyMask) != 0)
		t_modifiers |= kMCPlatformModifierOption;
	
	// COCOA-TODO: Abstract Command/Control switching.
	if ((p_modifiers & NSControlKeyMask) != 0)
		t_modifiers |= kMCPlatformModifierCommand;
	if ((p_modifiers & NSCommandKeyMask) != 0)
		t_modifiers |= kMCPlatformModifierControl;
	
	if ((p_modifiers & NSAlphaShiftKeyMask) != 0)
		t_modifiers |= kMCPlatformModifierCapsLock;

	return t_modifiers;
}

////////////////////////////////////////////////////////////////////////////////

CGFloat MCMacPlatformCore::GetDesktopHeight()
{
	if (!m_have_desktop_height)
	{
		m_desktop_height = 0.0f;
		
		for (NSScreen * t_screen in [NSScreen screens])
		{
			NSRect t_rect = [t_screen frame];
			if (t_rect.origin.y + t_rect.size.height > m_desktop_height)
				m_desktop_height = t_rect.origin.y + t_rect.size.height;
		}
		
		m_have_desktop_height = true;
	}
	
	return m_desktop_height;
}

void MCMacPlatformCore::SetHasDesktopHeight(bool p_have_desktop_height)
{
    m_have_desktop_height = p_have_desktop_height;
}

void MCMacPlatformCore::MapScreenMCPointToNSPoint(MCPoint p, NSPoint& r_point)
{
	r_point = NSMakePoint(p . x, GetDesktopHeight() - p . y);
}

void MCMacPlatformCore::MapScreenNSPointToMCPoint(NSPoint p, MCPoint& r_point)
{
	r_point . x = int16_t(p . x);
	r_point . y = int16_t(GetDesktopHeight() - p . y);
}

void MCMacPlatformCore::MapScreenMCRectangleToNSRect(MCRectangle r, NSRect& r_rect)
{
	r_rect = NSMakeRect(CGFloat(r . x), GetDesktopHeight() - CGFloat(r . y + r . height), CGFloat(r . width), CGFloat(r . height));
}

void MCMacPlatformCore::MapScreenNSRectToMCRectangle(NSRect r, MCRectangle& r_rect)
{
	r_rect = MCRectangleMake(int16_t(r . origin . x), int16_t(GetDesktopHeight() - (r . origin . y + r . size . height)), int16_t(r . size . width), int16_t(r . size . height));
}

////////////////////////////////////////////////////////////////////////////////

void MCMacPlatformCore::ShowMessageDialog(MCStringRef p_title,
                                    MCStringRef p_message)
{
    NSAlert *t_alert = [[NSAlert alloc] init];
    [t_alert addButtonWithTitle:@"OK"];
    [t_alert setMessageText: MCStringConvertToAutoreleasedNSString(p_title)];
    [t_alert setInformativeText: MCStringConvertToAutoreleasedNSString(p_message)];
    [t_alert setAlertStyle:NSInformationalAlertStyle];
    [t_alert runModal];
}

////////////////////////////////////////////////////////////////////////////////

static void display_reconfiguration_callback(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *userInfo)
{
	// COCOA-TODO: Make this is a little more discerning (only need to reset if
	//   primary geometry changes).
    MCMacPlatformCore * t_platform = (MCMacPlatformCore *) userInfo;
    t_platform -> SetHasDesktopHeight(false);
}

////////////////////////////////////////////////////////////////////////////////

extern "C" bool MCModulesInitialize(void);
extern "C" void MCModulesFinalize(void);

MCMacPlatformCore::MCMacPlatformCore(void)
{
    m_animation_start_time = CFAbsoluteTimeGetCurrent();
}

MCMacPlatformCore::~MCMacPlatformCore()
{
    if (m_abort_key_thread != nil)
        [m_abort_key_thread release];
}


int MCMacPlatformCore::Run(int argc, char *argv[], char *envp[])
{
    NSAutoreleasePool *t_pool;
    t_pool = [[NSAutoreleasePool alloc] init];
    
    m_callback_lock = [[NSLock alloc] init];
    
    // Create the normal NSApplication object.
    NSApplication *t_application;
    t_application = [com_runrev_livecode_MCApplication sharedApplication];
    
    // Register for reconfigurations.
    CGDisplayRegisterReconfigurationCallback(display_reconfiguration_callback, this);
    
    // On OSX, argv and envp are encoded as UTF8
    MCStringRef *t_new_argv;
    /* UNCHECKED */ MCMemoryNewArray(argc, t_new_argv);
    
    for (int i = 0; i < argc; i++)
    {
        /* UNCHECKED */ MCStringCreateWithBytes((const byte_t *)argv[i], strlen(argv[i]), kMCStringEncodingUTF8, false, t_new_argv[i]);
    }
    
    MCStringRef *t_new_envp;
    /* UNCHECKED */ MCMemoryNewArray(1, t_new_envp);
    
    int i = 0;
    uindex_t t_envp_count = 0;
    
    while (envp[i] != NULL)
    {
        t_envp_count++;
        uindex_t t_count = i;
        /* UNCHECKED */ MCMemoryResizeArray(i + 1, t_new_envp, t_count);
        /* UNCHECKED */ MCStringCreateWithBytes((const byte_t *)envp[i], strlen(envp[i]), kMCStringEncodingUTF8, false, t_new_envp[i]);
        i++;
    }
    
    /* UNCHECKED */ MCMemoryResizeArray(i + 1, t_new_envp, t_envp_count);
    t_new_envp[i] = nil;
    
    // Setup our delegate
    com_runrev_livecode_MCApplicationDelegate *t_delegate;
    t_delegate = [[com_runrev_livecode_MCApplicationDelegate alloc] initWithArgc: argc argv: t_new_argv envp: t_new_envp];
    
    [t_delegate setPlatform:this];
    
    // Assign our delegate
    [t_application setDelegate: t_delegate];
    
    // Run the application - this never returns!
    [t_application run];
    
    for (i = 0; i < argc; i++)
        MCValueRelease(t_new_argv[i]);
    for (i = 0; i < t_envp_count; i++)
        MCValueRelease(t_new_envp[i]);
    
    MCMemoryDeleteArray(t_new_argv);
    MCMemoryDeleteArray(t_new_envp);
    
    // Drain the autorelease pool.
    [t_pool release];
    
    return 0;
}


void MCMacPlatformCore::DisableScreenUpdates(void)
{
    NSDisableScreenUpdates();
}

void MCMacPlatformCore::EnableScreenUpdates(void)
{
    NSEnableScreenUpdates();
}

bool MCMacPlatformCore::QueryInterface(const char * p_interface_id, MCPlatform::Base *&r_interface)
{
    return false;
}

void MCMacPlatformCore::RunBlockOnMainFiber(void (^block)(void))
{
    block();
}

