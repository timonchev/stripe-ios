//
//  DocumentScanner.swift
//  StripeIdentity
//
//  Created by Mel Ludowise on 11/9/21.
//  Copyright © 2021 Stripe, Inc. All rights reserved.
//

import CoreVideo
@_spi(STP) import StripeCameraCore
@_spi(STP) import StripeCore
import Vision

typealias AnyDocumentScanner = AnyImageScanner<DocumentScannerOutput?>

/// Scans a camera feed for a valid identity document.

final class DocumentScanner {

    // MARK: Detectors

    private let idDetector: IDDetector
    private let motionBlurDetector: MotionBlurDetector
    private let barcodeDetector: BarcodeDetector?
    private let blurDetector: LaplacianBlurDetector
    private let highResImageCropPadding: CGFloat
    private let mbDetector: MBDetector?
    private let analyticsClient: IdentityAnalyticsClient
    private var hasSeenMBRunnerError: Bool = false
    private let sheetController: VerificationSheetControllerProtocol
    private var shouldStartScan: Bool = false
    private var scheduledAsync: Bool = false
    static let delayStart: DispatchTimeInterval = .seconds(3)

    /// Initializes a DocumentScanner with detectors.
    ///
    /// - Parameters:
    ///   - idDetector: The IDDetector to classify document images.
    ///   - motionBlurDetector: A motion blur detector to determine if the frame is blurry.
    ///   - barcodeDetector: A barcode detector
    init(
        idDetector: IDDetector,
        motionBlurDetector: MotionBlurDetector,
        barcodeDetector: BarcodeDetector?,
        blurDetector: LaplacianBlurDetector,
        mbDetector: MBDetector?,
        highResImageCropPadding: CGFloat,
        sheetController: VerificationSheetControllerProtocol
    ) {
        self.idDetector = idDetector
        self.motionBlurDetector = motionBlurDetector
        self.barcodeDetector = barcodeDetector
        self.blurDetector = blurDetector
        self.mbDetector = mbDetector
        self.highResImageCropPadding = highResImageCropPadding
        self.analyticsClient = sheetController.analyticsClient
        self.sheetController = sheetController
    }

    convenience init(
        idDetectorModel: VNCoreMLModel,
        configuration: Configuration,
        sheetController: VerificationSheetControllerProtocol
    ) {
        self.init(
            idDetector: IDDetector(
                model: idDetectorModel,
                configuration: .init(
                    minScore: configuration.idDetectorMinScore,
                    minIOU: configuration.idDetectorMinIOU
                )
            ),
            motionBlurDetector: MotionBlurDetector(
                minIOU: configuration.motionBlurMinIOU,
                minTime: configuration.motionBlurMinDuration
            ),
            barcodeDetector: configuration.backIdCardBarcodeSymbology.map {
                BarcodeDetector(
                    configuration: .init(
                        symbology: $0,
                        timeout: configuration.backIdCardBarcodeTimeout
                    )
                )
            },
            blurDetector: LaplacianBlurDetector(blurThreshold: configuration.blurThreshold),
            mbDetector: {
                if let mbSettings = configuration.mbSettings {
                    do {
                        let ret = try MBDetector(mbSettings: mbSettings)
                        sheetController.analyticsClient.logMbStatus(required: true, init_success: true, sheetController: sheetController)
                        return ret
                    } catch {
                        if case MBDetector.MBDetectorError.incorrectLicense(let reason) = error {
                            sheetController.analyticsClient.logMbStatus(required: true, init_success: false, init_failed_reason: reason, sheetController: sheetController)
                        } else {
                            sheetController.analyticsClient.logMbStatus(required: true, init_success: false, init_failed_reason: error.localizedDescription, sheetController: sheetController)
                        }
                        return nil
                    }
                } else {
                    sheetController.analyticsClient.logMbStatus(required: false, sheetController: sheetController)
                    return nil
                }
            }(),
            highResImageCropPadding: configuration.highResImageCorpPadding,
            sheetController: sheetController
        )
    }
}

extension DocumentScanner: ImageScanner {
    typealias Output = DocumentScannerOutput?

    var mlModelMetricsTrackers: [MLDetectorMetricsTrackerProtocol] {
        return [idDetector].compactMap { $0.metricsTracker }
    }

