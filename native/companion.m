#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

extern char *companion_reply(const char *input);
extern void companion_reply_free(char *value);
extern const char *companion_match(const char *input);
extern char *companion_ai_configure(const char *key, const char *model, uint32_t cap);
extern char *companion_ai_status(void);
extern void companion_ai_disable(void);
extern void companion_ai_clear(void);
extern char *companion_ai_save(const char *key,const char *model,uint32_t cap,uint8_t remember,uint8_t autoEnable,uint8_t enable);
extern char *companion_ai_remove_saved(void);
extern char *companion_persistence_startup(void);
extern uint8_t companion_ai_session_enabled(void);

// One GUI process per user across both the .app and cargo-run executable.
// No key or preferences are read here. The file contains only a process ID.
static int MicaInstanceFD = -1;
static NSString * const MicaShowNotification = @"local.dan.desktop-companion.show-existing";
static int MicaClaimInstanceAtPath(NSString *path, int *descriptor) {
    int fd = open(path.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != getuid()) {close(fd);return -1;}
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {int failure=errno;close(fd);return failure == EWOULDBLOCK || failure == EAGAIN ? 0 : -1;}
    *descriptor = fd;
    return 1;
}
static BOOL MicaClaimInstance(void) {
    NSString *directory = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Mica"];
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]) {
        NSAlert *alert = [NSAlert new];alert.messageText = @"Mica could not open its private instance directory.";
        alert.informativeText = @"No second window or AI request was started. Check access to Application Support/Mica.";[alert runModal];return NO;
    }
    NSString *path = [directory stringByAppendingPathComponent:@"instance.lock"];
    int claimed = MicaClaimInstanceAtPath(path, &MicaInstanceFD);
    if (claimed == 1) {
        ftruncate(MicaInstanceFD, 0);
        const char *pid = [[NSString stringWithFormat:@"%d\n", getpid()] UTF8String];
        (void)write(MicaInstanceFD, pid, strlen(pid));
        return YES;
    }
    if (claimed < 0) {
        NSAlert *alert=[NSAlert new];alert.messageText=@"Mica could not verify its single running instance.";
        alert.informativeText=@"Check permissions for Application Support/Mica/instance.lock. No second window or AI request was started.";[alert runModal];return NO;
    }
    // A read-only PID helps foreground the existing process. The notification
    // unhides its window without changing AI settings or reading credentials.
    NSString *pidText = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    pid_t pid = (pid_t)pidText.intValue;
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:MicaShowNotification object:NSUserName() userInfo:nil deliverImmediately:YES];
    if (pid > 0) [[NSRunningApplication runningApplicationWithProcessIdentifier:pid] activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    return NO;
}

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
@property NSTextField *aiStatus;
@property NSButton *aiSettingsButton;
@property NSButton *aiClearButton;
@property NSButton *aiDisableButton;
@property NSString *startupNotice;
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
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(showExisting:) name:MicaShowNotification object:NSUserName()];
    self.panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 460, 650)
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
    [self label:@"Local commands • Optional OpenAI text • Placeholder appearance" frame:NSMakeRect(18, 475, 424, 24) size:12];
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
    // Reserve an explicit AI setup area; voice controls retain their own states.
    for (NSView *view in self.panel.contentView.subviews) {
        NSRect frame = view.frame; frame.origin.y += 100; view.frame = frame;
    }
    self.aiSettingsButton = [self button:@"AI settings…" action:@selector(aiSettings:) frame:NSMakeRect(16, 56, 138, 32)];
    self.aiClearButton = [self button:@"Clear AI chat" action:@selector(clearAI:) frame:NSMakeRect(160, 56, 132, 32)];
    self.aiDisableButton = [self button:@"Disable AI" action:@selector(disableAI:) frame:NSMakeRect(300, 56, 144, 32)];
    self.aiStatus = [self label:@"AI off. Local commands only. No API request will be sent." frame:NSMakeRect(18, 8, 424, 43) size:11];
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
    [self refreshAIStatus];
    [self show:nil];
    self.busy=YES;[self refreshControls];self.status.stringValue=@"Loading saved AI preferences… No API request is sent.";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        char *raw=companion_persistence_startup();NSString *message=[NSString stringWithUTF8String:raw];companion_reply_free(raw);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.startupNotice=message;self.busy=NO;[self performCommand:@"help"];[self refreshAIStatus];
        });
    });
}
- (void)showExisting:(NSNotification *)notification { [self show:nil]; }
- (void)performCommand:(NSString *)text {
    if (self.busy || text.length == 0) return;
    if (text.length > 2000) { self.status.stringValue = @"Please use a command shorter than 2,000 characters."; return; }
    self.busy = YES;
    [self refreshControls];
    self.output.string = @"Working… Local commands stay local; enabled AI sends text to OpenAI.";
    NSString *command = [text copy];
    NSString *matched = [NSString stringWithUTF8String:companion_match(command.UTF8String)];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char *raw = companion_reply(command.UTF8String);
        NSString *json = raw ? [NSString stringWithUTF8String:raw] : @"{}";
        companion_reply_free(raw);
        NSDictionary *envelope = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        NSString *reply = envelope[@"text"] ?: @"No reply available.";
        NSString *source = envelope[@"source"] ?: @"Unavailable";
        NSString *usage = envelope[@"usage"] ?: @"API usage unavailable.";
        dispatch_async(dispatch_get_main_queue(), ^{
            [self displayReply:reply command:command matched:matched source:source usage:usage];
            self.busy = NO;
            [self refreshControls];
            [self refreshAIStatus];
            if (!self.capturing && !self.authorizing) {
                self.status.stringValue = self.startupNotice ?: @"Sent. Microphone off. Type a command or click to talk again.";
                self.startupNotice = nil;
            }
        });
    });
}
- (void)displayReply:(NSString *)reply command:(NSString *)command matched:(NSString *)matched source:(NSString *)source usage:(NSString *)usage {
    self.lastReply = reply;
    self.output.string = [NSString stringWithFormat:@"Submitted: “%@”\nMatched: %@\nSource: %@\n\n%@\n\n%@", command, matched, source, usage, reply];
    [self.output scrollRangeToVisible:NSMakeRange(0, 0)];
}
- (void)refreshControls {
    BOOL reviewing = !self.capturing && !self.authorizing;
    self.sendButton.enabled = !self.busy && reviewing;
    self.speakButton.enabled = !self.busy && reviewing && self.lastReply.length > 0;
    self.input.editable = reviewing;
    self.talkButton.enabled = !self.busy;
    self.aiSettingsButton.enabled = !self.busy && reviewing;
    self.aiClearButton.enabled = !self.busy && reviewing;
    self.aiDisableButton.enabled = !self.busy && reviewing;
}
- (NSDictionary *)aiPublicSettings {
    char *raw = companion_ai_status();
    NSString *json = [NSString stringWithUTF8String:raw];
    companion_reply_free(raw);
    return [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
}
- (void)refreshAIStatus {
    NSDictionary *settings = [self aiPublicSettings];
    self.aiStatus.stringValue = [settings[@"enabled"] boolValue]
        ? [NSString stringWithFormat:@"AI on • %@ • cap %@ tokens/request • %@ prior turns\nText + up to 3 prior AI turns sent to OpenAI. Separate API billing.", settings[@"model"], settings[@"cap"], settings[@"history_pairs"]]
        : @"AI off. Local commands only. No API request will be sent.\nAI settings supports an optional saved key in macOS Keychain.";
}
- (void)disableAI:(id)sender {
    if (self.busy) return;
    companion_ai_disable();
    [self refreshAIStatus];
    self.status.stringValue = @"AI off for this session; history cleared. Saved key/preferences unchanged.";
}
- (void)clearAI:(id)sender {
    if (self.busy) return;
    companion_ai_clear();
    [self refreshAIStatus];
    self.status.stringValue = @"AI conversation history cleared. No request sent.";
}
- (void)finishAISetup:(NSString *)message enable:(BOOL)enable {
    self.busy = NO;[self refreshControls];[self refreshAIStatus];
    self.status.stringValue = message;
    BOOL enabled = [[self aiPublicSettings][@"enabled"] boolValue];
    NSAlert *result = [NSAlert new];
    result.messageText = enabled ? @"AI is enabled" : (enable ? @"AI was not enabled" : @"Settings result — AI is off");
    result.informativeText = message;
    [result addButtonWithTitle:@"OK"];[result runModal];
}
- (void)aiSettings:(id)sender {
    if (self.busy || self.capturing || self.authorizing) return;
    NSDictionary *settings = [self aiPublicSettings];
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"OpenAI settings and macOS Keychain";
    alert.informativeText = @"Enable AI now uses your entered key for this session even if optional saving fails. Manual Send transmits non-command text and up to 3 previous AI turns (12 KB) to OpenAI. API billing is separate from ChatGPT; the output cap is not a spending limit. Audio stays local. No automatic submission or AI tools.\n\nSave/replace uses your encrypted macOS default (normally login) Keychain. macOS may ask permission; only you should answer that prompt. No plaintext key file. A blank field uses a saved Mica key. Save settings alone keeps AI off. Nothing here sends an API request.";
    NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 360, 230)];
    NSTextField *keyLabel = [NSTextField wrappingLabelWithString:[settings[@"key_saved"] boolValue] ? @"Saved-key preference present (not probed). Blank keeps it; type to replace." : @"API key — optional save; never paste into chat or Git"];
    keyLabel.frame = NSMakeRect(0, 187, 360, 40); [form addSubview:keyLabel];
    NSSecureTextField *key = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 158, 360, 26)];
    key.placeholderString = @"Blank: use saved key when Enable AI now is clicked"; [form addSubview:key];
    NSTextField *modelLabel = [NSTextField labelWithString:@"Model ID"];
    modelLabel.frame = NSMakeRect(0, 133, 145, 20); [form addSubview:modelLabel];
    NSTextField *model = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 104, 360, 26)];
    model.stringValue = settings[@"saved_model"]; [form addSubview:model];
    NSTextField *capLabel = [NSTextField labelWithString:@"Output-token cap (32–4096)"];
    capLabel.frame = NSMakeRect(0, 68, 240, 24); [form addSubview:capLabel];
    NSTextField *cap = [[NSTextField alloc] initWithFrame:NSMakeRect(250, 68, 110, 26)];
    cap.stringValue = [settings[@"saved_cap"] stringValue]; [form addSubview:cap];
    NSButton *remember = [NSButton checkboxWithTitle:@"Save/replace key in macOS Keychain" target:nil action:NULL];
    remember.frame = NSMakeRect(0, 35, 360, 26); remember.state = NSControlStateValueOff; [form addSubview:remember];
    NSButton *autoEnable = [NSButton checkboxWithTitle:@"Enable AI at app launch using the saved key" target:nil action:NULL];
    autoEnable.frame = NSMakeRect(0, 5, 360, 26); autoEnable.state = [settings[@"auto_enable"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff; [form addSubview:autoEnable];
    alert.accessoryView = form;
    [alert addButtonWithTitle:@"Save settings"];
    [alert addButtonWithTitle:@"Enable AI now"];
    [alert addButtonWithTitle:@"Remove saved key"];
    [alert addButtonWithTitle:@"Cancel"];
    NSModalResponse choice = [alert runModal];
    [alert.window makeFirstResponder:nil];
    if (choice == NSAlertThirdButtonReturn) {
        NSAlert *confirm = [NSAlert new]; confirm.messageText = @"Remove Mica's saved OpenAI key?";
        confirm.informativeText = @"Only Mica's Keychain item is removed. AI turns off and saved startup enablement is cleared. Model/cap remain. No API request is sent.";
        [confirm addButtonWithTitle:@"Remove saved key"]; [confirm addButtonWithTitle:@"Cancel"];
        if ([confirm runModal] == NSAlertFirstButtonReturn) {
            self.busy=YES;[self refreshControls];self.status.stringValue=@"Removing Mica's saved key…";
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
                char *raw=companion_ai_remove_saved();NSString *message=[NSString stringWithUTF8String:raw];companion_reply_free(raw);
                dispatch_async(dispatch_get_main_queue(), ^{[self finishAISetup:message enable:NO];});
            });
        }
    } else if (choice == NSAlertFirstButtonReturn || choice == NSAlertSecondButtonReturn) {
        NSScanner *scanner = [NSScanner scannerWithString:cap.stringValue];
        NSInteger capValue = 0;
        BOOL validCap = [scanner scanInteger:&capValue] && scanner.isAtEnd && capValue >= 32 && capValue <= 4096;
        if (!validCap) {
            self.status.stringValue = @"Invalid cap: enter 32–4096. No request sent.";
        } else {
            NSString *typedKey=[key.stringValue copy];NSString *selectedModel=[model.stringValue copy];
            BOOL rememberKey=remember.state==NSControlStateValueOn, startup=autoEnable.state==NSControlStateValueOn, enable=choice==NSAlertSecondButtonReturn;
            self.busy=YES;[self refreshControls];self.status.stringValue=@"Applying AI settings… No API request is sent.";
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
                char *raw=companion_ai_save(typedKey.UTF8String,selectedModel.UTF8String,(uint32_t)capValue,rememberKey,startup,enable);
                NSString *message=[NSString stringWithUTF8String:raw];companion_reply_free(raw);
                dispatch_async(dispatch_get_main_queue(), ^{[self finishAISetup:message enable:enable];});
            });
        }
    }
    key.stringValue = @"";
    if(!self.busy) [self refreshAIStatus];
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
- (void)applicationWillTerminate:(NSNotification *)notification { [self stopVoice:nil]; if (!self.busy) companion_ai_disable(); }
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
        if (!MicaClaimInstance()) return;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        Companion *delegate = [Companion new];
        app.delegate = delegate;
        [app run];
        (void)delegate;
        if (MicaInstanceFD >= 0) {close(MicaInstanceFD);MicaInstanceFD = -1;}
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
        test.output = [NSTextView new];
        test.sendButton = [NSButton new];
        test.speakButton = [NSButton new];
        test.talkButton = [NSButton new];
        [test setInputText:@"help"];
        [test.panel makeFirstResponder:test.input];
        int failures = 0;
