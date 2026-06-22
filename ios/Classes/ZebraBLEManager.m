#import "ZebraBLEManager.h"

@interface ZebraBLEManager()

@property(nonatomic, copy) void (^scanCallback)(NSArray *);
@property(nonatomic, copy) void (^connectCallback)(BOOL, NSString *);
@property(nonatomic, copy) void (^printCallback)(BOOL, NSString *);

@property(nonatomic, strong) NSMutableDictionary<NSString *, CBPeripheral *> *peripheralsById;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *deviceInfoById;

@property(nonatomic, assign) BOOL didReportConnected;

@property(nonatomic, strong) CBUUID *preferredServiceUuid;
@property(nonatomic, strong) CBUUID *preferredCharacteristicUuid;

@property(nonatomic, assign) NSInteger pendingCharacteristicDiscoveryCount;

@property(nonatomic, copy) NSString *pendingConnectDeviceId;
@property(nonatomic, copy) NSString *pendingConnectServiceUuid;
@property(nonatomic, copy) NSString *pendingConnectCharacteristicUuid;

@property(nonatomic, strong) NSArray<NSData *> *pendingWriteChunks;
@property(nonatomic, assign) NSUInteger pendingWriteIndex;
@property(nonatomic, assign) CBCharacteristicWriteType pendingWriteType;
@property(nonatomic, assign) BOOL isPrinting;

// Monotonic tokens used to invalidate stale connect/print watchdog timers so a
// superseded attempt's timeout cannot fire the wrong callback.
@property(nonatomic, assign) NSUInteger connectGeneration;
@property(nonatomic, assign) NSUInteger printGeneration;

// Monotonic token for scan requests, mirroring connectGeneration/printGeneration,
// so a stale scan's 5s completion timer cannot fire after it has been superseded.
@property(nonatomic, assign) NSUInteger scanGeneration;

@end

@implementation ZebraBLEManager

+ (instancetype)shared {
    static ZebraBLEManager *instance = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        instance = [[ZebraBLEManager alloc] init];
    });

    return instance;
}

- (instancetype)init {
    self = [super init];

    if (self) {
        self.discoveredDevices = [[NSMutableArray alloc] init];
        self.peripheralsById = [[NSMutableDictionary alloc] init];
        self.deviceInfoById = [[NSMutableDictionary alloc] init];

        self.centralManager =
        [[CBCentralManager alloc] initWithDelegate:self
                                             queue:nil];
    }

    return self;
}

#pragma mark - Scan

- (void)startScan:(void (^)(NSArray *devices))completion {

    // A second scan must fail-fast the previous one before replacing the
    // single callback slot, otherwise the prior Flutter future hangs to its
    // Dart-side timeout (and the original 5s completion timer, finding
    // scanCallback now pointing at the NEW completion, would incorrectly
    // fire it early while the real new scan is still in progress).
    if (self.scanCallback) {
        void (^previous)(NSArray *) = self.scanCallback;
        self.scanCallback = nil;
        previous(@[]);
    }

    self.scanCallback = completion;

    if (self.centralManager.state == CBManagerStatePoweredOn) {
        [self beginScan];
    } else {
        self.scanGeneration += 1;
        NSUInteger generation = self.scanGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!self.scanCallback || generation != self.scanGeneration) {
                return;
            }
            if (self.centralManager.state == CBManagerStatePoweredOn) {
                [self beginScan];
            } else {
                self.scanCallback(@[]);
                self.scanCallback = nil;
            }
        });
    }
}

#pragma mark - Connect

