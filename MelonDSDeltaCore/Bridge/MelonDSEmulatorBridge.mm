//
//  MelonDSEmulatorBridge.m
//  MelonDSDeltaCore
//
//  Created by Riley Testut on 10/31/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

#import "MelonDSEmulatorBridge.h"

#import <UIKit/UIKit.h> // Prevent undeclared symbols in below headers

#import <DeltaCore/DeltaCore.h>
#import <DeltaCore/DeltaCore-Swift.h>

#if STATIC_LIBRARY
#import "MelonDSDeltaCore-Swift.h"
#else
#import <MelonDSDeltaCore/MelonDSDeltaCore-Swift.h>
#endif

#include "melonDS/src/Platform.h"
#include "melonDS/src/NDS.h"
#include "melonDS/src/SPU.h"
#include "melonDS/src/GPU.h"
#include "melonDS/src/AREngine.h"

// zhuowei
//#include "melonDS/src/Config.h"
#include "melonDS/src/NDSCart.h"

#include <memory>

#import <notify.h>
#import <pthread.h>

// Copied from melonDS source (no longer exists in HEAD)
void ParseTextCode(char* text, int tlen, u32* code, int clen) // or whatever this should be named?
{
    u32 cur_word = 0;
    u32 ndigits = 0;
    u32 nin = 0;
    u32 nout = 0;

    char c;
    while ((c = *text++) != '\0')
    {
        u32 val;
        if (c >= '0' && c <= '9')
            val = c - '0';
        else if (c >= 'a' && c <= 'f')
            val = c - 'a' + 0xA;
        else if (c >= 'A' && c <= 'F')
            val = c - 'A' + 0xA;
        else
            continue;

        cur_word <<= 4;
        cur_word |= val;

        ndigits++;
        if (ndigits >= 8)
        {
            if (nout >= clen)
            {
                printf("AR: code too long!\n");
                return;
            }

            *code++ = cur_word;
            nout++;

            ndigits = 0;
            cur_word = 0;
        }

        nin++;
        if (nin >= tlen) break;
    }

    if (nout & 1)
    {
        printf("AR: code was missing one word\n");
        if (nout >= clen)
        {
            printf("AR: code too long!\n");
            return;
        }
        *code++ = 0;
    }
}

@interface MelonDSEmulatorBridge ()

@property (nonatomic, copy, nullable, readwrite) NSURL *gameURL;

@property (nonatomic) uint32_t activatedInputs;
@property (nonatomic) CGPoint touchScreenPoint;

@property (nonatomic, readonly) std::shared_ptr<ARCodeFile> cheatCodes;
@property (nonatomic, readonly) int notifyToken;

@property (nonatomic, getter=isInitialized) BOOL initialized;
@property (nonatomic, getter=isStopping) BOOL stopping;
@property (nonatomic, getter=isMicrophoneEnabled) BOOL microphoneEnabled;

@property (nonatomic, nullable) AVAudioEngine *audioEngine;
@property (nonatomic, nullable, readonly) AVAudioConverter *audioConverter; // May be nil while microphone is being used by another app.
@property (nonatomic, readonly) AVAudioUnitEQ *audioEQEffect;
@property (nonatomic, readonly) DLTARingBuffer *microphoneBuffer;
@property (nonatomic, readonly) dispatch_queue_t microphoneQueue;

@end

@implementation MelonDSEmulatorBridge
@synthesize audioRenderer = _audioRenderer;
@synthesize videoRenderer = _videoRenderer;
@synthesize saveUpdateHandler = _saveUpdateHandler;
@synthesize audioConverter = _audioConverter;

+ (instancetype)sharedBridge
{
    static MelonDSEmulatorBridge *_emulatorBridge = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _emulatorBridge = [[self alloc] init];
    });
    
    return _emulatorBridge;
}

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _cheatCodes = std::make_shared<ARCodeFile>("");
        _activatedInputs = 0;
        
        _audioEQEffect = [[AVAudioUnitEQ alloc] initWithNumberOfBands:2];
        
        _microphoneBuffer = [[DLTARingBuffer alloc] initWithPreferredBufferSize:100 * 1024];
        _microphoneQueue = dispatch_queue_create("com.rileytestut.MelonDSDeltaCore.Microphone", DISPATCH_QUEUE_SERIAL);
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAudioSessionInterruption:) name:AVAudioSessionInterruptionNotification object:nil];
    }
    
    return self;
}

