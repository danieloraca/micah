#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>

// Turn detection is local and deliberately conservative: both the acoustic
// activity and the recognized text must have settled. A final recognition
// result alone is not permission to submit a still-speaking user's turn.
static BOOL MicaPauseReady(BOOL active, BOOL capturing, BOOL busy, NSString *text,
                          double now, double lastSound, double lastText, double pause) {
    return active && capturing && !busy &&
        [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0 &&
        lastText > 0 && now-lastSound >= pause && now-lastText >= pause;
}
static BOOL MicaConversationCanResume(BOOL active, BOOL busy, BOOL visible, BOOL minimized,
                                     BOOL appActive, double now, double deadline, NSUInteger turns) {
    return active && !busy && visible && !minimized && appActive && now < deadline && turns < 10;
}
static double MicaBufferRMS(AVAudioPCMBuffer *buffer) {
    if (!buffer.floatChannelData || !buffer.frameLength || !buffer.format.channelCount) return 0;
    double sum=0;
    for (AVAudioChannelCount c=0;c<buffer.format.channelCount;c++) {
        const float *samples=buffer.floatChannelData[c];
        for (AVAudioFrameCount f=0;f<buffer.frameLength;f++) {
            double sample=samples[f*buffer.stride];
            if (isfinite(sample)) sum+=sample*sample;
        }
    }
    return sqrt(sum/((double)buffer.frameLength*buffer.format.channelCount));
}

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
extern char *companion_reply_with_voice(const char *input,const char *voice,uint64_t ticket);
extern void companion_audio_cancel(void);
extern uint64_t companion_audio_generation(void);

// One GUI process per user across both the .app and cargo-run executable.
// No key or preferences are read here. The file contains only a process ID.
static int MicaInstanceFD = -1;
static NSString * const MicaShowNotification = @"local.dan.desktop-companion.show-existing";
static BOOL MicaShouldReadVoiceReply(BOOL voice, BOOL enabled, BOOL visible, BOOL minimized, BOOL capturing, BOOL authorizing) {
    return voice && enabled && visible && !minimized && !capturing && !authorizing;
}
static BOOL MicaNeedsPermissionRequest(NSInteger status) { return status == 0; }
static BOOL MicaUsesOpenAIVoice(BOOL voice, BOOL readReply, NSString *choice) {
    return voice && readReply && choice.length>0 && ![choice isEqual:@"local"];
}
static void MicaSpeechPermission(void (^completion)(SFSpeechRecognizerAuthorizationStatus)) {
    SFSpeechRecognizerAuthorizationStatus status=SFSpeechRecognizer.authorizationStatus;
    if(MicaNeedsPermissionRequest(status)) [SFSpeechRecognizer requestAuthorization:completion];
    else completion(status);
}
static void MicaMicrophonePermission(void (^completion)(BOOL)) {
    AVAuthorizationStatus status=[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if(MicaNeedsPermissionRequest(status)) [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:completion];
    else completion(status==AVAuthorizationStatusAuthorized);
}
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

@interface Companion : NSObject <NSApplicationDelegate, NSWindowDelegate, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate>
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
@property NSButton *autoSpeakButton;
@property BOOL voiceDraft;
@property NSUInteger playbackGeneration;
@property NSPopUpButton *voicePicker;
@property AVAudioPlayer *audioPlayer;
@property NSData *lastAudio;
@property NSButton *conversationButton;
@property NSPopUpButton *pausePicker;
@property BOOL conversationActive;
@property NSUInteger conversationGeneration;
@property NSUInteger conversationTurns;
@property double conversationDeadline;
@property double lastSoundAt;
@property double lastTranscriptAt;
@property NSTimer *conversationTimer;
@property NSTimer *resumeTimer;
@property BOOL resumeAfterSpeech;
@property AVSpeechUtterance *currentUtterance;
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
    self.panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 460, 735)
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
    NSButton *floatToggle = [self button:@"Float" action:@selector(toggleFloat:) frame:NSMakeRect(16, 10, 65, 30)];
    [floatToggle setButtonType:NSButtonTypeSwitch];
    floatToggle.state = NSControlStateValueOn;
    self.autoSpeakButton = [self button:@"Read voice replies" action:@selector(toggleAutoSpeak:) frame:NSMakeRect(88, 10, 190, 30)];
    [self.autoSpeakButton setButtonType:NSButtonTypeSwitch];
    id savedVoicePreference = [NSUserDefaults.standardUserDefaults objectForKey:@"AutoSpeakVoiceReplies"];
    self.autoSpeakButton.state = savedVoicePreference == nil || [savedVoicePreference boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    [self button:@"Hide" action:@selector(hide:) frame:NSMakeRect(280, 10, 75, 30)];
    [self button:@"Quit" action:@selector(quit:) frame:NSMakeRect(363, 10, 80, 30)];
    // Reserve an explicit AI setup area; voice controls retain their own states.
    for (NSView *view in self.panel.contentView.subviews) {
        NSRect frame = view.frame; frame.origin.y += 185; view.frame = frame;
    }
    self.conversationButton=[self button:@"Conversation: pause to send" action:@selector(toggleConversation:) frame:NSMakeRect(16,145,265,30)];
    [self.conversationButton setButtonType:NSButtonTypeSwitch];
    // Auto-submit is intentionally session-only and off on every launch.
    self.pausePicker=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(282,145,161,30) pullsDown:NO];
    for(NSNumber *pause in @[@1.2,@1.8,@2.5]) {
        [self.pausePicker addItemWithTitle:[NSString stringWithFormat:@"Pause: %@ sec",pause]];
        self.pausePicker.lastItem.representedObject=pause;
    }
    [self.pausePicker selectItemAtIndex:1];
    [self.panel.contentView addSubview:self.pausePicker];
    [self label:@"Voice replies" frame:NSMakeRect(18, 111, 95, 22) size:12];
    self.voicePicker=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(118, 105, 325, 32) pullsDown:NO];
    self.voicePicker.target=self;self.voicePicker.action=@selector(changeReplyVoice:);
    [self.voicePicker addItemWithTitle:@"Mac voice (local)"];self.voicePicker.lastItem.representedObject=@"local";
    for(NSString *voice in @[@"marin",@"coral",@"sage",@"cedar",@"alloy",@"ash",@"ballad",@"echo",@"shimmer",@"verse"]) {
        [self.voicePicker addItemWithTitle:[NSString stringWithFormat:@"OpenAI · %@ (paid)",voice.capitalizedString]];self.voicePicker.lastItem.representedObject=voice;
    }
    NSString *savedVoice=[NSUserDefaults.standardUserDefaults stringForKey:@"ReplyVoiceChoice"] ?: @"local";
    for(NSMenuItem *item in self.voicePicker.itemArray) if([item.representedObject isEqual:savedVoice]) [self.voicePicker selectItem:item];
    [self.panel.contentView addSubview:self.voicePicker];
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
    [self endConversation];
    self.voiceDraft=NO;
    [self performCommand:text voiceReply:NO];
}
- (void)performCommand:(NSString *)text voiceReply:(BOOL)voiceReply {
    if (self.busy || text.length == 0) return;
    if (text.length > 2000) { [self endConversation];self.status.stringValue = @"Please use a command shorter than 2,000 characters. Conversation stopped."; return; }
    [self stopPlaybackAndCapture];
    self.busy = YES;
    [self refreshControls];
    self.output.string = @"Working… Local commands stay local; enabled AI sends text to OpenAI.";
    NSString *command = [text copy];
    NSUInteger playbackGeneration=self.playbackGeneration;
    NSUInteger conversationGeneration=self.conversationGeneration;
    uint64_t audioTicket=companion_audio_generation();
    NSString *selectedVoice=[self.voicePicker.selectedItem.representedObject copy] ?: @"local";
    BOOL requestRemoteVoice=MicaUsesOpenAIVoice(voiceReply,self.autoSpeakButton.state==NSControlStateValueOn,selectedVoice);
    NSString *matched = [NSString stringWithUTF8String:companion_match(command.UTF8String)];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char *raw = requestRemoteVoice ? companion_reply_with_voice(command.UTF8String,selectedVoice.UTF8String,audioTicket) : companion_reply(command.UTF8String);
        NSString *json = raw ? [NSString stringWithUTF8String:raw] : @"{}";
        companion_reply_free(raw);
        NSDictionary *envelope = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        NSString *reply = envelope[@"text"] ?: @"No reply available.";
        NSString *source = envelope[@"source"] ?: @"Unavailable";
        NSString *usage = envelope[@"usage"] ?: @"API usage unavailable.";
        NSString *encodedAudio=envelope[@"audio_wav"];
        NSData *audio=encodedAudio.length<=4000000 ? [[NSData alloc] initWithBase64EncodedString:encodedAudio ?: @"" options:0] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self displayReply:reply command:command matched:matched source:source usage:usage];
            self.lastAudio=audio.length>44 ? audio : nil;
            self.speakButton.title=self.lastAudio ? @"Replay voice" : @"Speak reply";
            self.busy = NO;
            [self refreshControls];
            [self refreshAIStatus];
            if (!self.capturing && !self.authorizing) {
                self.status.stringValue = self.startupNotice ?: @"Sent. Microphone off. Type a command or click to talk again.";
                self.startupNotice = nil;
            }
            BOOL continuing=self.conversationActive && conversationGeneration==self.conversationGeneration;
            if (continuing && (![source hasPrefix:@"Local ·"] && (![source hasPrefix:@"OpenAI"] || [source containsString:@"failed"]))) {
                [self endConversation];
                continuing=NO;
                self.status.stringValue=@"Conversation stopped. Review the result; no automatic retry. Microphone off.";
            }
            self.resumeAfterSpeech=continuing;
            if (playbackGeneration == self.playbackGeneration && MicaShouldReadVoiceReply(voiceReply,self.autoSpeakButton.state==NSControlStateValueOn,self.panel.visible,self.panel.miniaturized,self.capturing,self.authorizing)) {
                [self speak:nil];
            } else if(continuing) {
                [self scheduleNextTurn];
            }
        });
    });
}
- (void)displayReply:(NSString *)reply command:(NSString *)command matched:(NSString *)matched source:(NSString *)source usage:(NSString *)usage {
    self.lastReply = reply;
    self.lastAudio=nil;
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
    self.voicePicker.enabled = !self.busy && reviewing;
    self.conversationButton.enabled = !self.busy && !self.authorizing;
    self.pausePicker.enabled = !self.busy && reviewing && !self.conversationActive;
}
- (void)endConversation {
    self.conversationActive=NO;
    self.conversationGeneration++;
    self.resumeAfterSpeech=NO;
    [self.resumeTimer invalidate];self.resumeTimer=nil;
    [self.conversationTimer invalidate];self.conversationTimer=nil;
    [self refreshControls];
}
- (void)toggleConversation:(NSButton *)sender {
    [self stopVoice:nil];
    if(sender.state!=NSControlStateValueOn) {
        self.status.stringValue=@"Conversation off. Click to talk uses review and manual Send.";
        return;
    }
    NSAlert *notice=[NSAlert new];notice.messageText=@"Send voice turns automatically after a pause?";
    notice.informativeText=@"Click to talk starts a visible conversation session. After recognized speech and the selected quiet pause, Mica sends the transcript without another click. With AI enabled, non-command text and bounded history go to OpenAI and each turn can incur API charges, including the selected paid voice. Audio input stays on-device.\n\nThe microphone is off while waiting for or playing a reply, then starts again. Stop voice, Stop listening, hiding Mica or switching away ends the session. Sessions stop at 3 minutes or 10 turns; silent turns stop at 15 seconds. Errors and long uninterrupted speech stop for review. Pause detection can mistake a thinking pause or background speech for your turn. This option is off again at launch; no recording starts from this dialog.";
    [notice addButtonWithTitle:@"Use conversation mode"];[notice addButtonWithTitle:@"Cancel"];
    if([notice runModal]!=NSAlertFirstButtonReturn) sender.state=NSControlStateValueOff;
    self.status.stringValue=sender.state==NSControlStateValueOn ? @"Conversation ready. Click to talk once; pause to send. Stop voice ends the session." : @"Conversation off. Microphone off.";
}
- (void)beginConversation {
    self.conversationActive=YES;
    self.conversationGeneration++;
    self.conversationTurns=0;
    self.conversationDeadline=NSProcessInfo.processInfo.systemUptime+180;
    NSUInteger generation=self.conversationGeneration;
    self.conversationTimer=[NSTimer scheduledTimerWithTimeInterval:180 repeats:NO block:^(NSTimer *timer) {
        if(self.conversationActive && generation==self.conversationGeneration) {
            [self stopVoice:nil];self.status.stringValue=@"Conversation reached 3 minutes. Microphone off. Click to talk to start again.";
        }
    }];
}
- (BOOL)conversationEnvironmentReady {
    return self.panel.visible && !self.panel.miniaturized && NSApp.active;
}
- (void)scheduleNextTurn {
    self.resumeAfterSpeech=NO;
    [self.resumeTimer invalidate];
    if(!self.conversationActive) return;
    if(!MicaConversationCanResume(self.conversationActive,self.busy,YES,NO,[self conversationEnvironmentReady],NSProcessInfo.processInfo.systemUptime,self.conversationDeadline,self.conversationTurns)) {
        [self endConversation];self.status.stringValue=@"Conversation ended. Microphone off. Click to talk to start again.";return;
    }
    NSUInteger generation=self.conversationGeneration;
    self.status.stringValue=@"Reply finished. Listening resumes in a moment. Stop voice ends conversation.";
    // Let speaker/device audio drain before reopening the microphone.
    self.resumeTimer=[NSTimer scheduledTimerWithTimeInterval:0.65 repeats:NO block:^(NSTimer *timer) {
        self.resumeTimer=nil;
        if(generation!=self.conversationGeneration || !self.conversationActive) return;
        if(!MicaConversationCanResume(self.conversationActive,self.busy,YES,NO,[self conversationEnvironmentReady],NSProcessInfo.processInfo.systemUptime,self.conversationDeadline,self.conversationTurns)) {
            [self endConversation];return;
        }
        [self startCapture:++self.voiceGeneration];
    }];
}
- (void)submitPausedTurn:(NSUInteger)generation atTime:(double)now {
    double pause=[self.pausePicker.selectedItem.representedObject doubleValue];
    if(generation!=self.voiceGeneration || !MicaPauseReady(self.conversationActive,self.capturing,self.busy,self.liveTranscript,now,self.lastSoundAt,self.lastTranscriptAt,pause)) return;
    if(now>=self.conversationDeadline || self.conversationTurns>=10 || ![self conversationEnvironmentReady]) {
        [self stopVoice:nil];return;
    }
    [self stopCapture]; // freezes the exact text and invalidates all late callbacks
    self.conversationTurns++;
    [self send:nil];
}
- (void)captureTick:(NSUInteger)generation atTime:(double)now started:(double)started {
    if (generation != self.voiceGeneration || !self.capturing) return;
    if(self.conversationActive) {
        // Never auto-send at a hard timeout or from ambient sound alone.
        if(now-started>=30 || (now-started>=15 && self.lastTranscriptAt==0)) {
            [self stopVoice:nil];self.status.stringValue=@"Listening timed out. Microphone off. Review any draft and Send manually.";return;
        }
        [self submitPausedTurn:generation atTime:now];
    } else if(now-started>=15) [self stopCapture];
}
- (void)changeReplyVoice:(NSPopUpButton *)sender {
    [self stopVoice:nil];
    NSString *selected=sender.selectedItem.representedObject;
    NSString *old=[NSUserDefaults.standardUserDefaults stringForKey:@"ReplyVoiceChoice"] ?: @"local";
    if(![selected isEqual:@"local"] && ![selected isEqual:old]) {
        NSAlert *notice=[NSAlert new];notice.messageText=@"Use paid OpenAI voice replies?";
        notice.informativeText=@"For voice-submitted AI questions with Read voice replies on, one gpt-realtime-2.1-mini request generates the spoken answer and matching transcript. Your reviewed text plus bounded AI history goes to OpenAI; microphone audio stays on this Mac. The existing output-token cap also applies to audio generation, which has separate rates. Usage will be shown; no monetary estimate is calculated. This is an API voice, not a verified copy of this chat's voice.\n\nTyped questions keep the text model. Local commands stay local. Missing/unplayable audio falls back to the Mac voice when an answer transcript exists. A failed audio request is not retried through another paid model. No preview/request is sent by choosing this option.";
        [notice addButtonWithTitle:@"Use this voice"];[notice addButtonWithTitle:@"Cancel"];
        if([notice runModal]!=NSAlertFirstButtonReturn) {for(NSMenuItem *item in sender.itemArray) if([item.representedObject isEqual:old]) [sender selectItem:item];return;}
    }
    [NSUserDefaults.standardUserDefaults setObject:selected forKey:@"ReplyVoiceChoice"];
    self.status.stringValue=[selected isEqual:@"local"] ? @"Mac voice selected. No additional audio API charge." : @"OpenAI voice selected for voice replies. Paid only when you Send an AI voice question.";
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
    [self stopVoice:nil];
    companion_ai_disable();
    [self refreshAIStatus];
    self.status.stringValue = @"AI off for this session; history cleared. Saved key/preferences unchanged.";
}
- (void)clearAI:(id)sender {
    if (self.busy) return;
    [self stopVoice:nil];
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
    [self stopVoice:nil];
    alert.informativeText = @"Enable AI now uses your entered key for this session even if optional saving fails. Send (or pause-to-send in an explicitly started conversation) transmits non-command text and up to 3 previous AI turns (12 KB) to OpenAI. API billing is separate from ChatGPT; the output cap is not a spending limit. Microphone audio stays local. No AI tools. Usage metadata (model, time and token counts) is saved locally for LLM Usage; prompts, replies, audio and keys are excluded.\n\nSave/replace uses your encrypted macOS default (normally login) Keychain. macOS may ask permission; only you should answer that prompt. No plaintext key file. A blank field uses a saved Mica key. Save settings alone keeps AI off. Nothing here sends an API request.";
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
    if(![self.liveTranscript isEqualToString:text]) self.lastTranscriptAt=NSProcessInfo.processInfo.systemUptime;
    self.liveTranscript = [text copy];
    self.voiceDraft = text.length > 0;
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
    BOOL voiceReply=self.voiceDraft;
    self.voiceDraft=NO;
    [self performCommand:command voiceReply:voiceReply];
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
    [self stopVoice:nil];
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
    if (self.capturing || self.authorizing || self.conversationActive) [self stopVoice:nil];
}
- (void)applicationWillTerminate:(NSNotification *)notification { [self stopVoice:nil]; if (!self.busy) companion_ai_disable(); }
- (void)toggleFloat:(NSButton *)sender { self.panel.level = sender.state == NSControlStateValueOn ? NSFloatingWindowLevel : NSNormalWindowLevel; }
- (void)toggleAutoSpeak:(NSButton *)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.state==NSControlStateValueOn forKey:@"AutoSpeakVoiceReplies"];
    if(sender.state!=NSControlStateValueOn) [self stopVoice:nil];
}
- (void)speak:(id)sender {
    if (!self.lastReply || self.busy) return;
    if(sender) [self endConversation];
    [self stopPlaybackAndCapture];
    if(self.lastAudio) {
        NSError *error=nil;self.audioPlayer=[[AVAudioPlayer alloc] initWithData:self.lastAudio error:&error];
        self.audioPlayer.delegate=self;
        if(self.audioPlayer && [self.audioPlayer play]) {self.status.stringValue=@"Playing AI-generated OpenAI voice. Microphone off. Replay uses cached audio.";return;}
        self.audioPlayer=nil;
    }
    AVSpeechSynthesisVoice *voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
    if (!voice) { [self endConversation];self.status.stringValue = @"No installed English system voice. Nothing downloaded. Conversation ended."; return; }
    AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:self.lastReply];
    utterance.voice = voice;
    self.currentUtterance=utterance;
    self.status.stringValue = @"Speaking with a macOS system voice. Microphone off.";
    [self.speaker speakUtterance:utterance];
}
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)success {
    if(player!=self.audioPlayer) return;
    self.audioPlayer=nil;
    self.status.stringValue=success ? @"OpenAI voice finished. Microphone off." : @"Audio playback ended. Text answer remains available.";
    if(success && self.resumeAfterSpeech) [self scheduleNextTurn];
    else if(!success) [self endConversation];
}
- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *)error {
    if(player!=self.audioPlayer) return;
    [self stopVoice:nil];self.status.stringValue=@"Audio playback failed. Conversation stopped; the text answer remains available.";
}
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didFinishSpeechUtterance:(AVSpeechUtterance *)utterance {
    dispatch_async(dispatch_get_main_queue(), ^{
        if(utterance!=self.currentUtterance) return;
        self.currentUtterance=nil;
        if (!self.capturing && !self.authorizing) self.status.stringValue = @"Microphone off. System voice finished.";
        if(self.resumeAfterSpeech) [self scheduleNextTurn];
    });
}
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didCancelSpeechUtterance:(AVSpeechUtterance *)utterance {
    dispatch_async(dispatch_get_main_queue(), ^{
        if(utterance!=self.currentUtterance) return;
        [self stopVoice:nil];
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
- (void)stopPlaybackAndCapture {
    self.playbackGeneration++;companion_audio_cancel();[self.audioPlayer stop];self.audioPlayer=nil;
    self.currentUtterance=nil;
    [self stopCapture];[self.speaker stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
}
- (void)stopVoice:(id)sender {
    [self endConversation];[self stopPlaybackAndCapture];
    self.status.stringValue=@"Stopped. Microphone off. Review any draft; nothing more will send automatically.";
}
- (void)talk:(id)sender {
    if(self.busy) return;
    if (self.capturing || self.authorizing) { [self stopVoice:nil]; return; }
    [self stopVoice:nil];
    self.recognizer = [[SFSpeechRecognizer alloc] initWithLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"en-US"]];
    if (!self.recognizer || !self.recognizer.supportsOnDeviceRecognition) {
        self.status.stringValue = @"Device-only English recognition unavailable. Microphone stays off; use text.";
        return;
    }
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"VoiceCaptureExplained"]) {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Start device-only voice input?";
    alert.informativeText = @"macOS may ask for Speech Recognition and Microphone permission. Audio stays on-device; there is no server fallback. Normal input stops after 15 seconds for review and manual Send. Explicit conversation mode instead sends recognized text after a quiet pause, then listens again after the reply. Stop voice or switching away stops either mode. Audio is not saved by this app.";
    [alert addButtonWithTitle:@"Continue"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"VoiceCaptureExplained"];
    }
    if(self.conversationButton.state==NSControlStateValueOn) [self beginConversation];
    self.authorizing = YES;
    NSUInteger generation = ++self.voiceGeneration;
    self.talkButton.title = @"Cancel voice";
    self.status.stringValue = @"Waiting for macOS permission. Microphone off.";
    [self refreshControls];
    MicaSpeechPermission(^(SFSpeechRecognizerAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.voiceGeneration != generation || !self.authorizing) return;
            if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
                [self stopVoice:nil]; self.status.stringValue = @"Speech permission unavailable or denied. Use text; microphone off."; return;
            }
            MicaMicrophonePermission(^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.voiceGeneration != generation || !self.authorizing) return;
                    if (!granted || !NSApp.active || !self.panel.visible) {
                        [self stopVoice:nil]; self.status.stringValue = @"Voice not started: permission, focus, or visibility changed. Use text or click again."; return;
                    }
                    [self startCapture:generation];
                });
            });
        });
    });
}
- (void)startCapture:(NSUInteger)generation {
    if (!self.recognizer.supportsOnDeviceRecognition || !self.recognizer.available) {
        [self stopVoice:nil]; self.status.stringValue = @"Device-only recognition unavailable right now. Microphone off."; return;
    }
    // End the typed editing session before the transcript becomes authoritative.
    [self.panel makeFirstResponder:self.talkButton];
    self.liveTranscript = @"";
    self.lastSoundAt=NSProcessInfo.processInfo.systemUptime;
    self.lastTranscriptAt=0;
    self.voiceDraft=NO;
    [self setInputText:@""];
    self.request = [SFSpeechAudioBufferRecognitionRequest new];
    self.request.requiresOnDeviceRecognition = YES;
    self.request.shouldReportPartialResults = YES;
    self.engine = [AVAudioEngine new];
    AVAudioInputNode *node = self.engine.inputNode;
    AVAudioFormat *format = [node outputFormatForBus:0];
    if (format.sampleRate == 0 || format.channelCount == 0) {
        [self stopVoice:nil]; self.status.stringValue = @"No usable microphone input. Use text."; return;
    }
    SFSpeechAudioBufferRecognitionRequest *request = self.request;
    @try {
        [node installTapOnBus:0 bufferSize:1024 format:format block:^(AVAudioPCMBuffer *buffer, AVAudioTime *time) {
            [request appendAudioPCMBuffer:buffer];
            // Inspect only current PCM energy; retain no raw microphone buffer.
            double rms=MicaBufferRMS(buffer);
            if(rms>=0.006) {
                double now=NSProcessInfo.processInfo.systemUptime;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if(self.capturing && self.voiceGeneration==generation) self.lastSoundAt=now;
                });
            }
        }];
        self.tapInstalled = YES;
        [self.engine prepare];
        NSError *error = nil;
        if (![self.engine startAndReturnError:&error]) {
            [self reportVoiceError:error context:@"Could not start microphone audio."]; return;
        }
    } @catch (NSException *exception) {
        [self stopVoice:nil]; self.status.stringValue = @"Audio device could not start. Microphone off."; return;
    }
    self.authorizing = NO;
    self.capturing = YES;
    [self refreshControls];
    self.talkButton.title = @"Stop listening";
    self.status.stringValue = self.conversationActive ? @"Listening on-device. Pause to send automatically. Stop voice ends conversation." : @"Listening on-device (15s max). Click Stop listening, review, then Send.";
    self.task = [self.recognizer recognitionTaskWithRequest:request resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.voiceGeneration || !self.capturing) return;
            if (result) [self acceptTranscript:result.bestTranscription.formattedString generation:generation];
            if (error) {
                [self reportVoiceError:error context:@"On-device speech recognition failed."];
            } else if (result.final && !self.conversationActive) {
                [self stopCapture];
                self.status.stringValue = @"Review. Microphone off. Final transcript ready; edit if needed, then Send.";
            }
        });
    }];
    double started=NSProcessInfo.processInfo.systemUptime;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
        [self captureTick:generation atTime:NSProcessInfo.processInfo.systemUptime started:started];
    }];
}
@end