- (void)connectToDevice:(NSString *)deviceId
            serviceUuid:(NSString *)serviceUuid
     characteristicUuid:(NSString *)characteristicUuid
             completion:(void (^)(BOOL success,
                                  NSString *message))completion {

    self.didReportConnected = NO;
    self.writeCharacteristic = nil;
    self.pendingCharacteristicDiscoveryCount = 0;

    self.preferredServiceUuid = serviceUuid.length > 0 ? [CBUUID UUIDWithString:serviceUuid] : nil;
    self.preferredCharacteristicUuid = characteristicUuid.length > 0 ? [CBUUID UUIDWithString:characteristicUuid] : nil;

    if (deviceId.length == 0) {
        completion(NO, @"Missing deviceId");
        return;
    }

    // A second connect must fail-fast the previous one before replacing the
    // single callback slot, otherwise the prior Flutter future hangs to its
    // Dart-side timeout and its result block leaks.
    if (self.connectCallback) {
        void (^previous)(BOOL, NSString *) = self.connectCallback;
        self.connectCallback = nil;
        previous(NO, @"Superseded by a new connect request");
    }

    self.connectCallback = completion;

    if (self.centralManager.state != CBManagerStatePoweredOn) {
        self.pendingConnectDeviceId = deviceId;
        self.pendingConnectServiceUuid = serviceUuid;
        self.pendingConnectCharacteristicUuid = characteristicUuid;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!self.connectCallback) {
                return;
            }
            if (self.centralManager.state != CBManagerStatePoweredOn &&
                [self.pendingConnectDeviceId isEqualToString:deviceId]) {
                self.pendingConnectDeviceId = nil;
                self.pendingConnectServiceUuid = nil;
                self.pendingConnectCharacteristicUuid = nil;
                self.connectCallback(NO, @"Bluetooth is not powered on");
                self.connectCallback = nil;
            }
        });
        return;
    }

    CBPeripheral *peripheral = self.peripheralsById[deviceId];
    if (!peripheral) {
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:deviceId];
        if (uuid) {
            NSArray<CBPeripheral *> *retrieved =
            [self.centralManager retrievePeripheralsWithIdentifiers:@[uuid]];
            if (retrieved.count > 0) {
                peripheral = retrieved.firstObject;
                self.peripheralsById[deviceId] = peripheral;
            }
        }
    }

    if (!peripheral) {
        self.connectCallback = nil;
        NSUUID *parsed = [[NSUUID alloc] initWithUUIDString:deviceId];
        completion(NO, parsed
                   ? @"Device not found"
                   : @"Invalid BLE identifier — a CoreBluetooth UUID is required (run a scan first)");
        return;
    }

    if (self.connectedPeripheral &&
        ![self.connectedPeripheral.identifier.UUIDString isEqualToString:deviceId]) {
        [self.centralManager cancelPeripheralConnection:self.connectedPeripheral];
    }

    self.connectedPeripheral = peripheral;

    self.connectGeneration += 1;
    NSUInteger generation = self.connectGeneration;

    [self.centralManager connectPeripheral:peripheral
                                   options:@{
        CBConnectPeripheralOptionNotifyOnDisconnectionKey: @YES
    }];

    // CoreBluetooth's connectPeripheral: has NO built-in timeout: if the printer
    // is asleep / out of range, neither didConnectPeripheral nor
    // didFailToConnectPeripheral ever fires. Without this watchdog the connect
    // callback (and the Flutter result it captures) would leak and the peripheral
    // would stay stuck in the connecting state, blocking later reconnects. Fire
    // shorter than the Dart-side timeout so the native side cleans up first.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != self.connectGeneration ||
            self.didReportConnected ||
            !self.connectCallback) {
            return;
        }
        [self.centralManager cancelPeripheralConnection:peripheral];
        self.connectedPeripheral = nil;
        self.writeCharacteristic = nil;
        void (^callback)(BOOL, NSString *) = self.connectCallback;
        self.connectCallback = nil;
        callback(NO, @"Connection timed out");
    });
}

#pragma mark - Disconnect

- (void)disconnect {

    if (self.connectedPeripheral) {

        [self.centralManager cancelPeripheralConnection:
         self.connectedPeripheral];
    }
}

#pragma mark - Print

