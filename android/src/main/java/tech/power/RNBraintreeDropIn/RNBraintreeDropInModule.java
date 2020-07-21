package tech.power.RNBraintreeDropIn;

import android.app.Activity;
import android.content.Intent;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.bridge.ReactMethod;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.bridge.ActivityEventListener;
import com.facebook.react.bridge.BaseActivityEventListener;
import com.facebook.react.bridge.Promise;
import com.braintreepayments.api.dropin.DropInActivity;
import com.braintreepayments.api.dropin.DropInRequest;
import com.braintreepayments.api.dropin.DropInResult;
import com.braintreepayments.api.models.PayPalAccountNonce;
import com.braintreepayments.api.models.PaymentMethodNonce;
import com.braintreepayments.api.models.CardNonce;
import com.braintreepayments.api.models.ThreeDSecureInfo;
import com.braintreepayments.api.models.GooglePaymentRequest;
import com.braintreepayments.api.models.GooglePaymentCardNonce;
import com.braintreepayments.api.models.PostalAddress;
import com.google.android.gms.wallet.TransactionInfo;
import com.google.android.gms.wallet.WalletConstants;

public class RNBraintreeDropInModule extends ReactContextBaseJavaModule {

  private Promise mPromise;
  private static final int DROP_IN_REQUEST = 0x444;

  private boolean isVerifyingThreeDSecure = false;

  public RNBraintreeDropInModule(ReactApplicationContext reactContext) {
    super(reactContext);
    reactContext.addActivityEventListener(mActivityListener);
  }

  @ReactMethod
  public void show(final ReadableMap options, final Promise promise) {
    isVerifyingThreeDSecure = false;

    if (!options.hasKey("clientToken")) {
      promise.reject("NO_CLIENT_TOKEN", "You must provide a client token");
      return;
    }

    Activity currentActivity = getCurrentActivity();
    if (currentActivity == null) {
      promise.reject("NO_ACTIVITY", "There is no current activity");
      return;
    }

    DropInRequest dropInRequest = new DropInRequest().clientToken(options.getString("clientToken"));

    if(options.hasKey("vaultManager")) {
      dropInRequest.vaultManager(options.getBoolean("vaultManager"));
    }

    dropInRequest.collectDeviceData(true);

    if(options.getBoolean("googlePay")){
      GooglePaymentRequest googlePaymentRequest = new GooglePaymentRequest()
        .transactionInfo(TransactionInfo.newBuilder()
          .setTotalPrice(options.getString("orderTotal"))
          .setTotalPriceStatus(WalletConstants.TOTAL_PRICE_STATUS_FINAL)
          .setCurrencyCode(options.getString("currencyCode"))
          .build())
          .emailRequired(true)
          .billingAddressRequired(true)
          .billingAddressFormat(1)
          .googleMerchantId(options.getString("googlePayMerchantId"));

      dropInRequest.googlePaymentRequest(googlePaymentRequest);
    } else {
      dropInRequest.disableGooglePayment();
    }
    
    if(options.hasKey("paypal") && !options.getBoolean("paypal")) {
      dropInRequest.disablePayPal();
    }    

    if (options.hasKey("threeDSecure")) {
      final ReadableMap threeDSecureOptions = options.getMap("threeDSecure");
      if (!threeDSecureOptions.hasKey("amount")) {
        promise.reject("NO_3DS_AMOUNT", "You must provide an amount for 3D Secure");
        return;
      }

      isVerifyingThreeDSecure = true;

      dropInRequest
      .amount(String.valueOf(threeDSecureOptions.getDouble("amount")))
      .requestThreeDSecureVerification(true);
    }

    mPromise = promise;
    currentActivity.startActivityForResult(dropInRequest.getIntent(currentActivity), DROP_IN_REQUEST);
  }

