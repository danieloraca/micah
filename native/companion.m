#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>

extern char *companion_reply(const char *input);
extern void companion_reply_free(char *value);
extern const char *companion_match(const char *input);

@interface Companion : NSObject <NSApplicationDelegate, NSWindowDelegate, AVSpeechSynthesizerDelegate>
@property NSPanel *panel;
@property NSStatusItem *statusItem;
@property NSTextField *input;
@property NSTextView *output;
@property NSTextField *status;
@property NSButton *sendButton;
@property NSButton *talkButton;
@property NSButton *speakButton;
@property AVSpeechSynthesizer *speaker;
@property SFSpeechRecognizer *recognizer;
@property SFSpeechAudioBufferRecognitionRequest *request;
@property SFSpeechRecognitionTask *task;
@property AVAudioEngine *engine;
@property NSTimer *timer;
@property BOOL capturing;
@property BOOL authorizing;
@property BOOL busy;
@property BOOL tapInstalled;
@property NSUInteger voiceGeneration;
@property NSString *lastReply;
@property NSString *liveTranscript;
@end

@implementation Companion
- (NSTextField *)label:(NSString *)text frame:(NSRect)frame size:(CGFloat)size {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.frame = frame;
    label.font = [NSFont systemFontOfSize:size];
    [self.panel.contentView addSubview:label];
    return label;
}
- (NSButton *)button:(NSString *)title action:(SEL)action frame:(NSRect)frame {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.frame = frame;
    [self.panel.contentView addSubview:button];
    return button;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 460, 550)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    self.panel.title = @"Mica — Local";
    self.panel.delegate = self;
    self.panel.floatingPanel = YES;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.hidesOnDeactivate = NO;
    self.panel.releasedWhenClosed = NO;
    [self.panel center];
    [self label:@"◇  Mica" frame:NSMakeRect(18, 505, 424, 28) size:20];
    [self label:@"Offline commands • Placeholder appearance • No AI model" frame:NSMakeRect(18, 475, 424, 24) size:12];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(18, 224, 424, 245)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    self.output = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 402, 245)];
    self.output.editable = NO;
    self.output.selectable = YES;
    self.output.font = [NSFont systemFontOfSize:14];
    self.output.textContainerInset = NSMakeSize(10, 10);
    self.output.autoresizingMask = NSViewWidthSizable;
    self.output.textContainer.widthTracksTextView = YES;
    scroll.documentView = self.output;
    [self.panel.contentView addSubview:scroll];
    [self button:@"Mac status" action:@selector(mac:) frame:NSMakeRect(16, 183, 105, 32)];
    [self button:@"Pi sync status" action:@selector(pi:) frame:NSMakeRect(126, 183, 120, 32)];
    [self button:@"Help" action:@selector(help:) frame:NSMakeRect(251, 183, 72, 32)];
    [self button:@"Voice info" action:@selector(voiceInfo:) frame:NSMakeRect(326, 183, 118, 32)];
    self.input = [[NSTextField alloc] initWithFrame:NSMakeRect(18, 144, 336, 28)];
    self.input.placeholderString = @"Try “time” or “mac status”";
    self.input.target = self;
    self.input.action = @selector(send:);
    self.input.accessibilityLabel = @"Command or voice transcript";
    [self.panel.contentView addSubview:self.input];
    self.sendButton = [self button:@"Send" action:@selector(send:) frame:NSMakeRect(360, 141, 84, 34)];
    self.talkButton = [self button:@"Click to talk…" action:@selector(talk:) frame:NSMakeRect(16, 101, 143, 32)];
    self.speakButton = [self button:@"Speak reply" action:@selector(speak:) frame:NSMakeRect(164, 101, 128, 32)];
    [self button:@"Stop voice" action:@selector(stopVoice:) frame:NSMakeRect(300, 101, 144, 32)];
    self.status = [self label:@"Microphone off. Voice starts only after a click." frame:NSMakeRect(18, 49, 424, 45) size:12];
    NSButton *floatToggle = [self button:@"Float above windows" action:@selector(toggleFloat:) frame:NSMakeRect(16, 10, 200, 30)];
    [floatToggle setButtonType:NSButtonTypeSwitch];
    floatToggle.state = NSControlStateValueOn;
    [self button:@"Hide" action:@selector(hide:) frame:NSMakeRect(280, 10, 75, 30)];
    [self button:@"Quit" action:@selector(quit:) frame:NSMakeRect(363, 10, 80, 30)];
    self.speaker = [AVSpeechSynthesizer new];
    self.speaker.delegate = self;
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"◇";
    self.statusItem.button.toolTip = @"Mica (offline)";
    NSMenu *menu = [NSMenu new];
    NSMenuItem *show = [menu addItemWithTitle:@"Show Mica" action:@selector(show:) keyEquivalent:@""];
    show.target = self;
    NSMenuItem *hide = [menu addItemWithTitle:@"Hide Mica" action:@selector(hide:) keyEquivalent:@""];
    hide.target = self;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [menu addItemWithTitle:@"Quit Mica" action:@selector(quit:) keyEquivalent:@"q"];
    quit.target = self;
    self.statusItem.menu = menu;
    NSMenu *mainMenu = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    NSMenu *appMenu = [NSMenu new];
    NSMenuItem *appQuit = [appMenu addItemWithTitle:@"Quit Mica" action:@selector(quit:) keyEquivalent:@"q"];
    appQuit.target = self;
    appItem.submenu = appMenu;
    [mainMenu addItem:appItem];
    NSMenuItem *editItem = [NSMenuItem new];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = editMenu;
    [mainMenu addItem:editItem];
    NSApp.mainMenu = mainMenu;
    [self performCommand:@"help"];
    [self show:nil];
}
- (void)performCommand:(NSString *)text {
    if (self.busy || text.length == 0) return;
    if (text.length > 2000) { self.status.stringValue = @"Please use a command shorter than 2,000 characters."; return; }
    self.busy = YES;
    [self refreshControls];
    self.output.string = @"Checking locally…";
    NSString *command = [text copy];
    NSString *matched = [NSString stringWithUTF8String:companion_match(command.UTF8String)];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char *raw = companion_reply(command.UTF8String);
        NSString *reply = raw ? [NSString stringWithUTF8String:raw] : @"No reply available.";
        companion_reply_free(raw);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.lastReply = reply;
            self.output.string = [NSString stringWithFormat:@"Submitted: “%@”\nMatched: %@\n\n%@", command, matched, reply];
            [self.output scrollRangeToVisible:NSMakeRange(0, 0)];
            self.busy = NO;
            [self refreshControls];
            if (!self.capturing && !self.authorizing) self.status.stringValue = @"Sent. Microphone off. Type a command or click to talk again.";
        });
    });
}
- (void)refreshControls {
    BOOL reviewing = !self.capturing && !self.authorizing;
    self.sendButton.enabled = !self.busy && reviewing;
    self.speakButton.enabled = !self.busy && reviewing && self.lastReply.length > 0;
    self.input.editable = reviewing;
    self.talkButton.enabled = !self.busy;
}
- (void)setInputText:(NSString *)text {
    // NSTextField's shared field editor can own the current text while focused.
    // Keep it in sync with programmatic speech updates, so ending editing cannot
    // commit an older typed command over the visible transcript.
    self.input.stringValue = text;
    NSText *editor = self.input.currentEditor;
    if (editor) editor.string = text;
}
- (NSString *)commandSnapshot {
    NSText *editor = self.input.currentEditor;
    return [(editor ? editor.string : self.input.stringValue) copy];
}
- (BOOL)acceptTranscript:(NSString *)text generation:(NSUInteger)generation {
    if (generation != self.voiceGeneration || !self.capturing) return NO;
    self.liveTranscript = [text copy];
    [self setInputText:text];
    return YES;
}
- (void)send:(id)sender {
    if (self.busy) return;
    if (self.capturing || self.authorizing) {
        self.status.stringValue = @"Stop listening first, review the transcript, then Send.";
        return;
    }
    // Snapshot the real editor before ending editing or invalidating callbacks.
    NSString *command = [self commandSnapshot];
    [self.panel makeFirstResponder:nil];
    [self setInputText:command];
    [self stopCapture];
    if ([command stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length == 0) {
        self.status.stringValue = @"Nothing to send. Type a command or click to talk.";
        return;
    }
    [self performCommand:command];
}
- (void)mac:(id)sender { [self stopCapture]; [self performCommand:@"mac status"]; }
- (void)pi:(id)sender { [self stopCapture]; [self performCommand:@"pi status"]; }
- (void)help:(id)sender { [self stopCapture]; [self performCommand:@"capabilities"]; }
- (NSString *)voiceDetails {
    SFSpeechRecognizer *recognizer = [[SFSpeechRecognizer alloc] initWithLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"en-US"]];
    AVAuthorizationStatus microphone = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    NSArray<NSString *> *speechStates = @[@"not determined", @"denied", @"restricted", @"authorized"];
    NSArray<NSString *> *microphoneStates = @[@"not determined", @"restricted", @"denied", @"authorized"];
    NSInteger speech = SFSpeechRecognizer.authorizationStatus;
    return [NSString stringWithFormat:@"Voice input diagnostics (no recording)\n\nBundle: %@\nLocale: English (US)\nDevice-only support: %@\nRecognizer available: %@\nSpeech permission: %@\nMicrophone permission: %@\n\nSupport is a capability signal, not proof that the local recognition service can complete a request. Click to talk requires device-only recognition; no server fallback or asset download is requested. Text commands and system speech output work independently.", NSBundle.mainBundle.bundleIdentifier ?: @"unbundled process", recognizer.supportsOnDeviceRecognition ? @"yes" : @"no", recognizer.available ? @"yes" : @"no", speechStates[speech], microphoneStates[microphone]];
}
- (void)voiceInfo:(id)sender {
    [self stopVoice:nil];
    self.output.string = [self voiceDetails];
}
- (void)reportVoiceError:(NSError *)error context:(NSString *)context {
    [self stopCapture];
    NSString *advice = @"Review any partial transcript or use text.";
    if ([error.domain isEqualToString:@"kLSRErrorDomain"] && error.code == 201) {
        advice = @"macOS is blocking recognition because Siri or Dictation is disabled. You can continue using text and Speak reply. If you choose to review Dictation, open System Settings → Keyboard → Dictation and read Apple's privacy explanation. Mica has not changed this setting or enabled Siri.";
    } else if ([error.domain isEqualToString:@"kLSRErrorDomain"] && error.code == 102) {
        advice = @"Required local speech assets are not installed. Mica will not download them or use a server. Please use text.";
    }
    NSString *message = [NSString stringWithFormat:@"%@\n\nNative error: %@ (%ld)\n%@\n\nMicrophone off. No server fallback was attempted. %@\n\n%@", context, error.domain, (long)error.code, error.localizedDescription, advice, [self voiceDetails]];
    self.output.string = message;
    [self.output scrollRangeToVisible:NSMakeRange(0, 0)];
    self.status.stringValue = [NSString stringWithFormat:@"Microphone off. %@ (%ld). Details above.", error.domain, (long)error.code];
}
- (void)show:(id)sender {
    [self.panel deminiaturize:nil];
    [self.panel makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self.panel makeFirstResponder:self.input];
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)flag {
    [self show:nil];
    return NO;
}
- (void)hide:(id)sender { [self stopVoice:nil]; [self.panel orderOut:nil]; }
- (void)quit:(id)sender { [self stopVoice:nil]; [NSApp terminate:nil]; }
- (BOOL)windowShouldClose:(NSWindow *)sender { [self hide:nil]; return NO; }
- (void)windowWillMiniaturize:(NSNotification *)notification { [self stopVoice:nil]; }
- (void)applicationDidResignActive:(NSNotification *)notification {
    if (self.capturing) [self stopVoice:nil];
}
- (void)applicationWillTerminate:(NSNotification *)notification { [self stopVoice:nil]; }
- (void)toggleFloat:(NSButton *)sender { self.panel.level = sender.state == NSControlStateValueOn ? NSFloatingWindowLevel : NSNormalWindowLevel; }
- (void)speak:(id)sender {
    if (!self.lastReply || self.busy) return;
    [self stopVoice:nil];
    AVSpeechSynthesisVoice *voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
    if (!voice) { self.status.stringValue = @"No installed English system voice. Nothing downloaded."; return; }
    AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:self.lastReply];
    utterance.voice = voice;
    self.status.stringValue = @"Speaking with a macOS system voice. Microphone off.";
    [self.speaker speakUtterance:utterance];
}
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didFinishSpeechUtterance:(AVSpeechUtterance *)utterance {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.capturing && !self.authorizing) self.status.stringValue = @"Microphone off. System voice finished.";
    });
}
- (void)stopCapture {
    BOOL wasCapturing = self.capturing;
    NSString *frozenTranscript = [self.liveTranscript copy] ?: @"";
    self.voiceGeneration++;
    [self.timer invalidate]; self.timer = nil;
    self.authorizing = NO;
    self.capturing = NO;
    [self.engine stop];
    if (self.tapInstalled) { [self.engine.inputNode removeTapOnBus:0]; self.tapInstalled = NO; }
    [self.request endAudio];
    [self.task cancel];
    self.task = nil; self.request = nil; self.engine = nil;
    if (wasCapturing) [self setInputText:frozenTranscript];
    self.talkButton.title = @"Click to talk…";
    [self refreshControls];
    self.status.stringValue = wasCapturing && frozenTranscript.length == 0 ? @"Stopped. Microphone off. No speech recognized; type or try again." : @"Review. Microphone off. Edit the text if needed, then Send.";
}
- (void)stopVoice:(id)sender { [self stopCapture]; [self.speaker stopSpeakingAtBoundary:AVSpeechBoundaryImmediate]; }
- (void)talk:(id)sender {
    if (self.capturing || self.authorizing) { [self stopVoice:nil]; return; }
    [self.speaker stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    self.recognizer = [[SFSpeechRecognizer alloc] initWithLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"en-US"]];
    if (!self.recognizer || !self.recognizer.supportsOnDeviceRecognition) {
        self.status.stringValue = @"Device-only English recognition unavailable. Microphone stays off; use text.";
        return;
    }
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Start device-only voice input?";
    alert.informativeText = @"macOS may ask for Speech Recognition and Microphone permission. Audio stays on-device; there is no server fallback. Recording stops after 15 seconds, on Stop voice, or when this app loses focus. The transcript fills the input for your review. Nothing is sent automatically or saved by this app.";
    [alert addButtonWithTitle:@"Continue"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    self.authorizing = YES;
    NSUInteger generation = ++self.voiceGeneration;
    self.talkButton.title = @"Cancel voice";
    self.status.stringValue = @"Waiting for macOS permission. Microphone off.";
    [self refreshControls];
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.voiceGeneration != generation || !self.authorizing) return;
            if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
                [self stopCapture]; self.status.stringValue = @"Speech permission unavailable or denied. Use text; microphone off."; return;
            }
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.voiceGeneration != generation || !self.authorizing) return;
                    if (!granted || !NSApp.active || !self.panel.visible) {
                        [self stopCapture]; self.status.stringValue = @"Voice not started: permission, focus, or visibility changed. Use text or click again."; return;
                    }
                    [self startCapture:generation];
                });
            }];
        });
    }];
}
- (void)startCapture:(NSUInteger)generation {
    if (!self.recognizer.supportsOnDeviceRecognition || !self.recognizer.available) {
        [self stopCapture]; self.status.stringValue = @"Device-only recognition unavailable right now. Microphone off."; return;
    }
    // End the typed editing session before the transcript becomes authoritative.
    [self.panel makeFirstResponder:self.talkButton];
    self.liveTranscript = @"";
    [self setInputText:@""];
    self.request = [SFSpeechAudioBufferRecognitionRequest new];
    self.request.requiresOnDeviceRecognition = YES;
    self.request.shouldReportPartialResults = YES;
    self.engine = [AVAudioEngine new];
    AVAudioInputNode *node = self.engine.inputNode;
    AVAudioFormat *format = [node outputFormatForBus:0];
    if (format.sampleRate == 0 || format.channelCount == 0) {
        [self stopCapture]; self.status.stringValue = @"No usable microphone input. Use text."; return;
    }
    SFSpeechAudioBufferRecognitionRequest *request = self.request;
    @try {
        [node installTapOnBus:0 bufferSize:1024 format:format block:^(AVAudioPCMBuffer *buffer, AVAudioTime *time) {
            [request appendAudioPCMBuffer:buffer];
        }];
        self.tapInstalled = YES;
        [self.engine prepare];
        NSError *error = nil;
        if (![self.engine startAndReturnError:&error]) {
            [self reportVoiceError:error context:@"Could not start microphone audio."]; return;
        }
    } @catch (NSException *exception) {
        [self stopCapture]; self.status.stringValue = @"Audio device could not start. Microphone off."; return;
    }
    self.authorizing = NO;
    self.capturing = YES;
    [self refreshControls];
    self.talkButton.title = @"Stop listening";
    self.status.stringValue = @"Listening on-device (15s max). Click Stop listening, review, then Send.";
    self.task = [self.recognizer recognitionTaskWithRequest:request resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.voiceGeneration || !self.capturing) return;
            if (result) [self acceptTranscript:result.bestTranscription.formattedString generation:generation];
            if (error) {
                [self reportVoiceError:error context:@"On-device speech recognition failed."];
            } else if (result.final) {
                [self stopCapture];
                self.status.stringValue = @"Review. Microphone off. Final transcript ready; edit if needed, then Send.";
            }
        });
    }];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:15 repeats:NO block:^(NSTimer *timer) {
        if (generation == self.voiceGeneration) [self stopCapture];
    }];
}
@end

