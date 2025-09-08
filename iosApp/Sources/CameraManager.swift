import AVFoundation
import Vision
import SwiftUI
import Combine

struct DataMatrixResult {
    let data: String
    let quality: String
    let timestamp: String
    let parsedData: [String: String]
    let hologramDetections: [HologramDetection] // Add hologram detection results
}

class CameraManager: NSObject, ObservableObject {
    @Published var lastDetection: DataMatrixResult?
    @Published var guidanceMessage: String = "Initializing intelligent camera system..."
    @Published var currentZoomFactor: CGFloat = 1.0
    @Published var detectedHolograms: [HologramDetection] = [] // For UI overlay
    
    let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    
    // Ensure we configure the session only once to avoid crashes from duplicate inputs/outputs
    private var isConfigured: Bool = false
    
    private var lastScanTime: Date = Date.distantPast
    private let scanCooldown: TimeInterval = 1.0
    private var detectionCount = 0
    
    // Intelligent analysis components
    private let distanceAnalyzer = IntelligentDistanceAnalyzer()
    private let hologramDetector = HologramDetector() // Add hologram detection
    private var currentDevice: AVCaptureDevice?
    private var lastDistanceAnalysis: DistanceGuidance = .analyzing
    private var zoomAdjustmentCount = 0
    private let maxZoomAdjustments = 10
    
    // Enhanced focus control
    private var focusRetryCount = 0
    private let maxFocusRetries = 5
    private var lastFocusAdjustmentTime: Date = Date.distantPast
    private let focusAdjustmentInterval: TimeInterval = 2.0 // Minimum time between focus adjustments
    private var isManualFocusMode = false
    
    override init() {
        super.init()
        setupHighResolutionCamera()
    }
    