#pragma mark - Emulation State -

- (void)startWithGameURL:(NSURL *)gameURL
{
    self.gameURL = gameURL;
    
    if ([self isInitialized])
    {
        NDS::DeInit();
    }
    else
    {
// zhuowei: replaced in new melonDS
#if 0
        // DS paths
        strncpy(Config::BIOS7Path, self.bios7URL.lastPathComponent.UTF8String, self.bios7URL.lastPathComponent.length);
        strncpy(Config::BIOS9Path, self.bios9URL.lastPathComponent.UTF8String, self.bios9URL.lastPathComponent.length);
        strncpy(Config::FirmwarePath, self.firmwareURL.lastPathComponent.UTF8String, self.firmwareURL.lastPathComponent.length);
        
        // DSi paths
        strncpy(Config::DSiBIOS7Path, self.dsiBIOS7URL.lastPathComponent.UTF8String, self.dsiBIOS7URL.lastPathComponent.length);
        strncpy(Config::DSiBIOS9Path, self.dsiBIOS9URL.lastPathComponent.UTF8String, self.dsiBIOS9URL.lastPathComponent.length);
        strncpy(Config::DSiFirmwarePath, self.dsiFirmwareURL.lastPathComponent.UTF8String, self.dsiFirmwareURL.lastPathComponent.length);
        strncpy(Config::DSiNANDPath, self.dsiNANDURL.lastPathComponent.UTF8String, self.dsiNANDURL.lastPathComponent.length);
#endif
        
        [self registerForNotifications];
        
        // Renderer is not deinitialized in NDS::DeInit, so initialize it only once.
        GPU::InitRenderer(0);
    }
    
    [self prepareAudioEngine];
    
    NDS::SetConsoleType((int)self.systemType);

#if 0
    Config::JIT_Enable = [self isJITEnabled];
    Config::JIT_FastMemory = NO;
#endif
    
    NDS::Init();
    self.initialized = YES;
        
    GPU::RenderSettings settings;
    settings.Soft_Threaded = YES;

    GPU::SetRenderSettings(0, settings);
  
    NDS::LoadBIOS();
    
    BOOL isDirectory = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:gameURL.path isDirectory:&isDirectory] && !isDirectory)
    {
      NSError* error;
      NSData* cartData = [NSData dataWithContentsOfURL:gameURL options:0 error:&error];
      if (!cartData) {
        NSLog(@"failed to load cart data!! %@", error);
      } else {
        if (!NDS::LoadCart((const u8*)cartData.bytes, cartData.length, nullptr, 0))
        {
          NSLog(@"Failed to load Nintendo DS ROM.");
        } else {
          NDS::SetupDirectBoot(gameURL.lastPathComponent.UTF8String);
        }
      }
    }
    else
    {
        // NDS::LoadBIOS();
    }
    
    self.stopping = NO;
    NDS::Start();
}

- (void)stop
{
    self.stopping = YES;
    
    NDS::Stop();
    
    [self.audioEngine stop];
    
    // Assign to nil to prevent microphone indicator
    // staying on after returning from background.
    self.audioEngine = nil;
}

- (void)pause
{
    [self.audioEngine pause];
}

- (void)resume
{
}

#pragma mark - Game Loop -