- (void)printZpl:(NSString *)zpl
      completion:(void (^)(BOOL success,
                           NSString *message))completion {

    if (!self.connectedPeripheral) {

        completion(NO, @"No printer connected");
        return;
    }

    if (!self.writeCharacteristic) {

        completion(NO, @"No writable characteristic");
        return;
    }

    if (self.isPrinting) {
        completion(NO, @"Print already in progress");
        return;
    }

    self.printCallback = completion;

    NSData *data = [zpl dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) {
        self.printCallback = nil;
        completion(NO, @"Empty ZPL data");
        return;
    }

    // Prefer Write WITH response for the multi-KB ZPL raster: each chunk is
    // acknowledged by the peripheral before the next is sent, so reported success
    // reflects confirmed delivery rather than merely draining the local BLE queue.
    // This is the reliable path for the large ^GFA graphic and avoids the
    // intermittent missing-content prints seen with unacknowledged writes. Fall
    // back to write-without-response only when an acknowledged write is unavailable.
    CBCharacteristicProperties properties = self.writeCharacteristic.properties;
    if (properties & CBCharacteristicPropertyWrite) {
        self.pendingWriteType = CBCharacteristicWriteWithResponse;
    } else {
        self.pendingWriteType = CBCharacteristicWriteWithoutResponse;
    }

    NSUInteger maxLen =
    [self.connectedPeripheral maximumWriteValueLengthForType:self.pendingWriteType];
    if (maxLen == 0) {
        maxLen = 20;
    }

    NSMutableArray<NSData *> *chunks = [[NSMutableArray alloc] init];
    NSUInteger offset = 0;
    while (offset < data.length) {
        NSUInteger len = MIN(maxLen, data.length - offset);
        [chunks addObject:[data subdataWithRange:NSMakeRange(offset, len)]];
        offset += len;
    }

    self.pendingWriteChunks = [chunks copy];
    self.pendingWriteIndex = 0;
    self.isPrinting = YES;

    // Guard against a stalled transfer (e.g. an acknowledgement that never
    // arrives) leaving isPrinting stuck YES, which would reject every later print.
    self.printGeneration += 1;
    NSUInteger generation = self.printGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation == self.printGeneration && self.isPrinting) {
            [self finishPrint:NO message:@"Print timed out"];
        }
    });

    if (self.pendingWriteType == CBCharacteristicWriteWithoutResponse) {
        [self pumpWriteWithoutResponse];
    } else {
        [self writeNextChunkWithResponse];
    }
}

#pragma mark - CBCentralManager

- (void)centralManagerDidUpdateState:
(CBCentralManager *)central {

    switch (central.state) {

        case CBManagerStatePoweredOn:
            NSLog(@"Bluetooth ON");
            if (self.scanCallback && !central.isScanning) {
                [self beginScan];
            }
            if (self.pendingConnectDeviceId && self.connectCallback) {
                NSString *deviceId = self.pendingConnectDeviceId;
                NSString *serviceUuid = self.pendingConnectServiceUuid;
                NSString *characteristicUuid = self.pendingConnectCharacteristicUuid;
                // Hand the pending completion off and clear the slot first, so the
                // re-entrant connectToDevice: does not treat it as a "superseded"
                // callback and invoke it twice (which would fatally submit the
                // Flutter result more than once).
                void (^pendingCompletion)(BOOL, NSString *) = self.connectCallback;
                self.pendingConnectDeviceId = nil;
                self.pendingConnectServiceUuid = nil;
                self.pendingConnectCharacteristicUuid = nil;
                self.connectCallback = nil;
                [self connectToDevice:deviceId
                          serviceUuid:serviceUuid
                   characteristicUuid:characteristicUuid
                           completion:pendingCompletion];
            }
            break;

        case CBManagerStatePoweredOff:
            NSLog(@"Bluetooth OFF");
            break;

        default:
            break;
    }
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *,id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {

    NSString *name = peripheral.name;
    NSString *advName = advertisementData[CBAdvertisementDataLocalNameKey];
    if (advName.length > 0) {
        name = advName;
    }
    if (name.length == 0) {
        name = @"Unknown";
    }

    NSString *deviceId = peripheral.identifier.UUIDString;
    if (deviceId.length == 0) {
        return;
    }

    NSMutableDictionary *existing = self.deviceInfoById[deviceId];
    if (existing) {
        existing[@"rssi"] = RSSI;
        return;
    }

    NSMutableDictionary *device = [[NSMutableDictionary alloc] init];
    device[@"name"] = name;
    device[@"id"] = deviceId;
    device[@"rssi"] = RSSI;
    device[@"isLikelyZebra"] = @([self isLikelyZebraPrinterName:name]);

    NSData *manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey];
    if ([manufacturer isKindOfClass:[NSData class]] && manufacturer.length > 0) {
        device[@"manufacturerData"] = [self hexStringFromData:manufacturer];
    }

    NSArray<CBUUID *> *serviceUuids = advertisementData[CBAdvertisementDataServiceUUIDsKey];
    if ([serviceUuids isKindOfClass:[NSArray class]] && serviceUuids.count > 0) {
        NSMutableArray<NSString *> *serviceStrings = [[NSMutableArray alloc] initWithCapacity:serviceUuids.count];
        for (CBUUID *uuid in serviceUuids) {
            [serviceStrings addObject:uuid.UUIDString ?: @""];
        }
        device[@"advertisedServiceUuids"] = [serviceStrings copy];
    }

    [self.discoveredDevices addObject:device];
    self.deviceInfoById[deviceId] = device;
    self.peripheralsById[deviceId] = peripheral;
}