#define CHECK(condition, label) do { if (!(condition)) { fprintf(stderr, "FAIL: %s\n", label); failures++; } else { printf("PASS: %s\n", label); } } while (0)
        NSString *lockPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"mica-instance-test-%@",NSUUID.UUID.UUIDString]];
        int first=-1, second=-1;
        CHECK(MicaClaimInstanceAtPath(lockPath,&first)==1,"first GUI instance obtains the user lock");
        CHECK(MicaClaimInstanceAtPath(lockPath,&second)==0,"another app/cargo launch cannot create separate AI state");
        if(first>=0) close(first);
        CHECK(MicaClaimInstanceAtPath(lockPath,&second)==1,"instance lock is released after process lifetime");
        if(second>=0) close(second);
        [NSFileManager.defaultManager removeItemAtPath:lockPath error:NULL];
        CHECK(MicaClaimInstanceAtPath([lockPath stringByAppendingPathComponent:@"missing"],&second)==-1,"lock errors are distinguished from a running instance");
        char *configured=companion_ai_configure("fixture-only-not-a-secret","gpt-5.4-nano",128);
        CHECK(strlen(configured)==0 && companion_ai_session_enabled(),"synthetic session enables without Keychain or API access");
        companion_reply_free(configured);
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
        CHECK(companion_ai_session_enabled(),"stopping transcript capture preserves the enabled AI session");
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
        [test displayReply:@"Synthetic answer" command:@"Synthetic question" matched:@"OpenAI text" source:@"Fixture only — not live" usage:@"API-reported tokens — input: 120; output: 30; total: 150. Cost estimate: not calculated."];
        CHECK([test.output.string containsString:@"total: 150"] && [test.output.string containsString:@"Cost estimate: not calculated"], "reply renderer shows reported usage separately from cost");
        CHECK([test.lastReply isEqualToString:@"Synthetic answer"], "system speech reads answer without token metadata");
        [test stopVoice:nil];
        CHECK(companion_ai_session_enabled(),"Stop voice does not disable the AI session");
        companion_ai_disable();
        [test.panel close];
        printf("Native lifecycle tests: %d failure(s). No recording or permission requests.\n", failures);
#undef CHECK
        return failures ? 1 : 0;
    }
}
