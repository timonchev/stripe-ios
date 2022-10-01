//
//  PartnerAuthViewController.swift
//  StripeFinancialConnections
//
//  Created by Krisjanis Gaidis on 7/25/22.
//

import Foundation
import UIKit
import AuthenticationServices
@_spi(STP) import StripeUICore
@_spi(STP) import StripeCore

@available(iOSApplicationExtension, unavailable)
protocol PartnerAuthViewControllerDelegate: AnyObject {
    func partnerAuthViewControllerUserDidSelectAnotherBank(_ viewController: PartnerAuthViewController)
    func partnerAuthViewControllerDidRequestToGoBack(_ viewController: PartnerAuthViewController)
    func partnerAuthViewControllerUserDidSelectEnterBankDetailsManually(_ viewController: PartnerAuthViewController)
    func partnerAuthViewController(_ viewController: PartnerAuthViewController, didReceiveTerminalError error: Error)
    func partnerAuthViewController(
        _ viewController: PartnerAuthViewController,
        didCompleteWithAuthSession authSession: FinancialConnectionsAuthorizationSession
    )
}

@available(iOSApplicationExtension, unavailable)
final class PartnerAuthViewController: UIViewController {
    
    private let dataSource: PartnerAuthDataSource
    private var institution: FinancialConnectionsInstitution {
        return dataSource.institution
    }
    weak var delegate: PartnerAuthViewControllerDelegate?
    
    private lazy var establishingConnectionLoadingView: UIView = {
        let establishingConnectionLoadingView = ReusableInformationView(
            iconType: .loading,
            title: STPLocalizedString("Establishing connection", "The title of the loading screen that appears after a user selected a bank. The user is waiting for Stripe to establish a bank connection with the bank."),
            subtitle: STPLocalizedString("Please wait while a connection is established.", "The subtitle of the loading screen that appears after a user selected a bank. The user is waiting for Stripe to establish a bank connection with the bank.")
        )
        establishingConnectionLoadingView.isHidden = true
        return establishingConnectionLoadingView
    }()
    
    init(dataSource: PartnerAuthDataSource) {
        self.dataSource = dataSource
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .customBackgroundColor
        
        showEstablishingConnectionLoadingView(true)
        dataSource
            .createAuthSession()
            .observe(on: .main) { [weak self] result in
                guard let self = self else { return }
                // order is important so be careful of moving
                self.showEstablishingConnectionLoadingView(false)
                switch result {
                case .success(let authorizationSession):
                    self.createdAuthSession(authorizationSession)
                case .failure(let error):
                    self.showErrorView(error)
                }
            }
    }
    
    private func createdAuthSession(_ authorizationSession: FinancialConnectionsAuthorizationSession) {
        let shouldShowPrepane = (authorizationSession.flow?.isOAuth() ?? false)
        if shouldShowPrepane {
            let prepaneView = PrepaneView(
                institutionName: institution.name,
                institutionImageUrl: institution.smallImageUrl,
                partnerName: (authorizationSession.showPartnerDisclosure ?? false) ? authorizationSession.flow?.toInstitutionName() : nil,
                didSelectContinue: { [weak self] in
                    self?.openInstitutionAuthenticationWebView(authorizationSession: authorizationSession)
                }
            )
            view.addAndPinSubview(prepaneView)
        } else {
            // TODO(kgaidis): add a loading spinner?
            openInstitutionAuthenticationWebView(authorizationSession: authorizationSession)
        }
    }
    