- (void)centralManager:(CBCentralManager *)central
  didConnectPeripheral:(CBPeripheral *)peripheral {

    peripheral.delegate = self;

    if (self.preferredServiceUuid) {
        [peripheral discoverServices:@[self.preferredServiceUuid]];
    } else {
        [peripheral discoverServices:nil];
    }
}

- (void)centralManager:(CBCentralManager *)central
didFailToConnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {

    self.connectedPeripheral = nil;
    self.writeCharacteristic = nil;

    NSString *message = error.localizedDescription ?: @"Failed to connect";
    if (self.connectCallback) {
        self.connectCallback(NO, message);
        self.connectCallback = nil;
    }
}

- (void)centralManager:(CBCentralManager *)central
didDisconnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {

    if (self.connectedPeripheral == peripheral) {
        self.connectedPeripheral = nil;
        self.writeCharacteristic = nil;
    }

    // A disconnect during service/characteristic discovery (before success was
    // reported) must resolve the pending connect, otherwise its Flutter future
    // hangs until the Dart-side timeout.
    if (self.connectCallback && !self.didReportConnected) {
        void (^callback)(BOOL, NSString *) = self.connectCallback;
        self.connectCallback = nil;
        callback(NO, error.localizedDescription ?: @"Disconnected before the printer was ready");
    }
    self.didReportConnected = NO;
    self.pendingCharacteristicDiscoveryCount = 0;

    if (self.isPrinting) {
        [self finishPrint:NO message:@"Disconnected"];
    }
}

#pragma mark - Services

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverServices:(NSError *)error {

    if (error) {
        if (self.connectCallback) {
            self.connectCallback(NO, error.localizedDescription ?: @"Failed to discover services");
            self.connectCallback = nil;
        }
        return;
    }

    NSMutableArray<CBService *> *servicesToExplore = [[NSMutableArray alloc] init];
    for (CBService *service in peripheral.services) {

        NSLog(@"Service %@", service.UUID.UUIDString);

        if (self.preferredServiceUuid &&
            ![service.UUID isEqual:self.preferredServiceUuid]) {
            continue;
        }

        [servicesToExplore addObject:service];
    }

    self.pendingCharacteristicDiscoveryCount = (NSInteger)servicesToExplore.count;
    if (self.pendingCharacteristicDiscoveryCount == 0) {
        if (self.connectCallback) {
            self.connectCallback(NO, @"No services found");
            self.connectCallback = nil;
        }
        return;
    }

    for (CBService *service in servicesToExplore) {
        if (self.preferredCharacteristicUuid) {
            [peripheral discoverCharacteristics:@[self.preferredCharacteristicUuid]
                                     forService:service];
        } else {
            [peripheral discoverCharacteristics:nil
                                     forService:service];
        }
    }
}