    private func setupHighResolutionCamera() {
        // Ensure we have camera permission before configuring the session to avoid launch crashes
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            sessionQueue.async { [weak self] in
                self?.configureHighResolutionSession()
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self = self else { return }
                if granted {
                    self.sessionQueue.async {
                        self.configureHighResolutionSession()
                        // Do not auto-start here; the view controls starting to avoid race/double-start
                    }
                } else {
                    DispatchQueue.main.async {
                        self.guidanceMessage = "Camera permission denied. Enable access in Settings to scan FarmaTag codes."
                    }
                }
            }
        default:
            // .denied, .restricted, or future cases
            DispatchQueue.main.async { [weak self] in
                self?.guidanceMessage = "Camera access not allowed. Please enable it in Settings > Privacy > Camera."
            }
        }
    }
    
    private func configureHighResolutionSession() {
        // Prevent duplicate configuration
        if isConfigured { return }
        
        captureSession.beginConfiguration()
        
        // Set highest resolution for iPhone 15
        if captureSession.canSetSessionPreset(.hd4K3840x2160) {
            captureSession.sessionPreset = .hd4K3840x2160
            print("✅ Using 4K resolution for optimal data matrix scanning")
        } else if captureSession.canSetSessionPreset(.hd1920x1080) {
            captureSession.sessionPreset = .hd1920x1080
            print("✅ Using 1080p resolution for data matrix scanning")
        } else {
            captureSession.sessionPreset = .high
        }
        
        // Get the best camera available (iPhone 15 main camera)
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let cameraInput = try? AVCaptureDeviceInput(device: camera),
              captureSession.canAddInput(cameraInput) else {
            print("❌ Failed to setup high-resolution camera input")
            captureSession.commitConfiguration()
            return
        }
        
        // APPLE NATIVE CAMERA POWER - Maximum Sharpness Configuration
        do {
            try camera.lockForConfiguration()
            
            // 1. SELECT HIGHEST QUALITY FORMAT (like Camera.app)
            let bestFormat = selectBestCameraFormat(for: camera)
            if let format = bestFormat {
                camera.activeFormat = format
                print("📷 [v2.3] NATIVE: Set highest quality format")
            }
            
            // 2. APPLE'S NATIVE AUTO-FOCUS (Maximum Power)
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
                if camera.isAutoFocusRangeRestrictionSupported {
                    camera.autoFocusRangeRestriction = .none  // No restrictions
                }
                
                // Enable Apple's subject area monitoring
                camera.isSubjectAreaChangeMonitoringEnabled = true
                
                // Set optimal focus point
                if camera.isFocusPointOfInterestSupported {
                    camera.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                }

                if camera.isSmoothAutoFocusSupported {
                    camera.isSmoothAutoFocusEnabled = true
                }
                
                print("📷 [v2.3] NATIVE: Apple's continuous auto-focus enabled")
            }
            
            // 3. MAXIMUM EXPOSURE QUALITY
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
                
                if camera.isExposurePointOfInterestSupported {
                    camera.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
                }
                
                // Set optimal exposure for data matrix scanning
                if camera.activeFormat.isVideoHDRSupported {
                    camera.isVideoHDREnabled = false  // Disable HDR for sharper text
                }
                
                print("📷 [v2.3] NATIVE: Maximum exposure quality enabled")
            }
            
            // 4. OPTIMAL WHITE BALANCE
            // if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            //     camera.whiteBalanceMode = .continuousAutoWhiteBalance
            //     print("📷 [v2.3] NATIVE: Continuous auto white balance enabled")
            // }
            
            // // Enable image stabilization if available
            // if camera.activeFormat.isVideoStabilizationModeSupported(.auto) {
            //     // Will be set on connection
            // }
            
            camera.unlockForConfiguration()
        } catch {
            print("⚠️ Could not configure camera settings: \(error)")
        }
        
        captureSession.addInput(cameraInput)
        currentDevice = camera // Store reference for zoom and focus control
        
        // Add subject area change notification for focus adjustments
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(subjectAreaDidChange),
            name: .AVCaptureDeviceSubjectAreaDidChange,
            object: camera
        )
        
        // Configure high-resolution video output
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }
        
        // Configure connection for optimal scanning
        if let connection = videoOutput.connection(with: .video) {
            connection.videoOrientation = .portrait
            
            // Enable video stabilization for iPhone 15
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
        }
        
        captureSession.commitConfiguration()
        
        DispatchQueue.main.async { [weak self] in
            self?.guidanceMessage = "🇲🇾 Malaysian FarmaTag Scanner v2.3 - NATIVE Apple Camera Power!"
            print("✅ CAMERA SETUP COMPLETE v2.1: Malaysian FarmaTag detection with FIXED auto-focus")
        }
        
        // Mark as configured to avoid reconfiguration
        isConfigured = true
    }
    
    func startSession() {
        print("🚀 STARTING CAMERA SESSION...")
        sessionQueue.async { [weak self] in
            if let self = self, !self.captureSession.isRunning {
                print("📸 Starting capture session...")
                self.captureSession.startRunning()
                print("✅ HIGH-RESOLUTION CAMERA SESSION STARTED - Hologram detection active")
                
                // Update UI message
                DispatchQueue.main.async {
                    self.guidanceMessage = "🎯 Point camera at Malaysian FarmaTag hologram"
                }
                
                // Verify session is actually running
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if self.captureSession.isRunning {
                        print("✅ CAMERA SESSION CONFIRMED RUNNING")
                    } else {
                        print("❌ CAMERA SESSION FAILED TO START")
                    }
                }
            } else {
                print("⏰ Camera session already running or self is nil")
            }
        }
    }
    
    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.captureSession.isRunning {
                // Remove observers before stopping
                NotificationCenter.default.removeObserver(self, name: .AVCaptureDeviceSubjectAreaDidChange, object: self.currentDevice)
                
                // Detach delegate to avoid callbacks after stop (crash-safe)
                self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
                
                self.captureSession.stopRunning()
                print("🛑 Camera session stopped")
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        // Perform intelligent distance analysis with ML (optional)
        // performIntelligentDistanceAnalysis(pixelBuffer)
        
        // Perform hologram detection in parallel
        performHologramDetection(pixelBuffer)
        
        // High-resolution Vision processing optimized for data matrices
        let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        
        // Create optimized barcode detection request for pharmaceutical data matrices
        let barcodeRequest = VNDetectBarcodesRequest { [weak self] request, error in
            self?.handleHighResolutionBarcodeDetection(request: request, error: error)
        }
        
        // Configure specifically for data matrix detection with high accuracy
        barcodeRequest.symbologies = [.dataMatrix, .qr]
        if #available(iOS 15.0, *) {
            barcodeRequest.revision = VNDetectBarcodesRequestRevision2 // Latest revision for best accuracy
        }
        
        do {
            try requestHandler.perform([barcodeRequest])
        } catch {
            print("❌ High-resolution Vision request failed: \(error)")
        }
    }
    
    private func handleHighResolutionBarcodeDetection(request: VNRequest, error: Error?) {
        guard error == nil,
              let observations = request.results as? [VNBarcodeObservation],
              !observations.isEmpty else {
            
            DispatchQueue.main.async { [weak self] in
                self?.updateGuidanceForNoDetection()
            }
            return
        }
        
        if let observation = observations.first {
            let boundingBox = observation.boundingBox
            let center = CGPoint(x: boundingBox.midX, y: boundingBox.midY)
            focusAtPoint(center)
        }

        // Process all detected barcodes (there might be multiple on pharmaceutical packaging)
        for observation in observations {
            if let payloadString = observation.payloadStringValue,
               !payloadString.isEmpty {
                
                let quality = assessHighResolutionQuality(observation: observation)
                let timestamp = DateFormatter.pharmaceuticalTimestamp.string(from: Date())
                let parsedData = parsePharmaceuticalData(payloadString)
                
                // Get current hologram detections to include with the result
                let currentHolograms = hologramDetector.getRecentDetections()
                
                let result = DataMatrixResult(
                    data: payloadString,
                    quality: quality,
                    timestamp: timestamp,
                    parsedData: parsedData,
                    hologramDetections: currentHolograms
                )
                
                DispatchQueue.main.async { [weak self] in
                    self?.processDetectedResult(result)
                }
                
                // Only process the first high-quality detection to avoid spam
                if quality == "EXCELLENT" || quality == "GOOD" {
                    break
                }
            }
        }
    }
    
    private func assessHighResolutionQuality(observation: VNBarcodeObservation) -> String {
        let confidence = observation.confidence
        let dataLength = observation.payloadStringValue?.count ?? 0
        let boundingBoxArea = observation.boundingBox.width * observation.boundingBox.height
        
        // More stringent quality assessment for high-resolution iPhone 15 camera
        switch true {
        case confidence > 0.95 && dataLength > 15 && boundingBoxArea > 0.008:
            return "EXCELLENT"
        case confidence > 0.85 && dataLength > 10 && boundingBoxArea > 0.005:
            return "GOOD"
        case confidence > 0.7 && dataLength > 5:
            return "POOR"
        default:
            return "UNREADABLE"
        }
    }
    
    private func parsePharmaceuticalData(_ data: String) -> [String: String] {
        // Robust GS1 parser for common AIs used in serialized pharma GTINs
        // Handles fixed-length and variable-length AIs and FNC1 (ASCII 29)
        var parsed: [String: String] = [:]
        let fnc1: Character = Character(UnicodeScalar(29)) // Group Separator if present
        let input = data
        
        // Known AIs with fixed length (value length, excluding AI)
        let fixedLengthAIs: [String: Int] = [
            "01": 14, // GTIN-14
            "17": 6,  // Expiry YYMMDD
            "11": 6   // Production YYMMDD
        ]
        // Variable length AIs we'll support
        let variableAIs: Set<String> = ["10", "21", "240", "90"]
        let allAIs: [String] = ["01", "10", "11", "17", "21", "240", "90"]
        
        var i = input.startIndex
        while i < input.endIndex {
            // Need at least 2 characters for an AI
            guard input.distance(from: i, to: input.endIndex) >= 2 else { break }
            let ai = String(input[i..<input.index(i, offsetBy: 2)])
            
            if let fixedLen = fixedLengthAIs[ai] {
                let valueStart = input.index(i, offsetBy: 2)
                let valueEnd = input.index(valueStart, offsetBy: fixedLen, limitedBy: input.endIndex) ?? input.endIndex
                let value = String(input[valueStart..<valueEnd])
                switch ai {
                case "01": parsed["GTIN"] = value
                case "17": parsed["Expiry"] = formatGS1Date(value)
                case "11": parsed["Production Date"] = formatGS1Date(value)
                default: break
                }
                i = valueEnd
            } else if variableAIs.contains(ai) {
                let valueStart = input.index(i, offsetBy: 2)
                // Value continues until FNC1 (if present) or next AI or end
                var j = valueStart
                var nextIndex: String.Index? = nil
                while j < input.endIndex {
                    let ch = input[j]
                    if ch == fnc1 { nextIndex = j; break }
                    // Check if a next AI starts here
                    if input.distance(from: j, to: input.endIndex) >= 2 {
                        let possibleAI = String(input[j..<input.index(j, offsetBy: 2)])
                        if allAIs.contains(possibleAI) { nextIndex = j; break }
                    }
                    j = input.index(after: j)
                }
                let valueEnd = nextIndex ?? input.endIndex
                let value = String(input[valueStart..<valueEnd])
                switch ai {
                case "10": parsed["Batch"] = value
                case "21": parsed["Serial"] = value
                case "240": parsed["Additional ID"] = value
                case "90": parsed["Internal Code"] = value
                default: break
                }
                // Skip FNC1 if at valueEnd
                i = valueEnd
                if i < input.endIndex, input[i] == fnc1 { i = input.index(after: i) }
            } else {
                // Not a recognized AI at this position – advance by one
                i = input.index(after: i)
            }
        }
        
        // Derive manufacturer info from GTIN if possible
        if let gtin = parsed["GTIN"], gtin.count >= 3 {
            let prefix3 = String(gtin.prefix(3))
            parsed["Manufacturer Country"] = countryFromGS1Prefix(prefix3)
            // Very rough manufacturer code guess: first 7 digits of GTIN-14 (not standards-accurate)
            parsed["Manufacturer Code (guess)"] = String(gtin.prefix(min(7, gtin.count)))
        }
        
        return parsed
    }
    
    private func formatGS1Date(_ yymmdd: String) -> String {
        guard yymmdd.count == 6 else { return yymmdd }
        let year = "20" + String(yymmdd.prefix(2))
        let month = String(yymmdd.dropFirst(2).prefix(2))
        let day = String(yymmdd.suffix(2))
        return "\(day)/\(month)/\(year)"
    }
    
    private func countryFromGS1Prefix(_ prefix3: String) -> String {
        // Minimal mapping for demonstration; extend as needed
        // Source: GS1 prefix allocations (simplified)
        if let p = Int(prefix3) {
            switch p {
            case 000...019: return "USA & Canada"
            case 030...039: return "USA"
            case 040...049: return "USA"
            case 050...059: return "Coupons (USA)"
            case 060...139: return "USA & Canada"
            case 380: return "Bulgaria"
            case 383: return "Slovenia"
            case 385: return "Croatia"
            case 387: return "Bosnia and Herzegovina"
            case 400...440: return "Germany"
            case 450...459, 490...499: return "Japan"
            case 460...469: return "Russia"
            case 471: return "Taiwan"
            case 474: return "Estonia"
            case 475: return "Latvia"
            case 476: return "Azerbaijan"
            case 477: return "Lithuania"
            case 478: return "Uzbekistan"
            case 479: return "Sri Lanka"
            case 480: return "Philippines"
            case 481: return "Belarus"
            case 482: return "Ukraine"
            case 484: return "Moldova"
            case 485: return "Armenia"
            case 486: return "Georgia"
            case 487: return "Kazakhstan"
            case 489: return "Hong Kong"
            case 500...509: return "UK"
            case 520: return "Greece"
            case 528: return "Lebanon"
            case 529: return "Cyprus"
            case 531: return "Macedonia"
            case 535: return "Malta"
            case 539: return "Ireland"
            case 540...549: return "Belgium & Luxembourg"
            case 560: return "Portugal"
            case 569: return "Iceland"
            case 570...579: return "Denmark"
            case 590: return "Poland"
            case 594: return "Romania"
            case 599: return "Hungary"
            case 600...601: return "South Africa"
            case 603: return "Ghana"
            case 608: return "Bahrain"
            case 609: return "Mauritius"
            case 611: return "Morocco"
            case 613: return "Algeria"
            case 615: return "Nigeria"
            case 616: return "Kenya"
            case 618: return "Côte d’Ivoire"
            case 619: return "Tunisia"
            case 620: return "Tanzania"
            case 622: return "Egypt"
            case 624: return "Libya"
            case 625: return "Jordan"
            case 626: return "Iran"
            case 627: return "Kuwait"
            case 628: return "Saudi Arabia"
            case 629: return "United Arab Emirates"
            case 640...649: return "Finland"
            case 690...699: return "China"
            case 700...709: return "Norway"
            case 729: return "Israel"
            case 730...739: return "Sweden"
            case 740: return "Guatemala"
            case 741: return "El Salvador"
            case 742: return "Honduras"
            case 743: return "Nicaragua"
            case 744: return "Costa Rica"
            case 745: return "Panama"
            case 746: return "Dominican Republic"
            case 750: return "Mexico"
            case 754...755: return "Canada"
            case 759: return "Venezuela"
            case 760...769: return "Switzerland"
            case 770...771: return "Colombia"
            case 773: return "Uruguay"
            case 775: return "Peru"
            case 777: return "Bolivia"
            case 778...779: return "Argentina"
            case 780: return "Chile"
            case 784: return "Paraguay"
            case 786: return "Ecuador"
            case 789...790: return "Brazil"
            case 800...839: return "Italy"
            case 840...849: return "Spain"
            case 850: return "Cuba"
            case 858: return "Slovakia"
            case 859: return "Czech Republic"
            case 860: return "Serbia"
            case 865: return "Mongolia"
            case 867: return "North Korea"
            case 868...869: return "Turkey"
            case 870...879: return "Netherlands"
            case 880: return "South Korea"
            case 884: return "Cambodia"
            case 885: return "Thailand"
            case 888: return "Singapore"
            case 890: return "India"
            case 893: return "Vietnam"
            case 896: return "Pakistan"
            case 899: return "Indonesia"
            case 900...919: return "Austria"
            case 930...939: return "Australia"
            case 940...949: return "New Zealand"
            case 955: return "Malaysia"
            case 958: return "Macau"
            default: return "Unknown"
            }
        }
        return "Unknown"
    }
    
    private func processDetectedResult(_ result: DataMatrixResult) {
        guard shouldProcessNewScan() else { return }
        
        lastDetection = result
        detectionCount += 1
        
        let qualityMessage = switch result.quality {
        case "EXCELLENT": "✅ Excellent scan quality - Data captured!"
        case "GOOD": "✅ Good scan quality - Data captured!"
        case "POOR": "⚠️ Poor quality - Move closer or improve lighting"
        default: "❌ Unreadable - Adjust position and lighting"
        }
        
        guidanceMessage = "\(result.data)"
        
        // Enhanced logging for pharmaceutical scan with hologram authentication
        if result.quality == "EXCELLENT" || result.quality == "GOOD" {
            let hologramInfo = result.hologramDetections.isEmpty ? "" : 
                " (+ \(result.hologramDetections.count) hologram\(result.hologramDetections.count > 1 ? "s" : ""))"
            print("📊 Pharmaceutical data matrix scanned (#\(detectionCount))\(hologramInfo): \(String(result.data.prefix(30)))...")
            
            if !result.parsedData.isEmpty {
                print("📋 Parsed pharmaceutical data: \(result.parsedData)")
            }
            
            // Log hologram authentication details
            let pharmaceuticalHolograms = result.hologramDetections.filter { $0.hologramType == .pharmaceutical }
            if !pharmaceuticalHolograms.isEmpty {
                print("🌈 Pharmaceutical authentication: \(pharmaceuticalHolograms.count) hologram\(pharmaceuticalHolograms.count > 1 ? "s" : "") verified")
                for (index, hologram) in pharmaceuticalHolograms.enumerated() {
                    print("• Hologram \(index + 1): Confidence \(String(format: "%.1f", hologram.confidence * 100))%, Reflectance \(String(format: "%.2f", hologram.reflectiveIntensity))")
                }
            }
        }
    }
    
    private func updateGuidanceForNoDetection() {
        let guidance = [
            "🎯 Center the data matrix in the camera view",
            "📱 Move closer to the pharmaceutical label", 
            "💡 Ensure adequate lighting on the label",
            "🔍 Hold steady and focus on the data matrix",
            "📐 Keep camera parallel to the label surface"
        ]
        
        guidanceMessage = guidance.randomElement() ?? "Position camera over pharmaceutical data matrix"
    }
    
    private func shouldProcessNewScan() -> Bool {
        let now = Date()
        defer { lastScanTime = now }
        return now.timeIntervalSince(lastScanTime) >= scanCooldown
    }
    
    // MARK: - Hologram Detection
    
    private func performHologramDetection(_ pixelBuffer: CVPixelBuffer) {
        // Run hologram detection on background thread to avoid blocking camera
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            
            print("🔍 HOLOGRAM: Starting detection analysis...")
            let detections = self.hologramDetector.detectHolograms(in: pixelBuffer)
            print("🎯 HOLOGRAM: Detection complete, found \(detections.count) holograms")
            
            // ALWAYS Update UI on main thread - whether holograms detected or not
            DispatchQueue.main.async {
                print("📱 HOLOGRAM: Updating UI with \(detections.count) detections")
                self.detectedHolograms = detections
                
                if !detections.isEmpty {
                    self.updateGuidanceForHologramDetection(detections)
                } else {
                    // Clear old detections if no holograms found recently
                    let recentDetections = self.hologramDetector.getRecentDetections()
                    if recentDetections.isEmpty {
                        print("📭 HOLOGRAM: No recent detections, clearing UI")
                    } else {
                        print("🕐 HOLOGRAM: Keeping recent detections (\(recentDetections.count))")
                    }
                }
            }
        }
    }
    
    private func updateGuidanceForHologramDetection(_ detections: [HologramDetection]) {
        let pharmaceuticalHolograms = detections.filter { $0.hologramType == .pharmaceutical }
        
        if !pharmaceuticalHolograms.isEmpty {
            let highestConfidence = pharmaceuticalHolograms.max(by: { $0.confidence < $1.confidence })
            if let best = highestConfidence, best.confidence > 0.8 {
                guidanceMessage = "🌈 Pharmaceutical hologram detected! Focus on data matrix code"
            } else {
                guidanceMessage = "🔍 Possible hologram detected - position for better view"
            }
        } else if !detections.isEmpty {
            guidanceMessage = "⭐ Holographic element detected - look for data matrix"
        }
    }
    
    // MARK: - Intelligent Auto-Zoom & ML Distance Analysis
    
    private func performIntelligentDistanceAnalysis(_ pixelBuffer: CVPixelBuffer) {
        // Run ML analysis on background thread to avoid blocking camera
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            
            let distanceGuidance = self.distanceAnalyzer.analyzeDistance(from: pixelBuffer)
            
            // Only proceed if guidance changed to avoid constant adjustments
            if distanceGuidance != self.lastDistanceAnalysis {
                self.lastDistanceAnalysis = distanceGuidance
                
                DispatchQueue.main.async {
                    self.guidanceMessage = distanceGuidance.message
                    self.performIntelligentAutoZoom(based: distanceGuidance)
                    
                    // Handle blur detection for enhanced focus control
                    if distanceGuidance == .tooClose {
                        // If detected as too close due to blur, attempt focus adjustment
                        let analysisDetails = self.distanceAnalyzer.getAnalysisDetails()
                        if analysisDetails.contains("Laplacian variance (blur)") {
                            // Extract blur metric and attempt focus correction
                            // COMPLETELY DISABLED: Using iPhone Camera.app auto-focus only
                            print("🔍 [v2.2] Blur detected but using natural Camera.app auto-focus - NO interference")
                        }
                    }
                }
            }
        }
    }
    
    private func performIntelligentAutoZoom(based guidance: DistanceGuidance) {
        guard let device = currentDevice,
              device.activeFormat.videoMaxZoomFactor > 1.0,
              zoomAdjustmentCount < maxZoomAdjustments else {
            return
        }
        
        let currentZoom = device.videoZoomFactor
        var targetZoom = currentZoom
        
        // Enhanced zoom adjustment with focus coordination
        switch guidance {
        case .tooFar:
            // Zoom in to get closer to the pharmaceutical label
            targetZoom = min(currentZoom * 1.3, device.activeFormat.videoMaxZoomFactor)
            print("🔍 AI Auto-Zoom: Zooming in from \(String(format: "%.1f", currentZoom))x to \(String(format: "%.1f", targetZoom))x")
            
            // Post-zoom focus is now handled by applyIntelligentZoom with coordinateFocus
            
        case .tooClose:
            // Zoom out to capture the full data matrix
            targetZoom = max(currentZoom * 0.8, 1.0)
            print("🔍 AI Auto-Zoom: Zooming out from \(String(format: "%.1f", currentZoom))x to \(String(format: "%.1f", targetZoom))x")
            
            // Post-zoom focus is now handled by applyIntelligentZoom with coordinateFocus
            
        case .perfect:
            // Perfect distance - lock focus if possible
            print("✅ AI Analysis: Perfect distance achieved at \(String(format: "%.1f", currentZoom))x zoom")
            attemptFocusLock()
            return
            
        default:
            // No adjustment needed for other states
            return
        }
        
        // Apply smooth zoom adjustment with enhanced focus coordination
        applyIntelligentZoom(targetZoom, device: device, coordinateFocus: true)
    }
    
    private func applyIntelligentZoom(_ targetZoom: CGFloat, device: AVCaptureDevice, coordinateFocus: Bool = false) {
        do {
            try device.lockForConfiguration()
            
            // Enhanced zoom transition with focus coordination
            if coordinateFocus {
                // Pre-adjust focus before zoom change to minimize blur during transition
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                    if device.isAutoFocusRangeRestrictionSupported {
                        device.autoFocusRangeRestriction = .near
                    }
                    
                    // Set focus point to center for consistent data matrix detection
                    let centerPoint = CGPoint(x: 0.5, y: 0.5)
                    if device.isFocusPointOfInterestSupported {
                        device.focusPointOfInterest = centerPoint
                    }
                }
            }
            
            // Smooth zoom transition with adaptive rate based on zoom change magnitude
            let zoomDifference = abs(targetZoom - device.videoZoomFactor)
            let rampRate = zoomDifference > 1.0 ? 1.5 : 2.5 // Slower for large changes, faster for fine adjustments
            device.ramp(toVideoZoomFactor: targetZoom, withRate: Float(rampRate))
            
            device.unlockForConfiguration()
            
            // Update published zoom factor for UI
            DispatchQueue.main.async { [weak self] in
                self?.currentZoomFactor = targetZoom
            }
            
            zoomAdjustmentCount += 1
            
            print("🎯 Enhanced Zoom: Applied \(String(format: "%.1f", targetZoom))x with focus coordination (adjustment #\(zoomAdjustmentCount))")
            
            // Coordinate post-zoom focus adjustment with improved timing
            if coordinateFocus {
                let focusDelay = zoomDifference > 1.0 ? 1.2 : 0.8 // Longer delay for significant zoom changes
                DispatchQueue.main.asyncAfter(deadline: .now() + focusDelay) { [weak self] in
                    self?.attemptFocusAdjustment(reason: "post-zoom-coordination")
                }
            }
            
        } catch {
            print("❌ Enhanced zoom failed: \(error)")
        }
    }
    
    // MARK: - iPhone Camera.app Style Focus Control
    
    func focusAtPoint(_ point: CGPoint) {
        guard let device = currentDevice else {
            print("❌ [v2.2] Tap-to-focus failed: No camera device")
            return
        }
        
        do {
            try device.lockForConfiguration()
            
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
            }
            
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
            }
            
            device.unlockForConfiguration()
            
        } catch {
            print("❌ [v2.2] Tap-to-focus configuration failed: \(error)")
        }
    }
    
    private func resetToContinuousAutoFocus() {
        guard let device = currentDevice else { return }
        
        do {
            try device.lockForConfiguration()
            
            // Return to continuous auto-focus (like Camera.app)
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
                if device.isAutoFocusRangeRestrictionSupported {
                    device.autoFocusRangeRestriction = .none
                }
            }
            
            // Return to continuous auto-exposure
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            
            device.unlockForConfiguration()
            print("📷 [v2.2] Returned to continuous auto-focus (like Camera.app)")
            
        } catch {
            print("❌ [v2.2] Reset to continuous auto-focus failed: \(error)")
        }
    }
    
    // MARK: - Enhanced Focus Control Methods (DISABLED in v2.2)
    
    private func attemptFocusAdjustment(reason: String) {
        guard let device = currentDevice,
              Date().timeIntervalSince(lastFocusAdjustmentTime) >= focusAdjustmentInterval,
              focusRetryCount < maxFocusRetries else {
            return
        }
        
        lastFocusAdjustmentTime = Date()
        focusRetryCount += 1
        
        do {
            try device.lockForConfiguration()
            
            if device.isFocusModeSupported(.continuousAutoFocus) && !isManualFocusMode {
                device.focusMode = .continuousAutoFocus
                if device.isAutoFocusRangeRestrictionSupported {
                    device.autoFocusRangeRestriction = .near // Optimize for pharmaceutical close-up scanning
                }
                
                // Enhanced focus point selection for data matrix detection
                let focusPoint = CGPoint(x: 0.5, y: 0.5) // Center focus for data matrix
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = focusPoint
                }
                
                // Set exposure point to match focus point for consistent lighting
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = focusPoint
                }
                
                print("🎯 Focus Adjustment (\(reason)): Enhanced continuous auto-focus with near range and center point")
            } else if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
                
                // Enhanced focus point configuration for pharmaceutical scanning
                let centerPoint = CGPoint(x: 0.5, y: 0.5)
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = centerPoint
                }
                
                // Coordinate exposure with focus for optimal data matrix visibility
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = centerPoint
                }
                
                print("🎯 Focus Adjustment (\(reason)): Enhanced auto-focus at center with exposure coordination")
            }
            
            device.unlockForConfiguration()
            
        } catch {
            print("❌ Focus adjustment failed (\(reason)): \(error)")
        }
    }
    
    private func attemptFocusLock() {
        guard let device = currentDevice else { return }
        
        do {
            try device.lockForConfiguration()
            
            if device.isFocusModeSupported(.locked) {
                // Lock focus at current position since we have perfect distance
                device.focusMode = .locked
                isManualFocusMode = true
                print("🔒 Focus Lock: Locked focus at optimal distance for data matrix scanning")
            }
            
            device.unlockForConfiguration()
            
        } catch {
            print("❌ Focus lock failed: \(error)")
        }
    }
    
    private func attemptManualFocus(lensPosition: Float) {
        guard let device = currentDevice,
              device.isLockingFocusWithCustomLensPositionSupported,
              Date().timeIntervalSince(lastFocusAdjustmentTime) >= 0.5 else { // Reduced minimum interval for manual focus
            return
        }
        
        lastFocusAdjustmentTime = Date()
        focusRetryCount += 1
        
        do {
            try device.lockForConfiguration()
            
            // Enhanced manual focus with completion tracking
            device.setFocusModeLocked(lensPosition: lensPosition) { [weak self] focusTime in
                DispatchQueue.main.async {
                    print("📏 Manual Focus: Set lens position to \(lensPosition) (completion time: \(focusTime))")
                    
                    // Brief delay before next focus attempt to allow stabilization
                    self?.lastFocusAdjustmentTime = Date()
                }
            }
            
            isManualFocusMode = true
            device.unlockForConfiguration()
            
            // Reset to auto-focus after manual focus sequence completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.resetToAutoFocusIfNeeded()
            }
            
        } catch {
            print("❌ Manual focus failed: \(error)")
        }
    }
    
    private func resetToAutoFocusIfNeeded() {
        guard let device = currentDevice,
              isManualFocusMode,
              focusRetryCount >= maxFocusRetries else {
            return
        }
        
        do {
            try device.lockForConfiguration()
            
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
                if device.isAutoFocusRangeRestrictionSupported {
                    device.autoFocusRangeRestriction = .near
                }
                isManualFocusMode = false
                print("🔄 Reset to continuous auto-focus after manual focus sequence")
            }
            
            device.unlockForConfiguration()
            
        } catch {
            print("❌ Failed to reset to auto-focus: \(error)")
        }
    }
    
    private func handleBlurDetection() {
        guard let device = currentDevice else {
            print("❌ Blur detection failed: No camera device available")
            return
        }
        
        let timeSinceLastAdjustment = Date().timeIntervalSince(lastFocusAdjustmentTime)
        if timeSinceLastAdjustment < focusAdjustmentInterval {
            print("⏰ Blur detected but focus adjustment too recent (\(String(format: "%.1f", timeSinceLastAdjustment))s ago)")
            return
        }
        
        print("🌫️ BLUR DETECTED: Starting aggressive focus correction sequence...")
        
        // Immediate debug info
        print("📷 Camera info: zoom=\(device.videoZoomFactor), focusMode=\(device.focusMode.rawValue)")
        
        // Enhanced coordination between auto-focus and manual focus attempts
        attemptFocusAdjustment(reason: "blur-detection-immediate")
        
        // Improved timing and coordination for manual focus fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self,
                  self.focusRetryCount < self.maxFocusRetries else { return }
            
            // Check if auto-focus succeeded before trying manual positions
            let analysisDetails = self.distanceAnalyzer.getAnalysisDetails()
            if analysisDetails.contains("Laplacian variance (blur)") {
                let laplacianMatch = analysisDetails.range(of: "Laplacian variance \\(blur\\): ([0-9.]+)",
                                                         options: .regularExpression)
                if let match = laplacianMatch {
                    let laplacianValue = Double(String(analysisDetails[match]).components(separatedBy: ": ")[1]) ?? 0
                    
                    // Only proceed with manual focus if still significantly blurry
                    if laplacianValue < 75 {
                        self.tryOptimalManualFocusPositions()
                    }
                }
            } else {
                // Fallback: try manual focus positions if analysis unavailable
                self.tryOptimalManualFocusPositions()
            }
        }
    }
    
    private func tryOptimalManualFocusPositions() {
        // Improved manual focus positioning with better timing coordination
        let optimalPositions: [Float] = [0.85, 0.75, 0.9, 0.7, 0.6] // Extended range for better results
        
        for (index, position) in optimalPositions.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.6) { [weak self] in
                guard let self = self,
                      self.focusRetryCount < self.maxFocusRetries else { return }
                
                self.attemptManualFocus(lensPosition: position)
                
                // Add brief pause after each manual focus attempt for stabilization
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    // Focus position has been set, allow time for stabilization
                }
            }
        }
    }
    
    @objc private func subjectAreaDidChange(_ notification: Notification) {
        // Reset focus when subject area changes (user moves phone significantly)
        print("📱 Subject area changed - resetting focus for optimal data matrix scanning")
        attemptFocusAdjustment(reason: "subject-area-change")
    }
    
    // Reset zoom adjustment counter and focus state when user manually interacts or new session starts
    func resetIntelligentZoom() {
        zoomAdjustmentCount = 0
        focusRetryCount = 0
        isManualFocusMode = false
        lastDistanceAnalysis = .analyzing
        lastFocusAdjustmentTime = Date.distantPast
        
        // Reset camera to auto-focus mode
        if let device = currentDevice {
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                    if device.isAutoFocusRangeRestrictionSupported {
                        device.autoFocusRangeRestriction = .none
                    }
                }
                device.unlockForConfiguration()
            } catch {
                print("⚠️ Failed to reset focus mode: \(error)")
            }
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.currentZoomFactor = 1.0
        }
        
        print("🔄 AI Auto-Zoom & Focus: Reset for new pharmaceutical scanning session")
    }
}

