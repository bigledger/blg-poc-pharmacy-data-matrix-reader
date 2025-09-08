import SwiftUI
import AVFoundation
import Vision

struct FarmaTagScannerView: View {
    @StateObject private var cameraManager = CameraManager()
    @State private var detectedCodes: [DataMatrixResult] = []
    @State private var zoomLevel: CGFloat = 1.0
    @State private var showingResults = false
    @State private var selectedResult: DataMatrixResult?
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Camera View
                CameraPreviewView(
                    session: cameraManager.captureSession,
                    cameraManager: cameraManager
                )
                    .ignoresSafeArea()
                
                // Scanning Overlay
                ScanningOverlay(detectedCodes: detectedCodes, frameSize: geometry.size)
                
                // Top Controls
                VStack {
                    HStack {
                        Text("🏥 FarmaTag Scanner")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(20)
                        
                        Spacer()
                        
                        if !detectedCodes.isEmpty {
                            Button(action: { showingResults = true }) {
                                Text("\(detectedCodes.count) Found")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.green)
                                    .cornerRadius(15)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 20)
                    
                    Spacer()
                }
                
                // Bottom Controls
                VStack {
                    Spacer()
                    
                    HStack(spacing: 30) {
                        // Zoom Out
                        Button(action: { adjustZoom(-0.5) }) {
                            Image(systemName: "minus.magnifyingglass")
                                .font(.title2)
                                .foregroundColor(.white)
                                .frame(width: 50, height: 50)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Circle())
                        }
                        .disabled(zoomLevel <= 1.0)
                        
                        // Capture Button
                        Button(action: captureFrame) {
                            ZStack {
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 70, height: 70)
                                Circle()
                                    .stroke(Color.blue, lineWidth: 4)
                                    .frame(width: 80, height: 80)
                            }
                        }
                        
                        // Zoom In
                        Button(action: { adjustZoom(0.5) }) {
                            Image(systemName: "plus.magnifyingglass")
                                .font(.title2)
                                .foregroundColor(.white)
                                .frame(width: 50, height: 50)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Circle())
                        }
                        .disabled(zoomLevel >= 5.0)
                    }
                    .padding(.bottom, 50)
                }
                
                // Zoom Level Indicator
                if zoomLevel > 1.0 {
                    VStack {
                        HStack {
                            Spacer()
                            Text("×\(String(format: "%.1f", zoomLevel))")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.7))
                                .cornerRadius(8)
                                .padding(.trailing)
                        }
                        .padding(.top, 80)
                        Spacer()
                    }
                }
            }
        }
        .onAppear {
            cameraManager.startSession()
            cameraManager.onDataMatrixDetected = { results in
                DispatchQueue.main.async {
                    self.detectedCodes = results
                }
            }
        }
        .onDisappear {
            cameraManager.stopSession()
        }
        .sheet(isPresented: $showingResults) {
            DataMatrixResultsView(results: detectedCodes)
        }
    }
    
    private func adjustZoom(_ delta: CGFloat) {
        let newZoom = max(1.0, min(5.0, zoomLevel + delta))
        zoomLevel = newZoom
        cameraManager.setZoomLevel(newZoom)
    }
    
    private func captureFrame() {
        cameraManager.captureFrame()
    }
}


struct ScanningOverlay: View {
    let detectedCodes: [DataMatrixResult]
    let frameSize: CGSize
    
    var body: some View {
        ZStack {
            // Scanning Viewfinder
            Rectangle()
                .stroke(Color.green.opacity(0.8), lineWidth: 2)
                .frame(width: min(frameSize.width * 0.8, 300), 
                       height: min(frameSize.width * 0.8, 300))
                .overlay(
                    VStack {
                        HStack {
                            Rectangle()
                                .fill(Color.green)
                                .frame(width: 20, height: 4)
                            Spacer()
                            Rectangle()
                                .fill(Color.green)
                                .frame(width: 20, height: 4)
                        }
                        Spacer()
                        HStack {
                            Rectangle()
                                .fill(Color.green)
                                .frame(width: 20, height: 4)
                            Spacer()
                            Rectangle()
                                .fill(Color.green)
                                .frame(width: 20, height: 4)
                        }
                    }
                )
            
            // Detection Highlights
            ForEach(Array(detectedCodes.enumerated()), id: \.offset) { index, detection in
                DataMatrixHighlight(detection: detection, frameSize: frameSize)
            }
            
            // Instructions
            VStack {
                Spacer()
                Text("Point camera at FarmaTag data matrix")
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(10)
                    .padding(.bottom, 120)
            }
        }
    }
}

struct DataMatrixHighlight: View {
    let detection: DataMatrixResult
    let frameSize: CGSize
    
    var body: some View {
        let bounds = calculateBounds()
        
        Rectangle()
            .stroke(Color.yellow, lineWidth: 3)
            .background(Color.yellow.opacity(0.2))
            .frame(width: bounds.width, height: bounds.height)
            .position(x: bounds.midX, y: bounds.midY)
            .overlay(
                VStack {
                    HStack {
                        Text("DATA MATRIX")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.yellow)
                            .cornerRadius(4)
                        Spacer()
                    }
                    Spacer()
                }
                .frame(width: bounds.width, height: bounds.height)
                .position(x: bounds.midX, y: bounds.midY)
            )
    }
    
    private func calculateBounds() -> CGRect {
        let x = detection.boundingBox.origin.x * frameSize.width
        let y = detection.boundingBox.origin.y * frameSize.height
        let width = detection.boundingBox.width * frameSize.width
        let height = detection.boundingBox.height * frameSize.height
        
        return CGRect(x: x, y: y, width: max(width, 60), height: max(height, 60))
    }
}

