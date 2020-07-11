#import "RNBraintreeDropIn.h"
#import <React/RCTUtils.h>
#import "BTThreeDSecureRequest.h"
#import "BTPayPalAccountNonce.h"

@implementation RNBraintreeDropIn

- (dispatch_queue_t)methodQueue
{
    return dispatch_get_main_queue();
}
RCT_EXPORT_MODULE(RNBraintreeDropIn)

RCT_EXPORT_METHOD(show:(NSDictionary*)options resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
{

    if([options[@"darkTheme"] boolValue]){
        if (@available(iOS 13.0, *)) {
            BTUIKAppearance.sharedInstance.colorScheme = BTUIKColorSchemeDynamic;
        } else {
            BTUIKAppearance.sharedInstance.colorScheme = BTUIKColorSchemeDark;
        }
    } else {
        BTUIKAppearance.sharedInstance.colorScheme = BTUIKColorSchemeLight;
    }

    if(options[@"fontFamily"]){
        [BTUIKAppearance sharedInstance].fontFamily = options[@"fontFamily"];
    }
    if(options[@"boldFontFamily"]){
        [BTUIKAppearance sharedInstance].boldFontFamily = options[@"boldFontFamily"];
    }

    self.resolve = resolve;
    self.reject = reject;
    self.applePayAuthorized = NO;

    NSString* clientToken = options[@"clientToken"];
    if (!clientToken) {
        reject(@"NO_CLIENT_TOKEN", @"You must provide a client token", nil);
        return;
    }

    BTDropInRequest *request = [[BTDropInRequest alloc] init];
    request.cardDisabled = true;
    request.paypalDisabled = ![options[@"paypal"] boolValue];
    request.applePayDisabled = ![options[@"applePay"] boolValue];

    NSDictionary* threeDSecureOptions = options[@"threeDSecure"];
    if (threeDSecureOptions) {
        NSNumber* threeDSecureAmount = threeDSecureOptions[@"amount"];
        if (!threeDSecureAmount) {
            reject(@"NO_3DS_AMOUNT", @"You must provide an amount for 3D Secure", nil);
            return;
        }

        request.threeDSecureVerification = YES;
        BTThreeDSecureRequest *threeDSecureRequest = [[BTThreeDSecureRequest alloc] init];
        threeDSecureRequest.amount = [NSDecimalNumber decimalNumberWithString:threeDSecureAmount.stringValue];
        
    }

    BTAPIClient *apiClient = [[BTAPIClient alloc] initWithAuthorization:clientToken];
    self.dataCollector = [[BTDataCollector alloc] initWithAPIClient:apiClient];
    [self.dataCollector collectCardFraudData:^(NSString * _Nonnull deviceDataCollector) {
        // Save deviceData
        self.deviceDataCollector = deviceDataCollector;
    }];

    if([options[@"vaultManager"] boolValue]){
        request.vaultManager = YES;
    }

    if([options[@"applePay"] boolValue]){
        NSString* merchantIdentifier = options[@"merchantIdentifier"];
        NSString* countryCode = options[@"countryCode"];
        NSString* currencyCode = options[@"currencyCode"];
        NSString* merchantName = options[@"merchantName"];
        NSDecimalNumber* orderTotal = [NSDecimalNumber decimalNumberWithDecimal:[options[@"orderTotal"] decimalValue]];
        if(!merchantIdentifier || !countryCode || !currencyCode || !merchantName || !orderTotal){
            reject(@"MISSING_OPTIONS", @"Not all required Apple Pay options were provided", nil);
            return;
        }
        self.braintreeClient = [[BTAPIClient alloc] initWithAuthorization:clientToken];

        self.paymentRequest = [[PKPaymentRequest alloc] init];
        self.paymentRequest.merchantIdentifier = merchantIdentifier;
        self.paymentRequest.merchantCapabilities = PKMerchantCapability3DS;
        self.paymentRequest.countryCode = countryCode;
        self.paymentRequest.currencyCode = currencyCode;
        self.paymentRequest.supportedNetworks = @[PKPaymentNetworkAmex, PKPaymentNetworkVisa, PKPaymentNetworkMasterCard, PKPaymentNetworkDiscover, PKPaymentNetworkChinaUnionPay];
        self.paymentRequest.paymentSummaryItems =
            @[
                [PKPaymentSummaryItem summaryItemWithLabel:merchantName amount:orderTotal]
            ];
        if (@available(iOS 11.0, *)) {
            self.paymentRequest.requiredBillingContactFields = [[NSSet<PKContactField> alloc] initWithObjects: PKContactFieldPostalAddress, PKContactFieldEmailAddress, PKContactFieldName, nil];
        } else {
            reject(@"MISSING_OPTIONS", @"Not all required Apple Pay options were provided", nil);
        }
        self.viewController = [[PKPaymentAuthorizationViewController alloc] initWithPaymentRequest: self.paymentRequest];
        self.viewController.delegate = self;
    }else{
        request.applePayDisabled = YES;
    }

    BTDropInController *dropIn = [[BTDropInController alloc] initWithAuthorization:clientToken request:request handler:^(BTDropInController * _Nonnull controller, BTDropInResult * _Nullable result, NSError * _Nullable error) {
            [self.reactRoot dismissViewControllerAnimated:YES completion:nil];

            //result.paymentOptionType == .ApplePay
            //NSLog(@"paymentOptionType = %ld", result.paymentOptionType);

            if (error != nil) {
                reject(error.localizedDescription, error.localizedDescription, error);
            } else if (result.cancelled) {
                reject(@"USER_CANCELLATION", @"The user cancelled", nil);
            } else {
                if(result.paymentMethod == nil && (result.paymentOptionType == 16 || result.paymentOptionType == 18)){ //Apple Pay
                    // UIViewController *ctrl = [[[[UIApplication sharedApplication] delegate] window] rootViewController];
                    // [ctrl presentViewController:self.viewController animated:YES completion:nil];
                    UIViewController *rootViewController = RCTPresentedViewController();
                    [rootViewController presentViewController:self.viewController animated:YES completion:nil];
                } else{
                    [[self class] resolvePayment:result deviceData:self.deviceDataCollector resolver:resolve];
                }
            }
        }];
    [self.reactRoot presentViewController:dropIn animated:YES completion:nil];
}

- (void)paymentAuthorizationViewController:(PKPaymentAuthorizationViewController *)controller
                       didAuthorizePayment:(PKPayment *)payment
                                completion:(void (^)(PKPaymentAuthorizationStatus))completion
{

    // Example: Tokenize the Apple Pay payment
    BTApplePayClient *applePayClient = [[BTApplePayClient alloc]
                                        initWithAPIClient:self.braintreeClient];
    [applePayClient tokenizeApplePayPayment:payment
                                 completion:^(BTApplePayCardNonce *tokenizedApplePayPayment,
                                              NSError *error) {
        if (tokenizedApplePayPayment) {
            // On success, send nonce to your server for processing.
            // If applicable, address information is accessible in `payment`.
            // NSLog(@"description = %@", tokenizedApplePayPayment.localizedDescription);

            completion(PKPaymentAuthorizationStatusSuccess);
            self.applePayAuthorized = YES;


            NSMutableDictionary* result = [NSMutableDictionary new];
            [result setObject:tokenizedApplePayPayment.nonce forKey:@"nonce"];
            [result setObject:@"Apple Pay" forKey:@"type"];
            [result setObject:[NSString stringWithFormat: @"%@ %@", @"", tokenizedApplePayPayment.type] forKey:@"description"];
            [result setObject:[NSNumber numberWithBool:false] forKey:@"isDefault"];
            [result setObject:self.deviceDataCollector forKey:@"deviceData"];
            if(payment.billingContact && payment.billingContact.postalAddress) {
                [result setObject:payment.billingContact.name.givenName forKey:@"firstName"];
                [result setObject:payment.billingContact.name.familyName forKey:@"lastName"];
                if(payment.billingContact.emailAddress) {
                    [result setObject:payment.billingContact.emailAddress forKey:@"email"];
                }
                NSString *street = payment.billingContact.postalAddress.street;
                NSArray *splitArray = [street componentsSeparatedByString:@"\n"];
                [result setObject:splitArray[0] forKey:@"addressLine1"];
                if([splitArray count] > 1 && splitArray[1]) {
                    [result setObject:splitArray[1] forKey:@"addressLine2"];
                }
                [result setObject:payment.billingContact.postalAddress.city forKey:@"city"];
                [result setObject:payment.billingContact.postalAddress.state forKey:@"state"];
                [result setObject:payment.billingContact.postalAddress.ISOCountryCode forKey:@"country"];
                [result setObject:payment.billingContact.postalAddress.postalCode forKey:@"zip1"];
            }
            self.resolve(result);

        } else {
            // Tokenization failed. Check `error` for the cause of the failure.

            // Indicate failure via the completion callback:
            completion(PKPaymentAuthorizationStatusFailure);
        }
    }];
}

// Be sure to implement -paymentAuthorizationViewControllerDidFinish:
- (void)paymentAuthorizationViewControllerDidFinish:(PKPaymentAuthorizationViewController *)controller{
    [self.reactRoot dismissViewControllerAnimated:YES completion:nil];
    if(self.applePayAuthorized == NO){
        self.reject(@"USER_CANCELLATION", @"The user cancelled", nil);
    }
}

+ (void)resolvePayment:(BTDropInResult* _Nullable)result deviceData:(NSString * _Nonnull)deviceDataCollector resolver:(RCTPromiseResolveBlock _Nonnull)resolve {

    NSMutableDictionary* jsResult = [NSMutableDictionary new];
    if(result.paymentOptionType == BTUIKPaymentOptionTypePayPal) {
        BTPayPalAccountNonce *paypalNonce = (BTPayPalAccountNonce *)result.paymentMethod;
        [jsResult setObject:paypalNonce.firstName forKey:@"firstName"];
        [jsResult setObject:paypalNonce.lastName forKey:@"lastName"];
        [jsResult setObject:paypalNonce.email forKey:@"email"];
        [jsResult setObject:paypalNonce.billingAddress.streetAddress forKey:@"addressLine1"];
        if(paypalNonce.billingAddress.extendedAddress != nil) {
            [jsResult setObject:paypalNonce.billingAddress.extendedAddress forKey:@"addressLine2"];
        }
        [jsResult setObject:paypalNonce.billingAddress.locality forKey:@"city"];
        [jsResult setObject:paypalNonce.billingAddress.region forKey:@"state"];
        [jsResult setObject:paypalNonce.billingAddress.countryCodeAlpha2 forKey:@"country"];
        [jsResult setObject:paypalNonce.billingAddress.postalCode forKey:@"zip1"];
    }
    [jsResult setObject:result.paymentMethod.nonce forKey:@"nonce"];
    [jsResult setObject:result.paymentMethod.type forKey:@"type"];
    [jsResult setObject:result.paymentDescription forKey:@"description"];    
    [jsResult setObject:[NSNumber numberWithBool:result.paymentMethod.isDefault] forKey:@"isDefault"];
    [jsResult setObject:deviceDataCollector forKey:@"deviceData"];

    resolve(jsResult);
}

- (UIViewController*)reactRoot {
    UIViewController *root  = [UIApplication sharedApplication].keyWindow.rootViewController;
    UIViewController *maybeModal = root.presentedViewController;

    UIViewController *modalRoot = root;

    if (maybeModal != nil) {
        modalRoot = maybeModal;
    }

    return modalRoot;
}

@end