// MARK: - DateFormatter Extension
extension DateFormatter {
    static let pharmaceuticalTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = TimeZone.current
        return formatter
    }()
}

// MARK: - Apple Native Camera Format Selection Extension

extension CameraManager {
    
    private func selectBestCameraFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        // Get all available formats
        let formats = device.formats
        
        // Filter for formats suitable for data matrix scanning
        let suitableFormats = formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let width = Int(dimensions.width)
            let height = Int(dimensions.height)
            
            // Prefer high resolution formats (4K or 1080p+)
            return width >= 1920 && height >= 1080
        }
        
        // Sort by quality criteria for data matrix scanning
        let sortedFormats = suitableFormats.sorted { format1, format2 in
            let dims1 = CMVideoFormatDescriptionGetDimensions(format1.formatDescription)
            let dims2 = CMVideoFormatDescriptionGetDimensions(format2.formatDescription)
            
            let resolution1 = Int(dims1.width) * Int(dims1.height)
            let resolution2 = Int(dims2.width) * Int(dims2.height)
            
            // Prefer higher resolution for sharper data matrix detection
            if resolution1 != resolution2 {
                return resolution1 > resolution2
            }
            
            // Prefer formats that support higher frame rates for stability
            let maxFPS1 = format1.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            let maxFPS2 = format2.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            
            return maxFPS1 > maxFPS2
        }
        
        // Return the best format
        let bestFormat = sortedFormats.first
        
        if let format = bestFormat {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let maxFPS = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            print("📷 [v2.3] NATIVE: Selected best format \(dims.width)x\(dims.height) @ \(String(format: "%.0f", maxFPS))fps")
        } else {
            print("⚠️ [v2.3] NATIVE: No suitable high-resolution format found, using default")
        }
        
        return bestFormat
    }
}