struct DataMatrixResultsView: View {
    let results: [DataMatrixResult]
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            List {
                ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Data Matrix \(index + 1)")
                                .font(.headline)
                                .fontWeight(.semibold)
                            
                            Spacer()
                            
                            Text("✅ Valid")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.green)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.green.opacity(0.1))
                                .cornerRadius(8)
                        }
                        
                        if let farmaData = result.farmaTagData {
                            VStack(alignment: .leading, spacing: 4) {
                                InfoRow(label: "GTIN", value: farmaData.gtin)
                                InfoRow(label: "Serial Number", value: farmaData.serialNumber)
                                InfoRow(label: "Batch/Lot", value: farmaData.batchNumber)
                                InfoRow(label: "Expiry Date", value: farmaData.expiryDate)
                                if let manufacturingDate = farmaData.manufacturingDate {
                                    InfoRow(label: "Manufacturing Date", value: manufacturingDate)
                                }
                            }
                        } else {
                            Text("Raw Data: \(result.decodedString)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.vertical, 4)
                        }
                        
                        Text("Confidence: \(Int(result.confidence * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("FarmaTag Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label + ":")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
            Spacer()
        }
    }
}

// MARK: - Data Models

struct DataMatrixResult {
    let id = UUID()
    let decodedString: String
    let boundingBox: CGRect
    let confidence: Float
    let timestamp: Date
    let farmaTagData: FarmaTagData?
    
    init(decodedString: String, boundingBox: CGRect, confidence: Float) {
        self.decodedString = decodedString
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.timestamp = Date()
        self.farmaTagData = FarmaTagParser.parse(decodedString)
    }
}

struct FarmaTagData {
    let gtin: String
    let serialNumber: String
    let batchNumber: String
    let expiryDate: String
    let manufacturingDate: String?
}

struct FarmaTagParser {
    static func parse(_ dataMatrixString: String) -> FarmaTagData? {
        // Parse GS1 format data matrix (Malaysian FarmaTag standard)
        var gtin = ""
        var serialNumber = ""
        var batchNumber = ""
        var expiryDate = ""
        var manufacturingDate: String?
        
        let input = dataMatrixString
        var currentIndex = input.startIndex
        
        while currentIndex < input.endIndex {
            // Check for Application Identifiers (AI)
            if currentIndex < input.index(input.endIndex, offsetBy: -2) {
                let aiCandidate = String(input[currentIndex..<input.index(currentIndex, offsetBy: 2)])
                
                switch aiCandidate {
                case "01": // GTIN
                    currentIndex = input.index(currentIndex, offsetBy: 2)
                    if let endIndex = findNextAI(in: input, startingFrom: currentIndex, length: 14) {
                        gtin = String(input[currentIndex..<endIndex])
                        currentIndex = endIndex
                    }
                case "21": // Serial Number
                    currentIndex = input.index(currentIndex, offsetBy: 2)
                    if let endIndex = findNextAI(in: input, startingFrom: currentIndex) {
                        serialNumber = String(input[currentIndex..<endIndex])
                        currentIndex = endIndex
                    }
                case "10": // Batch/Lot Number
                    currentIndex = input.index(currentIndex, offsetBy: 2)
                    if let endIndex = findNextAI(in: input, startingFrom: currentIndex) {
                        batchNumber = String(input[currentIndex..<endIndex])
                        currentIndex = endIndex
                    }
                case "17": // Expiry Date (YYMMDD)
                    currentIndex = input.index(currentIndex, offsetBy: 2)
                    if let endIndex = findNextAI(in: input, startingFrom: currentIndex, length: 6) {
                        let rawDate = String(input[currentIndex..<endIndex])
                        expiryDate = formatDate(rawDate)
                        currentIndex = endIndex
                    }
                case "11": // Manufacturing Date (YYMMDD)
                    currentIndex = input.index(currentIndex, offsetBy: 2)
                    if let endIndex = findNextAI(in: input, startingFrom: currentIndex, length: 6) {
                        let rawDate = String(input[currentIndex..<endIndex])
                        manufacturingDate = formatDate(rawDate)
                        currentIndex = endIndex
                    }
                default:
                    currentIndex = input.index(after: currentIndex)
                }
            } else {
                break
            }
        }
        
        // Return parsed data if we have essential fields
        if !gtin.isEmpty && !serialNumber.isEmpty {
            return FarmaTagData(
                gtin: gtin,
                serialNumber: serialNumber,
                batchNumber: batchNumber.isEmpty ? "N/A" : batchNumber,
                expiryDate: expiryDate.isEmpty ? "N/A" : expiryDate,
                manufacturingDate: manufacturingDate
            )
        }
        
        return nil
    }
    
    private static func findNextAI(in string: String, startingFrom index: String.Index, length: Int? = nil) -> String.Index? {
        if let length = length {
            let endIndex = string.index(index, offsetBy: length, limitedBy: string.endIndex) ?? string.endIndex
            return endIndex
        }
        
        // Look for next AI or end of string
        var currentIndex = index
        while currentIndex < string.endIndex {
            if currentIndex < string.index(string.endIndex, offsetBy: -1) {
                let possibleAI = String(string[currentIndex..<string.index(currentIndex, offsetBy: 2)])
                if ["01", "10", "11", "17", "21"].contains(possibleAI) {
                    return currentIndex
                }
            }
            currentIndex = string.index(after: currentIndex)
        }
        return string.endIndex
    }
    
    private static func formatDate(_ rawDate: String) -> String {
        guard rawDate.count == 6 else { return rawDate }
        let year = "20" + String(rawDate.prefix(2))
        let month = String(rawDate.dropFirst(2).prefix(2))
        let day = String(rawDate.suffix(2))
        return "\(day)/\(month)/\(year)"
    }
}

#Preview {
    FarmaTagScannerView()
}