- (void)runFrameAndProcessVideo:(BOOL)processVideo
{
    if ([self isStopping])
    {
        return;
    }
    
    uint32_t inputs = self.activatedInputs;
    uint32_t inputsMask = 0xFFF; // 0b000000111111111111;
    
    uint16_t sanitizedInputs = inputsMask ^ inputs;
    NDS::SetKeyMask(sanitizedInputs);
    
    if (self.activatedInputs & MelonDSGameInputTouchScreenX || self.activatedInputs & MelonDSGameInputTouchScreenY)
    {
        NDS::TouchScreen(self.touchScreenPoint.x, self.touchScreenPoint.y);
    }
    else
    {
        NDS::ReleaseScreen();
    }
    
    if (self.activatedInputs & MelonDSGameInputLid)
    {
        NDS::SetLidClosed(true);
    }
    else if (NDS::IsLidClosed())
    {
        NDS::SetLidClosed(false);
    }
    
    static int16_t micBuffer[735];
    NSInteger readBytes = (NSInteger)[self.microphoneBuffer readIntoBuffer:micBuffer preferredSize:735 * sizeof(int16_t)];
    NSInteger readFrames = readBytes / sizeof(int16_t);
    
    if (readFrames > 0)
    {
        NDS::MicInputFrame(micBuffer, (int)readFrames);
    }
    
    if ([self isJITEnabled])
    {
        // Skipping frames with JIT disabled can cause graphical bugs,
        // so limit frame skip to devices that support JIT (for now).
        NDS::SetSkipFrame(!processVideo);
    }
    
    NDS::RunFrame();
    
    static int16_t buffer[0x1000];
    u32 availableBytes = SPU::GetOutputSize();
    availableBytes = MAX(availableBytes, (u32)(sizeof(buffer) / (2 * sizeof(int16_t))));
       
    int samples = SPU::ReadOutput(buffer, availableBytes);
    [self.audioRenderer.audioBuffer writeBuffer:buffer size:samples * 4];
    
    if (processVideo)
    {
        int screenBufferSize = 256 * 192 * 4;
        
        memcpy(self.videoRenderer.videoBuffer, GPU::Framebuffer[GPU::FrontBuffer][0], screenBufferSize);
        memcpy(self.videoRenderer.videoBuffer + screenBufferSize, GPU::Framebuffer[GPU::FrontBuffer][1], screenBufferSize);
        
        [self.videoRenderer processFrame];
    }
}

#pragma mark - Inputs -

- (void)activateInput:(NSInteger)input value:(double)value
{
    self.activatedInputs |= (uint32_t)input;
    
    CGPoint touchPoint = self.touchScreenPoint;
    
    switch ((MelonDSGameInput)input)
    {
    case MelonDSGameInputTouchScreenX:
        touchPoint.x = value * (256 - 1);
        break;
        
    case MelonDSGameInputTouchScreenY:
        touchPoint.y = value * (192 - 1);
        break;
            
    default: break;
    }

    self.touchScreenPoint = touchPoint;
}

- (void)deactivateInput:(NSInteger)input
{
    self.activatedInputs &= ~((uint32_t)input);
    
    CGPoint touchPoint = self.touchScreenPoint;
    
    switch ((MelonDSGameInput)input)
    {
        case MelonDSGameInputTouchScreenX:
            touchPoint.x = 0;
            break;
            
        case MelonDSGameInputTouchScreenY:
            touchPoint.y = 0;
            break;
            
        default: break;
    }
    
    self.touchScreenPoint = touchPoint;
}

- (void)resetInputs
{
    self.activatedInputs = 0;
    self.touchScreenPoint = CGPointZero;
}

#pragma mark - Game Saves -

- (void)saveGameSaveToURL:(NSURL *)URL
{
    //NDS::RelocateSave(URL.fileSystemRepresentation, true);
}

- (void)loadGameSaveFromURL:(NSURL *)URL
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:URL.path])
    {
        return;
    }
    
    //NDS::RelocateSave(URL.fileSystemRepresentation, false);
}

#pragma mark - Save States -

- (void)saveSaveStateToURL:(NSURL *)URL
{
    Savestate *savestate = new Savestate(URL.fileSystemRepresentation, true);
    NDS::DoSavestate(savestate);
    delete savestate;
}

- (void)loadSaveStateFromURL:(NSURL *)URL
{
    Savestate *savestate = new Savestate(URL.fileSystemRepresentation, false);
    NDS::DoSavestate(savestate);
    delete savestate;
}

#pragma mark - Cheats -