void companion_run(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        Companion *delegate = [Companion new];
        app.delegate = delegate;
        [app run];
        (void)delegate;
    }
}

void companion_voice_check(void) {
    @autoreleasepool {
        SFSpeechRecognizer *recognizer = [[SFSpeechRecognizer alloc] initWithLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"en-US"]];
        printf("English (US) device recognition supported: %s\n", recognizer.supportsOnDeviceRecognition ? "yes" : "no");
        printf("Speech authorization status: %ld (0=undetermined, 1=denied, 2=restricted, 3=authorized)\n", (long)SFSpeechRecognizer.authorizationStatus);
        printf("No permission prompt, audio capture, model download, or recognition request started.\n");
        printf("CLI permission identity can differ from the app. Use Voice info in Mica for its actual authorization state.\n");
    }
}

// Exercise actual AppKit field-editor behavior and the same transcript lifecycle
// methods as recognition callbacks. Synthetic strings only: no permissions/audio.
int companion_native_tests(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        Companion *test = [Companion new];
        test.panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(-4000, -4000, 460, 300)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        test.panel.releasedWhenClosed = NO;
        test.input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 30)];
        [test.panel.contentView addSubview:test.input];
        test.status = [NSTextField labelWithString:@""];
        test.sendButton = [NSButton new];
        test.speakButton = [NSButton new];
        test.talkButton = [NSButton new];
        [test setInputText:@"help"];
        [test.panel makeFirstResponder:test.input];
        int failures = 0;