#pragma mark - Characteristics

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverCharacteristicsForService:(CBService *)service
             error:(NSError *)error {

    if (error) {
        if (self.connectCallback) {
            self.connectCallback(NO, error.localizedDescription ?: @"Failed to discover characteristics");
            self.connectCallback = nil;
        }
        return;
    }

    if (self.didReportConnected) {
        return;
    }

    for (CBCharacteristic *characteristic
         in service.characteristics) {

        NSLog(@"Characteristic %@",
              characteristic.UUID.UUIDString);

        if (self.preferredCharacteristicUuid &&
            ![characteristic.UUID isEqual:self.preferredCharacteristicUuid]) {
            continue;
        }

        BOOL canWrite = (characteristic.properties & CBCharacteristicPropertyWrite) != 0;
        BOOL canWriteWithoutResponse = (characteristic.properties & CBCharacteristicPropertyWriteWithoutResponse) != 0;
        if (!canWrite && !canWriteWithoutResponse) {
            continue;
        }

        self.writeCharacteristic = characteristic;
        self.didReportConnected = YES;
        self.pendingCharacteristicDiscoveryCount = 0;

        if (self.connectCallback) {

            self.connectCallback(
                YES,
                @"Printer connected"
            );
            self.connectCallback = nil;
        }

        break;
    }

    if (!self.didReportConnected) {
        self.pendingCharacteristicDiscoveryCount -= 1;
        if (self.pendingCharacteristicDiscoveryCount <= 0) {
            if (self.connectCallback) {
                self.connectCallback(NO, @"No writable characteristic found");
                self.connectCallback = nil;
            }
        }
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didWriteValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {

    if (!self.isPrinting) {
        return;
    }

    if (error) {
        [self finishPrint:NO message:(error.localizedDescription ?: @"Write failed")];
        return;
    }

    [self writeNextChunkWithResponse];
}

- (void)peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral *)peripheral {
    if (!self.isPrinting) {
        return;
    }
    [self pumpWriteWithoutResponse];
}

- (void)writeNextChunkWithResponse {
    if (!self.isPrinting) {
        return;
    }

    if (self.pendingWriteIndex >= self.pendingWriteChunks.count) {
        [self finishPrint:YES message:@"Data sent"];
        return;
    }

    NSData *chunk = self.pendingWriteChunks[self.pendingWriteIndex];
    self.pendingWriteIndex += 1;

    [self.connectedPeripheral
        writeValue:chunk
        forCharacteristic:self.writeCharacteristic
        type:CBCharacteristicWriteWithResponse];
}

- (void)pumpWriteWithoutResponse {
    if (!self.isPrinting) {
        return;
    }

    while (self.pendingWriteIndex < self.pendingWriteChunks.count) {
        if (![self.connectedPeripheral canSendWriteWithoutResponse]) {
            return;
        }

        NSData *chunk = self.pendingWriteChunks[self.pendingWriteIndex];
        self.pendingWriteIndex += 1;

        [self.connectedPeripheral
            writeValue:chunk
            forCharacteristic:self.writeCharacteristic
            type:CBCharacteristicWriteWithoutResponse];
    }

    [self finishPrint:YES message:@"Data sent"];
}

- (void)finishPrint:(BOOL)success message:(NSString *)message {
    self.isPrinting = NO;
    self.pendingWriteChunks = nil;
    self.pendingWriteIndex = 0;

    if (self.printCallback) {
        void (^callback)(BOOL, NSString *) = self.printCallback;
        self.printCallback = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            callback(success, message);
        });
    }
}

- (BOOL)isLikelyZebraPrinterName:(NSString *)name {
    NSString *upper = [name uppercaseString];
    if ([upper containsString:@"ZEBRA"]) {
        return YES;
    }

    NSArray<NSString *> *prefixes = @[
        @"ZD", @"ZT", @"ZQ", @"ZR", @"GK", @"GC", @"QLN", @"RW"
    ];
    for (NSString *prefix in prefixes) {
        if ([upper hasPrefix:prefix]) {
            return YES;
        }
    }

    return NO;
}

- (NSString *)hexStringFromData:(NSData *)data {
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    return [hex copy];
}

- (void)beginScan {
    [self.discoveredDevices removeAllObjects];
    [self.peripheralsById removeAllObjects];
    [self.deviceInfoById removeAllObjects];

    // A connected peripheral stops advertising, so didDiscoverPeripheral: will
    // never fire for it during this scan. Re-seed it manually so it doesn't
    // disappear from the list just because it's already connected — otherwise
    // there is no way to see/disconnect it once it falls off the scan list.
    if (self.connectedPeripheral) {
        NSString *deviceId = self.connectedPeripheral.identifier.UUIDString;
        NSString *name = self.connectedPeripheral.name.length > 0 ? self.connectedPeripheral.name : @"Unknown";

        NSMutableDictionary *device = [[NSMutableDictionary alloc] init];
        device[@"name"] = name;
        device[@"id"] = deviceId;
        device[@"isLikelyZebra"] = @([self isLikelyZebraPrinterName:name]);
        device[@"isConnected"] = @YES;

        [self.discoveredDevices addObject:device];
        self.deviceInfoById[deviceId] = device;
        self.peripheralsById[deviceId] = self.connectedPeripheral;
    }

    if (self.centralManager.isScanning) {
        [self.centralManager stopScan];
    }

    [self.centralManager scanForPeripheralsWithServices:nil
                                                options:@{
        CBCentralManagerScanOptionAllowDuplicatesKey: @NO
    }];

    self.scanGeneration += 1;
    NSUInteger generation = self.scanGeneration;

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(5 * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{

        if (generation != self.scanGeneration) {
            return;
        }

        [self.centralManager stopScan];

        if (self.scanCallback) {
            self.scanCallback([self.discoveredDevices copy]);
            self.scanCallback = nil;
        }

    });
}

@end