- (BOOL)addCheatCode:(NSString *)cheatCode type:(NSString *)type
{
    NSArray<NSString *> *codes = [cheatCode componentsSeparatedByString:@"\n"];
    for (NSString *code in codes)
    {
        if (code.length != 17)
        {
            return NO;
        }
        
        NSMutableCharacterSet *legalCharactersSet = [NSMutableCharacterSet hexadecimalCharacterSet];
        [legalCharactersSet addCharactersInString:@" "];
        
        if ([code rangeOfCharacterFromSet:legalCharactersSet.invertedSet].location != NSNotFound)
        {
            return NO;
        }
    }
    
    NSString *sanitizedCode = [[cheatCode componentsSeparatedByCharactersInSet:NSCharacterSet.hexadecimalCharacterSet.invertedSet] componentsJoinedByString:@""];
    int codeLength = (sanitizedCode.length / 8);
    
    ARCode code;
    //memset(code.Name, 0, 128);
    memset(code.Code, 0, 128);
    //memcpy(code.Name, sanitizedCode.UTF8String, MIN(128, sanitizedCode.length));
    code.Name = sanitizedCode.UTF8String;
    ParseTextCode((char *)sanitizedCode.UTF8String, (int)[sanitizedCode lengthOfBytesUsingEncoding:NSUTF8StringEncoding], &code.Code[0], 128);
    code.Enabled = YES;
    code.CodeLen = codeLength;

    ARCodeCat category;
    //memcpy(category.Name, sanitizedCode.UTF8String, MIN(128, sanitizedCode.length));
    category.Name = sanitizedCode.UTF8String;
    category.Codes.push_back(code);

    self.cheatCodes->Categories.push_back(category);

    return YES;
}

- (void)resetCheats
{
    self.cheatCodes->Categories.clear();
    AREngine::Reset();
}

- (void)updateCheats
{
    AREngine::SetCodeFile(self.cheatCodes.get());
}

#pragma mark - Notifications -

- (void)registerForNotifications
{
    int status = notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &_notifyToken, dispatch_get_main_queue(), ^(int t) {
        uint64_t state;
        int result = notify_get_state(self.notifyToken, &state);
        NSLog(@"Lock screen state = %llu", state);
        
        if (state == 0)
        {
            [self deactivateInput:MelonDSGameInputLid];
        }
        else
        {
            [self activateInput:MelonDSGameInputLid value:1];
        }
        
        if (result != NOTIFY_STATUS_OK)
        {
            NSLog(@"Lock screen notification returned: %d", result);
        }
    });
    
    if (status != NOTIFY_STATUS_OK)
    {
        NSLog(@"Lock screen notification registration returned: %d", status);
    }
}

#pragma mark - Microphone -

- (void)prepareAudioEngine
{
    self.audioEngine = [[AVAudioEngine alloc] init];
    if ([self.audioEngine.inputNode inputFormatForBus:0].sampleRate == 0)
    {
        // Microphone is being used by another application.
        self.microphoneEnabled = NO;
        return;
    }
    
    self.microphoneEnabled = YES;
        
    // Experimentally-determined values. Focuses on ensuring blows are registered correctly.
    self.audioEQEffect.bands[0].filterType = AVAudioUnitEQFilterTypeLowShelf;
    self.audioEQEffect.bands[0].frequency = 100;
    self.audioEQEffect.bands[0].gain = 20;
    self.audioEQEffect.bands[0].bypass = NO;

    self.audioEQEffect.bands[1].filterType = AVAudioUnitEQFilterTypeHighShelf;
    self.audioEQEffect.bands[1].frequency = 10000;
    self.audioEQEffect.bands[1].gain = -30;
    self.audioEQEffect.bands[1].bypass = NO;
    
    self.audioEQEffect.globalGain = 3;
    
    [self.audioEngine attachNode:self.audioEQEffect];
    [self.audioEngine connect:self.audioEngine.inputNode to:self.audioEQEffect format:self.audioConverter.inputFormat];
    
    NSInteger bufferSize = 1024 * self.audioConverter.inputFormat.streamDescription->mBytesPerFrame;
    [self.audioEQEffect installTapOnBus:0 bufferSize:bufferSize format:self.audioConverter.inputFormat block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {
        dispatch_async(self.microphoneQueue, ^{
            [self processMicrophoneBuffer:buffer];
        });
    }];
}

