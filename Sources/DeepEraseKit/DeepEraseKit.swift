// The Swift Programming Language
// https://docs.swift.org/swift-book
// swift-tools-version:5.5
// VirtualBackgroundKit.swift

import Foundation
import CoreImage
import Vision
import SwiftUI

#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - Public API

/// Main entry point for virtual background functionality
public class DeepEraseKit: ObservableObject {
    // MARK: - Public Properties
    
    /// The resulting processed image with virtual background
    @Published public private(set) var outputImage: PlatformImage?
    
    /// Camera authorization status
    @Published public private(set) var authorizationStatus: AuthorizationStatus = .unknown
    
    /// Currently selected background option
    public private(set) var currentBackground: BackgroundOption = .none {
        didSet {
            processorManager.updateBackground(to: currentBackground)
        }
    }
    
    // MARK: - Private Properties
    private let processorManager: VideoProcessorManager
    
    // MARK: - Initialization
    
    /// Initialize the VirtualBackgroundManager
    /// - Parameter configuration: Optional configuration settings
    public init(configuration: Configuration = Configuration()) {
        self.processorManager = VideoProcessorManager(configuration: configuration)
        
        // Connect publisher from processor to our public property
        processorManager.$outputImage
            .assign(to: &$outputImage)
        
        processorManager.$authorizationStatus
            .assign(to: &$authorizationStatus)
    }
    
    // MARK: - Public Methods
    
    /// Request camera permissions and prepare capture session
    public func prepare() {
        processorManager.checkPermissions()
    }
    
    /// Start capturing and processing video
    public func startCapturing() {
        processorManager.setupSession()
    }
    
    /// Stop capturing video
    public func stopCapturing() {
        processorManager.stopSession()
    }
    
    /// Update the virtual background
    /// - Parameter option: Background option to apply
    public func setBackground(_ option: BackgroundOption) {
        currentBackground = option
    }
    
    /// Toggle between front and back camera
    public func toggleCamera() {
        processorManager.toggleCamera()
    }
}

// MARK: - Public Types

/// Authorization status for camera access
public enum AuthorizationStatus {
    case unknown
    case authorized
    case denied
    case restricted
    case notDetermined
}

/// Configuration options for the virtual background processor
public struct Configuration {
    /// Camera device position to use
    public var preferredCameraPosition: CameraPosition = .front
    
    /// Quality level for person segmentation
    public var segmentationQuality: SegmentationQuality = .balanced
    
    /// Session preset quality
    public var sessionPreset: SessionPreset = .high
    
    public init(
        preferredCameraPosition: CameraPosition = .front,
        segmentationQuality: SegmentationQuality = .balanced,
        sessionPreset: SessionPreset = .high
    ) {
        self.preferredCameraPosition = preferredCameraPosition
        self.segmentationQuality = segmentationQuality
        self.sessionPreset = sessionPreset
    }
}

/// Camera position options
public enum CameraPosition {
    case front
    case back
}

/// Segmentation quality levels
public enum SegmentationQuality {
    case fast
    case balanced
    case accurate
    
    @available(macOS 12.0, *)
    var visionQuality: VNGeneratePersonSegmentationRequest.QualityLevel {
        switch self {
        case .fast: return .fast
        case .balanced: return .balanced
        case .accurate: return .accurate
        }
    }
}

/// Session quality presets
public enum SessionPreset {
    case low
    case medium
    case high
    
    #if canImport(AVFoundation)
    var avPreset: AVCaptureSession.Preset {
        switch self {
        case .low: return .medium
        case .medium: return .high
        case .high: return .high
        }
    }
    #endif
}

/// Background options for virtual backgrounds
public enum BackgroundOption: Equatable {
    case none
    case blur(radius: Float)
    case image(image: PlatformImage)
    case color(color: PlatformColor)
}

// MARK: - Platform abstractions

#if os(iOS)
import UIKit
public typealias PlatformImage = UIImage
public typealias PlatformColor = UIColor
#elseif os(macOS)
import AppKit
public typealias PlatformImage = NSImage
public typealias PlatformColor = NSColor
#endif

// MARK: - Implementation