// Test seam replaces only external effects, retaining the production pause,
// freeze/send, cancellation and rearm transitions. Never records or calls APIs.
@interface MicaTurnTest : Companion
@property NSUInteger submittedCount;
@property NSString *submittedText;
@property BOOL submittedVoice;
@property NSUInteger captureStarts;
@property BOOL environmentReady;
@end
@implementation MicaTurnTest
- (BOOL)conversationEnvironmentReady {return self.environmentReady;}
- (void)performCommand:(NSString *)text voiceReply:(BOOL)voiceReply {
    self.submittedCount++;self.submittedText=[text copy];self.submittedVoice=voiceReply;
}
- (void)startCapture:(NSUInteger)generation {self.captureStarts++;self.capturing=YES;}
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
        CHECK(MicaUsesOpenAIVoice(YES,YES,@"marin") && !MicaUsesOpenAIVoice(NO,YES,@"marin") && !MicaUsesOpenAIVoice(YES,NO,@"marin") && !MicaUsesOpenAIVoice(YES,YES,@"local"),"paid audio requires selected OpenAI voice, voice-origin Send and playback enabled");
        CHECK(MicaShouldReadVoiceReply(YES,YES,YES,NO,NO,NO),"voice-origin replies automatically read the displayed answer");
        CHECK(MicaNeedsPermissionRequest(0) && !MicaNeedsPermissionRequest(1) && !MicaNeedsPermissionRequest(2) && !MicaNeedsPermissionRequest(3),"system permissions are requested only while undetermined");
        CHECK(!MicaShouldReadVoiceReply(NO,YES,YES,NO,NO,NO),"typed replies do not automatically play audio");
        CHECK(!MicaShouldReadVoiceReply(YES,NO,YES,NO,NO,NO),"voice reply playback respects the off switch");
        CHECK(!MicaShouldReadVoiceReply(YES,YES,NO,NO,NO,NO) && !MicaShouldReadVoiceReply(YES,YES,YES,YES,NO,NO),"hidden or minimized replies stay silent");
        CHECK(!MicaShouldReadVoiceReply(YES,YES,YES,NO,YES,NO) && !MicaShouldReadVoiceReply(YES,YES,YES,NO,NO,YES),"reply playback cannot overlap microphone capture or permission setup");
        test.voiceGeneration = 41;
        test.capturing = YES;
        [test refreshControls];
        CHECK(!test.sendButton.enabled && !test.input.editable, "listening blocks editing and Send");
        CHECK([test acceptTranscript:@"Time." generation:41], "current speech session accepts transcript");
        CHECK(test.voiceDraft,"accepted speech marks the reviewed draft as voice-origin");
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
        test.lastAudio=[NSData dataWithBytes:"fixture" length:7];
        [test displayReply:@"Synthetic answer" command:@"Synthetic question" matched:@"OpenAI text" source:@"Fixture only — not live" usage:@"API-reported tokens — input: 120; output: 30; total: 150. Cost estimate: not calculated."];
        CHECK(test.lastAudio==nil,"new text reply cannot replay audio from an older answer");
        CHECK([test.output.string containsString:@"total: 150"] && [test.output.string containsString:@"Cost estimate: not calculated"], "reply renderer shows reported usage separately from cost");
        CHECK([test.lastReply isEqualToString:@"Synthetic answer"], "system speech reads answer without token metadata");
        [test stopVoice:nil];
        NSUInteger canceledPlayback=test.playbackGeneration;
        uint64_t canceledRemoteAudio=companion_audio_generation();
        [test stopVoice:nil];
        CHECK(companion_audio_generation()!=canceledRemoteAudio,"Stop voice cancels pending remote audio generation");
        CHECK(test.playbackGeneration>canceledPlayback,"Stop voice invalidates pending automatic playback");
        CHECK(companion_ai_session_enabled(),"Stop voice does not disable the AI session");
        CHECK(MicaPauseReady(YES,YES,NO,@"time",103,100,101,1.8),"quiet pause with settled recognized text can submit");
        CHECK(!MicaPauseReady(YES,YES,NO,@"time",102,101,100,1.8),"new speech delays automatic submission");
        CHECK(!MicaPauseReady(YES,YES,NO,@"time",102,100,101,1.8),"changing transcript delays automatic submission");
        CHECK(!MicaPauseReady(YES,YES,NO,@" \n",103,100,101,1.8),"silence or whitespace never creates a request");
        CHECK(!MicaPauseReady(YES,YES,NO,@"time",103,100,0,1.8),"no recognition event means no automatic request");
        CHECK(!MicaPauseReady(NO,YES,NO,@"time",103,100,101,1.8) && !MicaPauseReady(YES,NO,NO,@"time",103,100,101,1.8) && !MicaPauseReady(YES,YES,YES,@"time",103,100,101,1.8),"manual mode, stopped capture and busy requests cannot auto-send");
        CHECK(!MicaPauseReady(YES,YES,NO,@"time",103,101,101,2.5),"longer selected thinking pause is respected");
        CHECK(MicaConversationCanResume(YES,NO,YES,NO,YES,100,200,9),"bounded conversation may resume after a reply");
        CHECK(!MicaConversationCanResume(YES,NO,YES,NO,YES,200,200,1) && !MicaConversationCanResume(YES,NO,YES,NO,YES,100,200,10),"session time and turn limits block rearming");
        CHECK(!MicaConversationCanResume(NO,NO,YES,NO,YES,100,200,1) && !MicaConversationCanResume(YES,YES,YES,NO,YES,100,200,1) && !MicaConversationCanResume(YES,NO,NO,NO,YES,100,200,1) && !MicaConversationCanResume(YES,NO,YES,YES,YES,100,200,1) && !MicaConversationCanResume(YES,NO,YES,NO,NO,100,200,1),"stop, in-flight request, hidden, minimized or inactive app cannot rearm");
        AVAudioFormat *pcmFormat=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:24000 channels:1];
        AVAudioPCMBuffer *pcm=[[AVAudioPCMBuffer alloc] initWithPCMFormat:pcmFormat frameCapacity:240];pcm.frameLength=240;
        memset(pcm.floatChannelData[0],0,240*sizeof(float));
        CHECK(MicaBufferRMS(pcm)==0,"silent PCM does not mark acoustic activity");
        for(NSUInteger i=0;i<240;i++) pcm.floatChannelData[0][i]=0.02f;
        CHECK(fabs(MicaBufferRMS(pcm)-0.02)<0.0001,"local PCM energy detects synthetic speech-level signal");
        MicaTurnTest *turn=[MicaTurnTest new];
        turn.panel=test.panel;turn.input=[NSTextField new];turn.status=[NSTextField labelWithString:@""];turn.environmentReady=YES;
        turn.pausePicker=[NSPopUpButton new];[turn.pausePicker addItemWithTitle:@"1.8"];turn.pausePicker.lastItem.representedObject=@1.8;
        double now=NSProcessInfo.processInfo.systemUptime;
        turn.conversationActive=YES;turn.conversationDeadline=now+30;turn.capturing=YES;turn.voiceGeneration=500;
        [turn acceptTranscript:@"Time." generation:500];turn.lastSoundAt=now-3;turn.lastTranscriptAt=now-3;
        [turn submitPausedTurn:500 atTime:now];
        CHECK(turn.submittedCount==1 && turn.submittedVoice && [turn.submittedText isEqual:@"Time."] && !turn.capturing,"pause freezes and submits the current voice transcript exactly once");
        [turn submitPausedTurn:500 atTime:now+1];
        CHECK(turn.submittedCount==1 && ![turn acceptTranscript:@"stale replacement" generation:500],"duplicate timer and late recognition cannot duplicate or change a sent turn");
        [turn scheduleNextTurn];[turn stopVoice:nil];
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.75]];
        CHECK(turn.captureStarts==0 && !turn.conversationActive,"Stop cancels a pending post-reply microphone restart");
        turn.conversationActive=YES;turn.conversationDeadline=NSProcessInfo.processInfo.systemUptime+30;
        [turn scheduleNextTurn];
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.75]];
        CHECK(turn.captureStarts==1 && turn.capturing,"completed reply rearms one synthetic next turn after the audio drain delay");
        [turn applicationDidResignActive:[NSNotification notificationWithName:NSApplicationDidResignActiveNotification object:nil]];
        CHECK(!turn.conversationActive && !turn.capturing,"switching away ends conversation and microphone capture");
        turn.conversationActive=YES;turn.environmentReady=NO;[turn scheduleNextTurn];
        CHECK(!turn.conversationActive && turn.resumeTimer==nil,"invisible or inactive environment blocks rearm");
        turn.environmentReady=YES;turn.conversationActive=YES;turn.capturing=YES;turn.voiceGeneration=600;turn.lastTranscriptAt=0;turn.liveTranscript=@"";
        NSUInteger beforeTimeout=turn.submittedCount;
        [turn captureTick:600 atTime:now+15 started:now];
        CHECK(!turn.conversationActive && !turn.capturing && turn.submittedCount==beforeTimeout,"15 seconds without recognized speech stops without a request");
        turn.conversationActive=YES;turn.capturing=YES;turn.voiceGeneration=601;turn.liveTranscript=@"unfinished thought";turn.lastTranscriptAt=now+29;turn.lastSoundAt=now+29;
        [turn captureTick:601 atTime:now+30 started:now];
        CHECK(!turn.conversationActive && !turn.capturing && turn.submittedCount==beforeTimeout && [turn.input.stringValue isEqual:@"unfinished thought"],"30-second utterance cutoff preserves a partial draft without auto-sending");
        turn.capturing=YES;turn.voiceGeneration=602;
        [turn captureTick:602 atTime:now+15 started:now];
        CHECK(!turn.capturing && turn.submittedCount==beforeTimeout,"manual mode timeout still stops for review without sending");
        [turn beginConversation];
        [turn.conversationTimer fire];
        CHECK(!turn.conversationActive && !turn.resumeTimer,"session deadline ends conversation and invalidates rearm");
        turn.conversationActive=YES;turn.conversationDeadline=now+30;turn.conversationTurns=10;
        [turn scheduleNextTurn];
        CHECK(!turn.conversationActive && !turn.resumeTimer,"tenth submitted turn ends the session before another microphone start");
        [turn stopVoice:nil];
        companion_ai_disable();
        [test.panel close];
        printf("Native lifecycle tests: %d failure(s). No recording or permission requests.\n", failures);
#undef CHECK
        return failures ? 1 : 0;
    }
}