- (void)processMicrophoneBuffer:(AVAudioPCMBuffer *)inputBuffer
{
    static AVAudioPCMBuffer *outputBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.audioConverter.outputFormat frameCapacity:5000];
    outputBuffer.frameLength = 5000;
    
    __block BOOL didReturnBuffer = NO;
    
    NSError *error = nil;
    AVAudioConverterOutputStatus status = [self.audioConverter convertToBuffer:outputBuffer error:&error
                                                            withInputFromBlock:^AVAudioBuffer * _Nullable(AVAudioPacketCount packetCount, AVAudioConverterInputStatus * _Nonnull outStatus) {
        if (didReturnBuffer)
        {
            *outStatus = AVAudioConverterInputStatus_NoDataNow;
            return nil;
        }
        else
        {
            didReturnBuffer = YES;
            *outStatus = AVAudioConverterInputStatus_HaveData;
            return inputBuffer;
        }
    }];

    if (status == AVAudioConverterOutputStatus_Error)
    {
        NSLog(@"Conversion error: %@", error);
    }
    
    NSInteger outputSize = outputBuffer.frameLength * outputBuffer.format.streamDescription->mBytesPerFrame;
    [self.microphoneBuffer writeBuffer:outputBuffer.int16ChannelData[0] size:outputSize];
}

- (void)handleAudioSessionInterruption:(NSNotification *)notification
{
    AVAudioSessionInterruptionType interruptionType = (AVAudioSessionInterruptionType)[notification.userInfo[AVAudioSessionInterruptionTypeKey] integerValue];
    
    switch (interruptionType)
    {
        case AVAudioSessionInterruptionTypeBegan:
        {
            self.microphoneEnabled = NO;
            break;
        }
            
        case AVAudioSessionInterruptionTypeEnded:
        {
            if (self.audioEngine)
            {
                // Only reset audio engine if there is currently an active one.
                [self prepareAudioEngine];
            }
            
            break;
        }
    }
}

#pragma mark - Getters/Setters -

- (NSTimeInterval)frameDuration
{
    return (1.0 / 60.0);
}

- (NSURL *)bios7URL
{
    return [MelonDSEmulatorBridge.coreDirectoryURL URLByAppendingPathComponent:@"bios7.bin"];
}

- (NSURL *)bios9URL
{
    return [MelonDSEmulatorBridge.coreDirectoryURL URLByAppendingPathComponent:@"bios9.bin"];
}

- (NSURL *)firmwareURL
{
    return [MelonDSEmulatorBridge.coreDirectoryURL URLByAppendingPathComponent:@"firmware.bin"];
}

- (NSURL *)dsiBIOS7URL
{
    return [MelonDSEmulatorBridge.coreDirectoryURL URLByAppendingPathComponent:@"dsibios7.bin"];
}

- (NSURL *)dsiBIOS9URL
{
    return [MelonDSEmulatorBridge.coreDirectoryURL URLByAppendingPathComponent:@"dsibios9.bin"];
}

- (NSURL *)dsiFirmwareURL
{
    return [MelonDSEmulatorBridge.coreDirectoryURL URLByAppendingPathComponent:@"dsifirmware.bin"];
}

- (NSURL *)dsiNANDURL
{
    return [MelonDSEmulatorBridge.coreDirectoryURL URLByAppendingPathComponent:@"dsinand.bin"];
}

- (AVAudioConverter *)audioConverter
{
    if (_audioConverter == nil)
    {
        // Lazily initialize so we don't cause microphone permission alert to appear prematurely.
        AVAudioFormat *inputFormat = [_audioEngine.inputNode inputFormatForBus:0];
        AVAudioFormat *outputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:44100 channels:1 interleaved:NO];
        _audioConverter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:outputFormat];
    }
    
    return _audioConverter;
}

@end

