//
//  AuthenticationSessionManager.swift
//  StripeFinancialConnections
//
//  Created by Vardges Avetisyan on 12/3/21.
//

import AuthenticationServices
@_spi(STP) import StripeCore
import UIKit

final class AuthenticationSessionManager: NSObject {

    // MARK: - Types

    enum Result {
        case success(returnUrl: URL)
        case webCancelled
        case nativeCancelled
        case redirect(url: URL)
    }

    // MARK: - Properties

    private var authSession: ASWebAuthenticationSession?
    private let manifest: FinancialConnectionsSessionManifest
    private var window: UIWindow?

    // MARK: - Init

    init(manifest: FinancialConnectionsSessionManifest, window: UIWindow?) {
        self.manifest = manifest
        self.window = window
    }

    // MARK: - Public

    func start(additionalQueryParameters: String? = nil) -> Promise<AuthenticationSessionManager.Result> {
        let promise = Promise<AuthenticationSessionManager.Result>()

        guard let hostedAuthUrl = manifest.hostedAuthUrl else {
            promise.reject(with: FinancialConnectionsSheetError.unknown(debugDescription: "NULL `hostedAuthUrl`"))
            return promise
        }

        let urlString = hostedAuthUrl + (additionalQueryParameters ?? "")

        guard let url = URL(string: urlString) else {
            promise.reject(with: FinancialConnectionsSheetError.unknown(debugDescription: "Malformed hosted auth URL"))
            return promise
        }

        guard let successUrl = manifest.successUrl else {
            promise.reject(with: FinancialConnectionsSheetError.unknown(debugDescription: "NULL `successUrl`"))
            return promise
        }
        
//        print("url before", url)
        
//        var urlBuilder = URLComponents(string: url.absoluteString)
//        let queryItem = URLQueryItem(
//            name: "return_payment_method",
//            value: "true"
//        )
//        urlBuilder?.queryItems?.append(queryItem)
//        guard let url = URL(string: url.absoluteString.appending("&return_payment_method=true")) else {
//            promise.reject(with: FinancialConnectionsSheetError.unknown(debugDescription: "Malformed hosted auth URL"))
//            return promise
//        }
//        print("url after", url)

        let authSession = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: URL(string: successUrl)?.scheme,
            completionHandler: { [weak self] returnUrl, error in
                guard let self = self else { return }
                if let error = error {
                    if let authenticationSessionError = error as? ASWebAuthenticationSessionError {
                        switch authenticationSessionError.code {
                        case .canceledLogin:
                            promise.resolve(with: .nativeCancelled)
                        default:
                            promise.reject(with: authenticationSessionError)
                        }
                    } else {
                        promise.reject(with: error)
                    }
                    return
                }
                guard let returnUrl = returnUrl else {
                    promise.reject(with: FinancialConnectionsSheetError.unknown(debugDescription: "Missing return URL"))
                    return
                }
                let returnUrlString = returnUrl.absoluteString
                
                // `matchesSchemeHostAndPath` is necessary for instant debits which
                // contains additional query parameters at the end of the `successUrl`
                if returnUrl.matchesSchemeHostAndPath(of: URL(string: self.manifest.successUrl ?? ""))  {
                    promise.resolve(with: .success(returnUrl: returnUrl))
                } else if  returnUrl.matchesSchemeHostAndPath(of: URL(string: self.manifest.cancelUrl ?? ""))  {
                    promise.resolve(with: .webCancelled)
                } else if returnUrlString.hasNativeRedirectPrefix,
                    let targetURL = URL(string: returnUrlString.droppingNativeRedirectPrefix())
                {
                    promise.resolve(with: .redirect(url: targetURL))
                } else {
                    promise.reject(with: FinancialConnectionsSheetError.unknown(debugDescription: "Nil return URL"))
                }
                
//                if self.manifest.isProductInstantDebits {
//                    if returnUrl.matchesSchemeHostAndPath(of: URL(string: successUrl)) {
//                        if let paymentMethodID = Self.extractValue(from: returnUrl, key: "payment_method_id") {
//                            print(paymentMethodID)
//                            promise.resolve(with: .success)
////                            let details = RedactedPaymentDetails(paymentMethodID: paymentMethodID,
////                                                                 bankName: Self.extractValue(from: returnUrl, key: "bank_name")?.replacingOccurrences(of: "+", with: " "),
////                                                                 bankIconCode: Self.extractValue(from: returnUrl, key: "bank_icon_code"),
////                                                                 last4: Self.extractValue(from: returnUrl, key: "last4"))
////                            promise.fullfill(with: .success(.success(details: details)))
//                        } else {
//                            promise.reject(with: FinancialConnectionsSheetError.unknown(debugDescription: "no payment method id"))
//                        }
//                    } else if returnUrl.matchesSchemeHostAndPath(of: URL(string: manifest.cancelUrl ?? "")) {
//                        promise.resolve(with: .webCancelled)
//                    } else {
//                        promise.reject(with: FinancialConnectionsSheetError.unknown(debugDescription: "Nil return URL"))
//                    }
            }
        )
        authSession.presentationContextProvider = self
        authSession.prefersEphemeralWebBrowserSession = true

        self.authSession = authSession
        if #available(iOS 13.4, *) {
            if !authSession.canStart {
                promise.reject(
                    with: FinancialConnectionsSheetError.unknown(debugDescription: "Failed to start session")
                )
                return promise
            }
        }
        /**
         This terribly hacky animation disabling is needed to control the presentation of ASWebAuthenticationSession underlying view controller.
         Since we present a modal already that itself presents ASWebAuthenticationSession, the double modal animation is jarring and a bad UX.
         We disable animations for a second. Sometimes there is a delay in creating the ASWebAuthenticationSession underlying view controller
         to be safe, I made the delay a full second. I didn't find a good way to make this approach less clowny.
         PresentedViewController is not KVO compliant and the notifications sent by presentation view controller that could help with knowing when
         ASWebAuthenticationSession underlying view controller finished presenting are considered private API.
         */
        let animationsEnabledOriginalValue = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)

        if !authSession.start() {
            UIView.setAnimationsEnabled(animationsEnabledOriginalValue)
            promise.reject(with: FinancialConnectionsSheetError.unknown(debugDescription: "Failed to start session"))
            return promise
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            UIView.setAnimationsEnabled(animationsEnabledOriginalValue)
        }

        return promise
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

/// :nodoc:

extension AuthenticationSessionManager: ASWebAuthenticationPresentationContextProviding {

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return self.window ?? ASPresentationAnchor()
    }
}

extension URL {

    fileprivate func matchesSchemeHostAndPath(of otherURL: URL?) -> Bool {
        guard let otherURL = otherURL else {
            return false
        }
        return (
            self.scheme == otherURL.scheme &&
            self.host == otherURL.host &&
            self.path == otherURL.path
        )
    }
}