    private func showErrorView(_ error: Error) {
        // all Partner Auth errors hide the back button
        // and all errors end up in user having to exit
        // PartnerAuth to try again
        navigationItem.hidesBackButton = true
        
        let errorView: UIView?
        if
            let error = error as? StripeError,
            case .apiError(let apiError) = error,
            let extraFields = apiError.allResponseFields["extra_fields"] as? [String:Any],
            let institutionUnavailable = extraFields["institution_unavailable"] as? Bool,
            institutionUnavailable
        {
            let institutionIconView = InstitutionIconView(size: .large, showWarning: true)
            institutionIconView.setImageUrl(institution.smallImageUrl)
            let primaryButtonConfiguration = ReusableInformationView.ButtonConfiguration(
                title: String.Localized.select_another_bank,
                action: { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.partnerAuthViewControllerUserDidSelectAnotherBank(self)
                }
            )
            if let expectedToBeAvailableAt = extraFields["expected_to_be_available_at"] as? TimeInterval {
                let expectedToBeAvailableDate = Date(timeIntervalSince1970: expectedToBeAvailableAt)
                let dateFormatter = DateFormatter()
                dateFormatter.timeStyle = .short
                let expectedToBeAvailableTimeString = dateFormatter.string(from: expectedToBeAvailableDate)
                errorView = ReusableInformationView(
                    iconType: .view(institutionIconView),
                    title: String(format: STPLocalizedString("%@ is undergoing maintenance", "Title of a screen that shows an error. The error indicates that the bank user selected is currently under maintenance."), institution.name),
                    subtitle: String(format: STPLocalizedString("Maintenance is scheduled to end at %@. Please select another bank or try again later.", "The subtitle/description of a screen that shows an error. The error indicates that the bank user selected is currently under maintenance."), expectedToBeAvailableTimeString),
                    primaryButtonConfiguration: primaryButtonConfiguration
                )
            } else {
                errorView = ReusableInformationView(
                    iconType: .view(institutionIconView),
                    title: String(format: STPLocalizedString("%@ is currently unavailable", "Title of a screen that shows an error. The error indicates that the bank user selected is currently under maintenance."), institution.name),
                    subtitle:  STPLocalizedString("Please enter your bank details manually or select another bank.", "The subtitle/description of a screen that shows an error. The error indicates that the bank user selected is currently under maintenance."),
                    primaryButtonConfiguration: primaryButtonConfiguration,
                    secondaryButtonConfiguration: dataSource.manifest.allowManualEntry ? ReusableInformationView.ButtonConfiguration(
                        title: String.Localized.enter_bank_details_manually,
                        action: { [weak self] in
                            guard let self = self else { return }
                            self.delegate?.partnerAuthViewControllerUserDidSelectEnterBankDetailsManually(self)
                        }
                    ) : nil
                )
            }
        } else {
            // if we didn't get specific errors back, we don't know
            // what's wrong, so show a generic error
            delegate?.partnerAuthViewController(self, didReceiveTerminalError: error)
            errorView = nil
            
            // keep showing the loading view while we transition to
            // terminal error
            showEstablishingConnectionLoadingView(true)
        }
        
        if let errorView = errorView {
            view.addAndPinSubviewToSafeArea(errorView)
        }
    }
    
    private func openInstitutionAuthenticationWebView(authorizationSession: FinancialConnectionsAuthorizationSession) {
        guard let urlString =  authorizationSession.url, let url = URL(string: urlString) else {
            assertionFailure("Expected to get a URL back from authorization session.")
            return
        }
        
        let authSession = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "stripe-auth",
            completionHandler: { [weak self] returnUrl, error in
                guard let self = self else { return }
                if let error = error {
                    print(error)
                    self.navigateBack() // TODO(kgaidis): make sure that this error handling makes sense
                } else {
                    if let returnUrl = returnUrl, returnUrl.absoluteString.hasPrefix("stripe-auth://link-accounts/login") {
                        self.authorizeAuthSession(authorizationSession)
                    } else {
                        print(returnUrl ?? "no return url")
                        // TODO(kgaidis): handle an unexpected return URL
                        self.navigateBack()
                    }
                }
        })
        
        if #available(iOS 13.0, *) {
            authSession.presentationContextProvider = self
            authSession.prefersEphemeralWebBrowserSession = true
        }

        if #available(iOS 13.4, *) {
            if !authSession.canStart {
                // navigate back to bank picker so user can try again
                //
                // this may be an odd way to handle an issue, but trying again
                // is potentially better than forcing user to close the whole
                // auth session
                navigateBack()
                return // skip starting
            }
        }
        
        if !authSession.start() {
            // navigate back to bank picker so user can try again
            //
            // this may be an odd way to handle an issue, but trying again
            // is potentially better than forcing user to close the whole
            // auth session
            navigateBack()
        }
    }
    
    private func authorizeAuthSession(_ authorizationSession: FinancialConnectionsAuthorizationSession) {
        showEstablishingConnectionLoadingView(true)
        dataSource
            .authorizeAuthSession(authorizationSession)
            .observe(on: .main) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success():
                    self.delegate?.partnerAuthViewController(self, didCompleteWithAuthSession: authorizationSession)
                    self.showEstablishingConnectionLoadingView(false)
                case .failure(let error):
                    self.showEstablishingConnectionLoadingView(false) // important to come BEFORE showing error view so we avoid showing back button
                    self.showErrorView(error)
                    assert(self.navigationItem.hidesBackButton)
                }
            }
    }
    
    private func navigateBack() {
        delegate?.partnerAuthViewControllerDidRequestToGoBack(self)
    }
    
    private func showEstablishingConnectionLoadingView(_ show: Bool) {
        if establishingConnectionLoadingView.superview == nil {
            view.addAndPinSubviewToSafeArea(establishingConnectionLoadingView)
        }
        view.bringSubviewToFront(establishingConnectionLoadingView) // bring to front in-case something else is covering it
        
        navigationItem.hidesBackButton = show
        establishingConnectionLoadingView.isHidden = !show
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

/// :nodoc:
@available(iOS 13, *)
@available(iOSApplicationExtension, unavailable)
extension PartnerAuthViewController: ASWebAuthenticationPresentationContextProviding {

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return self.view.window ?? ASPresentationAnchor()
    }
}