namespace Platform
{
    void StopEmu()
    {
        if ([MelonDSEmulatorBridge.sharedBridge isStopping])
        {
            return;
        }
        
        MelonDSEmulatorBridge.sharedBridge.stopping = YES;
        [[NSNotificationCenter defaultCenter] postNotificationName:DLTAEmulatorCore.emulationDidQuitNotification object:nil];
    }
    
    FILE* OpenFile(const std::string& path, const std::string& mode, bool mustexist)
    {
        FILE* ret;
        
        if (mustexist)
        {
            ret = fopen(path.c_str(), "rb");
            if (ret) ret = freopen(path.c_str(), mode.c_str(), ret);
        }
        else
            ret = fopen(path.c_str(), mode.c_str());
        
        return ret;
    }
    
    FILE* OpenLocalFile(const std::string& path, const std::string& mode)
    {
        NSURL *fileURL = [MelonDSEmulatorBridge.coreDirectoryURL URLByAppendingPathComponent:@(path.c_str())];
        return OpenFile(fileURL.fileSystemRepresentation, mode);
    }
    
    FILE* OpenDataFile(const char* path)
    {
        NSString *resourceName = [@(path) stringByDeletingPathExtension];
        NSString *extension = [@(path) pathExtension];
        
        NSURL *fileURL = [MelonDSEmulatorBridge.dsResources URLForResource:resourceName withExtension:extension];
        return OpenFile(fileURL.fileSystemRepresentation, "rb");
    }
    
    Thread* Thread_Create(std::function<void()> func)
    {
        NSThread *thread = [[NSThread alloc] initWithBlock:^{
            func();
        }];
        
        thread.name = @"MelonDS - Rendering";
        thread.qualityOfService = NSQualityOfServiceUserInitiated;
        
        [thread start];
        
        return (Thread *)CFBridgingRetain(thread);
    }
    
    void Thread_Free(Thread *thread)
    {
        NSThread *nsThread = (NSThread *)CFBridgingRelease(thread);
        [nsThread cancel];
    }
    
    void Thread_Wait(Thread *thread)
    {
        NSThread *nsThread = (__bridge NSThread *)thread;
        while (nsThread.isExecuting)
        {
            continue;
        }
    }
    
    Semaphore *Semaphore_Create()
    {
        dispatch_semaphore_t dispatchSemaphore = dispatch_semaphore_create(0);
        return (Semaphore *)CFBridgingRetain(dispatchSemaphore);
    }
    
    void Semaphore_Free(Semaphore *semaphore)
    {
        CFRelease(semaphore);
    }
    
    void Semaphore_Reset(Semaphore *semaphore)
    {
        dispatch_semaphore_t dispatchSemaphore = (__bridge dispatch_semaphore_t)semaphore;
        while (dispatch_semaphore_wait(dispatchSemaphore, DISPATCH_TIME_NOW) == 0)
        {
            continue;
        }
    }
    
    void Semaphore_Wait(Semaphore *semaphore)
    {
        dispatch_semaphore_t dispatchSemaphore = (__bridge dispatch_semaphore_t)semaphore;
        dispatch_semaphore_wait(dispatchSemaphore, DISPATCH_TIME_FOREVER);
    }

    void Semaphore_Post(Semaphore *semaphore, int count)
    {
        dispatch_semaphore_t dispatchSemaphore = (__bridge dispatch_semaphore_t)semaphore;
        for (int i = 0; i < count; i++)
        {
            dispatch_semaphore_signal(dispatchSemaphore);
        }
    }

    Mutex *Mutex_Create()
    {
        // NSLock is too slow for real-time audio, so use pthread_mutex_t directly.
        
        pthread_mutex_t *mutex = (pthread_mutex_t *)malloc(sizeof(pthread_mutex_t));
        pthread_mutex_init(mutex, NULL);
        return (Mutex *)mutex;
    }

    void Mutex_Free(Mutex *m)
    {
        pthread_mutex_t *mutex = (pthread_mutex_t *)m;
        pthread_mutex_destroy(mutex);
        free(mutex);
    }

    void Mutex_Lock(Mutex *m)
    {
        pthread_mutex_t *mutex = (pthread_mutex_t *)m;
        pthread_mutex_lock(mutex);
    }