#define CHECK(condition, label) do { if (!(condition)) { fprintf(stderr, "FAIL: %s\n", label); failures++; } else { printf("PASS: %s\n", label); } } while (0)
        CHECK(test.input.currentEditor != nil, "real AppKit field editor is active");
        test.voiceGeneration = 41;
        test.capturing = YES;
        [test refreshControls];
        CHECK(!test.sendButton.enabled && !test.input.editable, "listening blocks editing and Send");
        CHECK([test acceptTranscript:@"Time." generation:41], "current speech session accepts transcript");
        CHECK([[test commandSnapshot] isEqualToString:@"Time."], "speech replaces old focused help command");
        CHECK([test.input.currentEditor.string isEqualToString:@"Time."], "field editor matches programmatic speech text");
        [test send:nil];
        CHECK(!test.busy, "Send cannot dispatch during listening");
        [test stopCapture];
        CHECK(test.sendButton.enabled && test.input.editable, "stop enables review and manual Send");
        CHECK(![test acceptTranscript:@"help" generation:41], "late result after Stop is rejected");
        CHECK([[test commandSnapshot] isEqualToString:@"Time."], "stopped transcript remains frozen");
        [test.panel makeFirstResponder:test.input];
        test.input.currentEditor.string = @"Mac status";
        NSString *edited = [test commandSnapshot];
        CHECK([edited isEqualToString:@"Mac status"], "manual review edits beat the backing control value");
        [test.panel makeFirstResponder:nil];
        [test setInputText:edited];
        CHECK(strcmp(companion_match([test commandSnapshot].UTF8String), "Mac status") == 0, "reviewed text dispatches to the Rust Mac action");
        test.voiceGeneration = 99;
        test.capturing = YES;
        CHECK([test acceptTranscript:@"Max status." generation:99], "observed speech alias accepted by current session");
        CHECK(![test acceptTranscript:@"help" generation:41], "previous session cannot overwrite new transcript");
        [test stopCapture];
        CHECK(strcmp(companion_match([test commandSnapshot].UTF8String), "Mac status") == 0, "stopped observed Max status transcript matches Mac action");
        test.authorizing = YES;
        [test refreshControls];
        CHECK(!test.sendButton.enabled, "pending permission blocks Send");
        [test stopCapture];
        CHECK(![test acceptTranscript:@"help" generation:test.voiceGeneration], "idle callback cannot overwrite reviewed text");
        [test.panel close];
        printf("Native lifecycle tests: %d failure(s). No recording or permission requests.\n", failures);
#undef CHECK
        return failures ? 1 : 0;
    }
}