  private final ActivityEventListener mActivityListener = new BaseActivityEventListener() {
    @Override
    public void onActivityResult(Activity activity, int requestCode, int resultCode, Intent data) {
      super.onActivityResult(requestCode, resultCode, data);

      if (requestCode != DROP_IN_REQUEST || mPromise == null) {
        return;
      }

      if (resultCode == Activity.RESULT_OK) {
        DropInResult result = data.getParcelableExtra(DropInResult.EXTRA_DROP_IN_RESULT);
        PaymentMethodNonce paymentMethodNonce = result.getPaymentMethodNonce();
        String deviceData = result.getDeviceData();

        if (isVerifyingThreeDSecure && paymentMethodNonce instanceof CardNonce) {
          CardNonce cardNonce = (CardNonce) paymentMethodNonce;
          ThreeDSecureInfo threeDSecureInfo = cardNonce.getThreeDSecureInfo();
          if (!threeDSecureInfo.isLiabilityShiftPossible()) {
            mPromise.reject("3DSECURE_NOT_ABLE_TO_SHIFT_LIABILITY", "3D Secure liability cannot be shifted");
          } else if (!threeDSecureInfo.isLiabilityShifted()) {
            mPromise.reject("3DSECURE_LIABILITY_NOT_SHIFTED", "3D Secure liability was not shifted");
          } else {
            resolvePayment(paymentMethodNonce, deviceData);
          }
        } else {
          resolvePayment(paymentMethodNonce, deviceData);
        }
      } else if (resultCode == Activity.RESULT_CANCELED) {
        mPromise.reject("USER_CANCELLATION", "The user cancelled");
      } else {
        Exception exception = (Exception) data.getSerializableExtra(DropInActivity.EXTRA_ERROR);
        mPromise.reject(exception.getMessage(), exception.getMessage());
      }

      mPromise = null;
    }
  };

  private final void resolvePayment(PaymentMethodNonce paymentMethodNonce, String deviceData) {
    WritableMap jsResult = Arguments.createMap();
    PostalAddress billingAddress = null;
    if(paymentMethodNonce instanceof PayPalAccountNonce) {
      PayPalAccountNonce payPalAccountNonce = (PayPalAccountNonce) paymentMethodNonce;
      jsResult.putString("firstName", payPalAccountNonce.getFirstName());
      jsResult.putString("lastName", payPalAccountNonce.getLastName());
      jsResult.putString("email", payPalAccountNonce.getEmail());
      billingAddress = payPalAccountNonce.getBillingAddress();
    } else if(paymentMethodNonce instanceof GooglePaymentCardNonce) {
      GooglePaymentCardNonce googlePaymentCardNonce = (GooglePaymentCardNonce) paymentMethodNonce;
      billingAddress = googlePaymentCardNonce.getBillingAddress();
      jsResult.putString("email", googlePaymentCardNonce.getEmail());
      if(billingAddress != null) {
        String name = billingAddress.getRecipientName();
        if(!name.equals("")) {
          jsResult.putString("firstName", name.substring(0, name.lastIndexOf(" ")));
          jsResult.putString("lastName", name.substring(name.lastIndexOf(" ")));
        }
      }
    }
    if(billingAddress != null) {
      jsResult.putString("addressLine1", billingAddress.getStreetAddress());
      jsResult.putString("addressLine2", billingAddress.getExtendedAddress());
      jsResult.putString("city", billingAddress.getLocality());
      jsResult.putString("state", billingAddress.getRegion());
      jsResult.putString("country", billingAddress.getCountryCodeAlpha2());
      jsResult.putString("zip1", billingAddress.getPostalCode());
    }
    jsResult.putString("nonce", paymentMethodNonce.getNonce());
    jsResult.putString("type", paymentMethodNonce.getTypeLabel());
    jsResult.putString("description", paymentMethodNonce.getDescription());
    jsResult.putBoolean("isDefault", paymentMethodNonce.isDefault());
    jsResult.putString("deviceData", deviceData);

    mPromise.resolve(jsResult);
  }

  @Override
  public String getName() {
    return "RNBraintreeDropIn";
  }
}