    void Mutex_Unlock(Mutex *m)
    {
        pthread_mutex_t *mutex = (pthread_mutex_t *)m;
        pthread_mutex_unlock(mutex);
    }
    
    void *GL_GetProcAddress(const char* proc)
    {
        return NULL;
    }
    
    bool MP_Init()
    {
        return false;
    }
    
    void MP_DeInit()
    {
    }
    
    int MP_SendPacket(u8* bytes, int len)
    {
        return 0;
    }
    
    int MP_RecvPacket(u8* bytes, bool block)
    {
        return 0;
    }
    
    bool LAN_Init()
    {
        return false;
    }
    
    void LAN_DeInit()
    {
    }
    
    int LAN_SendPacket(u8* data, int len)
    {
        return 0;
    }
    
    int LAN_RecvPacket(u8* data)
    {
        return 0;
    }

    void Mic_Prepare()
    {
        if (![MelonDSEmulatorBridge.sharedBridge isMicrophoneEnabled] || [MelonDSEmulatorBridge.sharedBridge.audioEngine isRunning])
        {
            return;
        }
        
        NSError *error = nil;
        if (![MelonDSEmulatorBridge.sharedBridge.audioEngine startAndReturnError:&error])
        {
            NSLog(@"Failed to start listening to microphone. %@", error);
        }
    }

std::string GetConfigString(ConfigEntry entry) {
  MelonDSEmulatorBridge* bridge = MelonDSEmulatorBridge.sharedBridge;
  // zhuowei: melonDS updating
  switch (entry) {
    case BIOS7Path:
      return bridge.bios7URL.lastPathComponent.UTF8String;
    case BIOS9Path:
      return bridge.bios9URL.lastPathComponent.UTF8String;
    case FirmwarePath:
      return bridge.firmwareURL.lastPathComponent.UTF8String;
    // TODO(zhuowei): DSi and other paths
    default:
      fprintf(stderr, "GetConfigString not implemented yet!\n");
      return "";
  }
}

bool GetConfigBool(ConfigEntry entry) {
  MelonDSEmulatorBridge* bridge = MelonDSEmulatorBridge.sharedBridge;
  switch (entry) {
#ifdef JIT_ENABLED
    case JIT_Enable:
      return bridge.jitEnabled;
    case JIT_FastMemory:
      return false;
#endif
    default:
      fprintf(stderr, "GetConfigBool not implemented yet!\n");
      return false;
  }
}

bool GetConfigArray(ConfigEntry entry, void* data)
{
  return false;
}

int GetConfigInt(ConfigEntry entry) {
  fprintf(stderr, "GetConfigInt not implemented yet!\n");
  return 0;
}

int InstanceID() {
  return 0;
}

std::string InstanceFileSuffix() {
  return "";
}

void MP_Begin()
{
}

void MP_End()
{
}

int MP_SendAck(u8* data, int len, u64 timestamp)
{
  return -1;
}

int MP_SendCmd(u8* data, int len, u64 timestamp)
{
  return -1;
}

int MP_SendReply(u8* data, int len, u64 timestamp, u16 aid)
{
  return -1;
}

int MP_SendPacket(u8* data, int len, u64 timestamp)
{
  return -1;
}

int MP_RecvPacket(u8* data, u64* timestamp)
{
  return -1;
}

int MP_RecvHostPacket(u8* data, u64* timestamp)
{
  return -1;
}

u16 MP_RecvReplies(u8* data, u64 timestamp, u16 aidmask)
{
  return -1;
}


void Camera_Start(int num)
{
}

void Camera_Stop(int num)
{
}

void Camera_CaptureFrame(int num, u32* frame, int width, int height, bool yuv)
{
}

void WriteNDSSave(const u8* savedata, u32 savelen, u32 writeoffset, u32 writelen)
{
}

void WriteGBASave(const u8* savedata, u32 savelen, u32 writeoffset, u32 writelen)
{
}

void Log(LogLevel level, const char* fmt, ...)
{
    if (fmt == nullptr)
        return;

    va_list args;
    va_start(args, fmt);
    vprintf(fmt, args);
    va_end(args);
}

}
