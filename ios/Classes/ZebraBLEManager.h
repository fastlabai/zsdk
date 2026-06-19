#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>

@interface ZebraBLEManager : NSObject<CBCentralManagerDelegate, CBPeripheralDelegate>

@property(nonatomic, strong) CBCentralManager *centralManager;
@property(nonatomic, strong) NSMutableArray *discoveredDevices;
@property(nonatomic, strong) CBPeripheral *connectedPeripheral;
@property(nonatomic, strong) CBCharacteristic *writeCharacteristic;

+ (instancetype)shared;

- (void)startScan:(void (^)(NSArray *devices))completion;
- (void)connectToDevice:(NSString *)deviceId
            serviceUuid:(NSString *)serviceUuid
     characteristicUuid:(NSString *)characteristicUuid
             completion:(void (^)(BOOL success, NSString *message))completion;

- (void)disconnect;

- (void)printZpl:(NSString *)zpl
      completion:(void (^)(BOOL success, NSString *message))completion;

@end