    func scanImage(
        pixelBuffer: CVPixelBuffer,
        sampleBuffer: CMSampleBuffer,
        cameraProperties: CameraSession.DeviceProperties?
    ) -> Future<DocumentScannerOutput?> {
        if !self.shouldStartScan {
            if !self.scheduledAsync {
                self.scheduledAsync = true
                DispatchQueue.main.asyncAfter(deadline: .now() + DocumentScanner.delayStart) { [weak self] in
                    self?.shouldStartScan = true
                }
            }
            return Promise(value: nil)
        }
        do {
            // Scan for ID Document Classification
            guard let idDetectorOutput = try self.idDetector.scanImage(pixelBuffer: pixelBuffer) else {
                return Promise(value: nil)
            }

            if self.hasSeenMBRunnerError { // If MBMBCCAnalyzerRunnerError occurs before, don't try use MB again, directly fallback to legacy
                return scanImageLegacy(pixelBuffer: pixelBuffer, idDetectorOutput: idDetectorOutput, cameraProperties: cameraProperties)
            } else { // MB is available, and never throws any MBCCAnalyzerRunnerError, attempt to use MB
                if let mbDetector { // MBDetector available, use modern
                    return mbDetector.analyze(sampleBuffer: sampleBuffer).chained { mbResult in
                        if case .error(let mbError) = mbResult {
                            self.analyticsClient.logMbError(error: mbError, sheetController: self.sheetController)
                            if case .runnerError = mbError {
                                self.hasSeenMBRunnerError = true
                            }
                            return self.scanImageLegacy(pixelBuffer: pixelBuffer, idDetectorOutput: idDetectorOutput, cameraProperties: cameraProperties)
                        } else {
                            return self.scanImageModern(pixelBuffer: pixelBuffer, idDetectorOutput: idDetectorOutput, cameraProperties: cameraProperties, mbResult: mbResult)
                        }
                    }
                } else { // MBDetector not avaialbe, fallback to legacy
                    return scanImageLegacy(pixelBuffer: pixelBuffer, idDetectorOutput: idDetectorOutput, cameraProperties: cameraProperties)
                }
            }
        } catch {
            return Promise(error: error)
        }
    }

    fileprivate func processCommonResults(
        pixelBuffer: CVPixelBuffer,
        idDetectorOutput: IDDetectorOutput,
        cameraProperties: CameraSession.DeviceProperties?
    ) throws -> (motionBlurOutput: MotionBlurDetector.Output, barcodeOutput: BarcodeDetectorOutput?, blurResult: LaplacianBlurDetector.Output)  {
        // Check for motion blur
        let motionBlurOutput = motionBlurDetector.determineMotionBlur(
            documentBounds: idDetectorOutput.documentBounds
        )

        // If there's motion blur, reset the timer on the barcode detector.
        // Otherwise, scan for a barcode if this is the back of an ID.
        var barcodeOutput: BarcodeDetectorOutput?
        if let barcodeDetector = self.barcodeDetector,
           idDetectorOutput.classification == .idCardBack
        {
            barcodeOutput = try barcodeDetector.scanImage(
                pixelBuffer: pixelBuffer,
                regionOfInterest: idDetectorOutput.documentBounds
            )
        }

        let blurResult: LaplacianBlurDetector.Output = try {
            let originalImage = pixelBuffer.cgImage()
            guard let croppedImage = try originalImage?.cropping(
                toNormalizedRegion: idDetectorOutput.documentBounds,
                withPadding: highResImageCropPadding,
                computationMethod: .maxImageWidthOrHeight
            )
            else {
                return LaplacianBlurDetector.defaultOutput
            }
            return blurDetector.calculateBlurOutput(inputImage: croppedImage)
        }()

        return (motionBlurOutput, barcodeOutput, blurResult)
    }

    fileprivate func scanImageLegacy(
        pixelBuffer: CVPixelBuffer,
        idDetectorOutput: IDDetectorOutput,
        cameraProperties: CameraSession.DeviceProperties?
    ) -> Future<DocumentScannerOutput?> {
        do {
            let commonOutputs = try processCommonResults(pixelBuffer: pixelBuffer, idDetectorOutput: idDetectorOutput, cameraProperties: cameraProperties)
            return Promise(value: DocumentScannerOutput.legacy(
                idDetectorOutput,
                commonOutputs.barcodeOutput,
                commonOutputs.motionBlurOutput,
                cameraProperties,
                commonOutputs.blurResult
            ))
        } catch {
            return Promise(error: error)
        }
    }

    fileprivate func scanImageModern(
        pixelBuffer: CVPixelBuffer,
        idDetectorOutput: IDDetectorOutput,
        cameraProperties: CameraSession.DeviceProperties?,
        mbResult: MBDetector.DetectorResult
    ) -> Future<DocumentScannerOutput?> {
        do {
            let commonOutputs = try processCommonResults(pixelBuffer: pixelBuffer, idDetectorOutput: idDetectorOutput, cameraProperties: cameraProperties)
            return Promise(value: DocumentScannerOutput.modern(
                idDetectorOutput,
                commonOutputs.barcodeOutput,
                commonOutputs.motionBlurOutput,
                cameraProperties,
                commonOutputs.blurResult,
                mbResult
            ))
        } catch {
            return Promise(error: error)
        }
    }

    func reset() {
        motionBlurDetector.reset()
        barcodeDetector?.reset()
        idDetector.metricsTracker?.reset()
        mbDetector?.reset()
        shouldStartScan = false
        scheduledAsync = false
    }
}

extension IDDetectorOutput.Classification {
    /// Determines if the classification output by the IDDetector matches the
    /// scanner's desired classification.
    ///
    /// - Parameters:
    ///   - side: The desired document side
    ///
    /// - Returns: True if this classification matches the desired classification.
    func matchesDocument(
        side: DocumentSide
    ) -> Bool {
        switch (side, self) {
        case (.front, .idCardFront),
            (.front, .passport),
            (.back, .idCardBack):
            return true
        default:
            return false
        }
    }
}