/// Internal manager for video processing
@available(macOS 12.0, *)
class VideoProcessorManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var outputImage: PlatformImage?
    @Published var authorizationStatus: AuthorizationStatus = .unknown
    
    // MARK: - Private Properties
    private let configuration: Configuration
    private var currentBackground: BackgroundOption = .none
    
    #if canImport(AVFoundation)
    private let captureSession = AVCaptureSession()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "com.virtualbgkit.videoQueue", qos: .userInteractive)
    private var videoOrientation: AVCaptureVideoOrientation = .portrait
    private var currentPosition: CameraPosition
    #endif
    
    private var personSegmentationRequest: VNGeneratePersonSegmentationRequest?
    private let ciContext = CIContext()
    
    // MARK: - Initialization
    init(configuration: Configuration) {
        self.configuration = configuration
        
        #if canImport(AVFoundation)
        self.currentPosition = configuration.preferredCameraPosition
        #endif
        
        super.init()
        
        setupVisionRequest()
        setupOrientationNotifications()
    }
    
    // MARK: - Setup
    
    private func setupVisionRequest() {
        personSegmentationRequest = VNGeneratePersonSegmentationRequest()
        personSegmentationRequest?.qualityLevel = configuration.segmentationQuality.visionQuality
        personSegmentationRequest?.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }
    
    private func setupOrientationNotifications() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateVideoOrientation),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        #endif
    }
    
    // MARK: - Camera Management
    
    func checkPermissions() {
        #if canImport(AVFoundation)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            self.authorizationStatus = .authorized
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.authorizationStatus = granted ? .authorized : .denied
                    if granted {
                        self?.setupSession()
                    }
                }
            }
        case .denied:
            self.authorizationStatus = .denied
        case .restricted:
            self.authorizationStatus = .restricted
        @unknown default:
            self.authorizationStatus = .unknown
        }
        #else
        // On platforms without AVFoundation
        self.authorizationStatus = .denied
        #endif
    }
    
    func setupSession() {
        #if canImport(AVFoundation)
        guard authorizationStatus == .authorized else { return }
        
        captureSession.sessionPreset = configuration.sessionPreset.avPreset
        
        // Clear existing setup
        clearCaptureSession()
        
        // Setup device input
        setupCameraInput()
        
        // Setup video output
        setupVideoOutput()
        
        // Start the session
        videoQueue.async { [weak self] in
            self?.captureSession.startRunning()
        }
        #endif
    }
    
    #if canImport(AVFoundation)
    private func clearCaptureSession() {
        if !captureSession.inputs.isEmpty {
            for input in captureSession.inputs {
                captureSession.removeInput(input)
            }
        }
        
        if !captureSession.outputs.isEmpty {
            for output in captureSession.outputs {
                captureSession.removeOutput(output)
            }
        }
    }
    
    private func setupCameraInput() {
        let position: AVCaptureDevice.Position = currentPosition == .front ? .front : .back
        guard let captureDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: captureDevice) else {
            Logger.error("Failed to get camera device")
            return
        }
        
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }
    }
    
    private func setupVideoOutput() {
        videoDataOutput.setSampleBufferDelegate(self, queue: videoQueue)
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        
        if captureSession.canAddOutput(videoDataOutput) {
            captureSession.addOutput(videoDataOutput)
        }
        
        // Set video orientation
        if let connection = videoDataOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
                videoOrientation = .portrait
            }
            
            if connection.isVideoMirroringSupported && currentPosition == .front {
                connection.isVideoMirrored = true
            }
        }
    }
    #endif
    
    func toggleCamera() {
        #if canImport(AVFoundation)
        currentPosition = currentPosition == .front ? .back : .front
        // Restart session with new camera
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
        setupSession()
        #endif
    }
    
    func stopSession() {
        #if canImport(AVFoundation)
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
        #endif
    }
    
    func updateBackground(to option: BackgroundOption) {
        currentBackground = option
    }
    
    #if os(iOS)
    @objc private func updateVideoOrientation() {
        #if canImport(AVFoundation)
        guard let connection = videoDataOutput.connection(with: .video),
              let newOrientation = AVCaptureVideoOrientation(deviceOrientation: UIDevice.current.orientation),
              newOrientation != videoOrientation else {
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = newOrientation
                self?.videoOrientation = newOrientation
            }
        }
        #endif
    }
    #endif
}

// MARK: - Video Processing
#if canImport(AVFoundation)
extension VideoProcessorManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let request = personSegmentationRequest else {
            return
        }
        
        #if os(iOS)
        // Update orientation if needed
        if case let deviceOrientation = UIDevice.current.orientation,
           let videoOrientation = AVCaptureVideoOrientation(deviceOrientation: deviceOrientation),
           connection.isVideoOrientationSupported {
            connection.videoOrientation = videoOrientation
            self.videoOrientation = videoOrientation
        }
        #endif
        
        // Perform segmentation
        do {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            try handler.perform([request])
            
            guard let maskPixelBuffer = request.results?.first?.pixelBuffer else {
                return
            }
            
            processImageWithMask(originalImage: pixelBuffer, maskBuffer: maskPixelBuffer)
        } catch {
            Logger.error("Failed to perform segmentation: \(error)")
        }
    }
    
    private func processImageWithMask(originalImage: CVPixelBuffer, maskBuffer: CVPixelBuffer) {
        let ciImage = CIImage(cvPixelBuffer: originalImage)
        
        // If no background is set, just show the normal camera feed
        if (currentBackground == .none) {
            DispatchQueue.main.async { [weak self] in
                self?.outputImage = self?.createPlatformImage(from: ciImage)
            }
            return
        }
        
        let maskImage = CIImage(cvPixelBuffer: maskBuffer)
        
        // Scale the mask to match the original image
        let scaleX = ciImage.extent.width / maskImage.extent.width
        let scaleY = ciImage.extent.height / maskImage.extent.height
        let scaledMask = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        // Create background image based on current selection
        let background = createBackgroundImage(for: currentBackground, withOriginalImage: ciImage)
        
        // Blend foreground and background based on mask
        guard let blendFilter = CIFilter(name: "CIBlendWithMask") else {
            return
        }
        
        blendFilter.setValue(ciImage, forKey: kCIInputImageKey)
        blendFilter.setValue(background, forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(scaledMask, forKey: kCIInputMaskImageKey)
        
        guard let outputCIImage = blendFilter.outputImage else {
            return
        }
        
        // Convert to platform image and display
        if let platformImage = createPlatformImage(from: outputCIImage) {
            DispatchQueue.main.async { [weak self] in
                self?.outputImage = platformImage
            }
        }
    }
    
    private func createBackgroundImage(for option: BackgroundOption, withOriginalImage ciImage: CIImage) -> CIImage {
        switch option {
        case .blur(let radius):
            // Use a blurred version of the original as background
            guard let blurFilter = CIFilter(name: "CIGaussianBlur") else {
                return ciImage
            }
            blurFilter.setValue(ciImage, forKey: kCIInputImageKey)
            blurFilter.setValue(radius, forKey: kCIInputRadiusKey)
            return blurFilter.outputImage ?? ciImage
            
        case .image(let bgImage):
            // Convert platform image to CIImage
            #if os(iOS)
            guard let ciBackgroundImage = CIImage(image: bgImage) else {
                return CIImage(color: CIColor(red: 0, green: 0, blue: 1, alpha: 1)).cropped(to: ciImage.extent)
            }
            #else
            guard let cgImage = bgImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return CIImage(color: CIColor(red: 0, green: 0, blue: 1, alpha: 1)).cropped(to: ciImage.extent)
            }
            let ciBackgroundImage = CIImage(cgImage: cgImage)
            #endif
            
            // Calculate scaling to fill the frame while maintaining aspect ratio
            let bgAspect = ciBackgroundImage.extent.width / ciBackgroundImage.extent.height
            let frameAspect = ciImage.extent.width / ciImage.extent.height
            
            var scale: CGFloat
            var xOffset: CGFloat = 0
            var yOffset: CGFloat = 0
            
            if bgAspect > frameAspect {
                // Background is wider, scale to match height
                scale = ciImage.extent.height / ciBackgroundImage.extent.height
                xOffset = (ciImage.extent.width - (ciBackgroundImage.extent.width * scale)) / 2
            } else {
                // Background is taller, scale to match width
                scale = ciImage.extent.width / ciBackgroundImage.extent.width
                yOffset = (ciImage.extent.height - (ciBackgroundImage.extent.height * scale)) / 2
            }
            
            // Apply transformation
            return ciBackgroundImage
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: xOffset, y: yOffset))
                .cropped(to: ciImage.extent)
            
        case .color(let color):
            // Use solid color as background
            #if os(iOS)
            return CIImage(color: CIColor(color: color))
                .cropped(to: ciImage.extent)
            #else
            let ciColor = CIColor(red: CGFloat(color.redComponent),
                                 green: CGFloat(color.greenComponent),
                                 blue: CGFloat(color.blueComponent),
                                 alpha: CGFloat(color.alphaComponent))
            return CIImage(color: ciColor).cropped(to: ciImage.extent)
            #endif
            
        case .none:
            return CIImage(color: CIColor(red: 0, green: 0, blue: 1, alpha: 1))
                .cropped(to: ciImage.extent)
        }
    }
    
    private func createPlatformImage(from ciImage: CIImage) -> PlatformImage? {
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        
        #if os(iOS)
        // Create UIImage with proper orientation
        return UIImage(cgImage: cgImage, scale: 1.0, orientation: getUIImageOrientationFromVideoOrientation())
        #else
        // Create NSImage
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        return NSImage(cgImage: cgImage, size: size)
        #endif
    }
    
    #if os(iOS)
    private func getUIImageOrientationFromVideoOrientation() -> UIImage.Orientation {
        switch videoOrientation {
        case .portrait:
            return currentPosition == .front ? .right : .up
        case .portraitUpsideDown:
            return currentPosition == .front ? .left : .down
        case .landscapeRight:
            return currentPosition == .front ? .down : .right
        case .landscapeLeft:
            return currentPosition == .front ? .up : .left
        @unknown default:
            return .up
        }
    }
    #endif
}
#endif

// MARK: - Platform Extensions

#if os(iOS)
extension AVCaptureVideoOrientation {
    init?(deviceOrientation: UIDeviceOrientation) {
        switch deviceOrientation {
        case .portrait:
            self = .portrait
        case .portraitUpsideDown:
            self = .portraitUpsideDown
        case .landscapeLeft:
            self = .landscapeRight
        case .landscapeRight:
            self = .landscapeLeft
        default:
            return nil
        }
    }
}
#endif

// MARK: - Utility Classes

/// Simple logger for internal operations
enum Logger {
    static func error(_ message: String) {
        #if DEBUG
        print("[VirtualBackgroundKit] ERROR: \(message)")
        #endif
    }
    
    static func info(_ message: String) {
        #if DEBUG
        print("[VirtualBackgroundKit] INFO: \(message)")
        #endif
    }
}
