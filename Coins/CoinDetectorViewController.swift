//
//  CoinDetectorViewController.swift
//  Count
//
//  Created by Dani Shifer on 25/08/2019.
//  Copyright © 2019 Dani Shifer. All rights reserved.
//

import UIKit
import AVFoundation
import Vision

class CoinDetectorViewController: ViewController, AVCapturePhotoCaptureDelegate, UITableViewDelegate, UITableViewDataSource {
    @IBOutlet weak var tableView: UITableView!
    @IBOutlet weak var savePhotosSwitch: UISwitch!
    
    private let kCoinPaddingPercentage: CGFloat = 10
    
    private let coinDetectorMLModel = CoinDetector()
    private let coinClassifierMLModel = CoinClassifier()
    
    
    private var detectionOverlay: CALayer! = nil
    
    private var staticCoinDetectionRequest: VNCoreMLRequest!
    private var liveCoinDetectionRequest: VNCoreMLRequest!
    
    struct Coin {
        let id: UUID
        var label: String?
        var labelConfidence: Double?
        
        init() {
            self.id = UUID()
        }
    }
    
    private var coinClassifications = [Coin]()
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return coinClassifications.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "CoinObservationCell", for: indexPath) as! CoinObservationCell
        
        cell.coinLabel.text = coinClassifications[indexPath.row].label ?? coinClassifications[indexPath.row].id.uuidString
        cell.confidenceLabel.text = String(format: "%.2f", coinClassifications[indexPath.row].labelConfidence ?? 0.0)
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        detectionOverlay.sublayers?.forEach { layer in
            if (layer.name == coinClassifications[indexPath.row].id.uuidString) {
                layer.backgroundColor = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0.5, 1.0, 0.2, 0.4])
            } else {
                layer.backgroundColor = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [1.0, 1.0, 0.2, 0.4])
            }
        }
    }
    
    private var capturePhoto = false
    
    @IBOutlet weak var captureButton: UIButton!
    @IBAction func capture(_ sender: UIButton) {
        if session.isRunning {
            captureButton.setTitle("Resume", for: .normal)
            capturePhoto = true
        } else {
            captureButton.setTitle("Capture", for: .normal)
            startCaptureSession()
        }
        
        
       
    }
    
    func setupVision() {
        let visionModel = try! VNCoreMLModel(for: coinDetectorMLModel.model)
        
        liveCoinDetectionRequest = VNCoreMLRequest(model: visionModel) { (request, error) in
            if let results = request.results {
                DispatchQueue.main.async {
                    self.drawVisionRequestResults(results)
                }
            }
        }
        
        staticCoinDetectionRequest = VNCoreMLRequest(model: visionModel) { (request, error) in
            if let results = request.results {
                for case let foundObject as VNRecognizedObjectObservation in results {
                    let bestLabel = foundObject.labels.first!
                    let objectBounds = foundObject.boundingBox
                    
                    print(bestLabel.identifier, bestLabel.confidence, objectBounds)
                }
                
                DispatchQueue.main.async {
                    self.drawVisionRequestResults(results)
                    self.staticCoinDetectionCompleted(with: results)
                }
            }
        }
        
        liveCoinDetectionRequest.imageCropAndScaleOption = .scaleFill
        staticCoinDetectionRequest.imageCropAndScaleOption = .scaleFill
    }
    
    func addClassification(to coin: Coin, with results: [Any]) -> Coin {
        var coin = coin
        
        for observation in results where observation is VNClassificationObservation {
            guard let coinClassification = observation as? VNClassificationObservation else {
                continue
            }
            
            coin.label = coinClassification.identifier
            coin.labelConfidence = Double(coinClassification.confidence)
            
            print(coinClassification.identifier, coinClassification.confidence)
            
            break
        }
        
        return coin
    }
    
    func clearDetectionOverlay() {
        detectionOverlay.sublayers = nil
    }
    
    func staticCoinDetectionCompleted(with results: [Any]) {
        let fullImage = self.previewLayer.contents as! CGImage
        let coinClassifierModel = try! VNCoreMLModel(for: coinClassifierMLModel.model)

        // Reset detection overlay
        CATransaction.begin()
        CATransaction.setValue(kCFBooleanTrue, forKey: kCATransactionDisableActions)
        clearDetectionOverlay()
        
        for observation in results where observation is VNRecognizedObjectObservation {
            guard let objectObservation = observation as? VNRecognizedObjectObservation else {
                continue
            }
            
            let coin = Coin()
            
            let objectBounds = VNImageRectForNormalizedRect(objectObservation.boundingBox, Int(self.bufferSize.width), Int(self.bufferSize.height))
            
            // Draw coin bounding box
            let shapeLayer = createRoundedRectLayerWithBounds(objectBounds)
            shapeLayer.name = coin.id.uuidString
            detectionOverlay.addSublayer(shapeLayer)
            
            let width = objectBounds.width
            let height = objectBounds.height
            var xInset: CGFloat!
            var yInset: CGFloat!
            
            if width == max(width, height) {
                // Width > Height
                xInset = (self.kCoinPaddingPercentage * width) / 100
                yInset = (width - height) / 2 + xInset
            } else {
                // Width < Height
                yInset = (self.kCoinPaddingPercentage * height) / 100
                xInset = (height - width) / 2 + yInset
            }
            
            let insets = UIEdgeInsets(top: -yInset, left: -xInset, bottom: -yInset, right: -xInset)
            var correctedBounds = objectBounds.inset(by: insets)
            correctedBounds.origin.y = bufferSize.height - (correctedBounds.origin.y + correctedBounds.height)
            
            let croppedImage = fullImage.cropping(to: correctedBounds)!
            let imageRequestHandler = VNImageRequestHandler(cgImage: croppedImage, options: [:])
            
            do {
                let classificationRequest = VNCoreMLRequest(model: coinClassifierModel) { [weak self] (request, error) in
                    if let results = request.results {
                        DispatchQueue.main.async {
                            let classifiedCoin = self?.addClassification(to: coin, with: results)
                            self?.coinClassifications.append(classifiedCoin!)
                            self?.tableView.reloadData()
                        }
                    }
                }
                
                classificationRequest.imageCropAndScaleOption = .scaleFill
                try imageRequestHandler.perform([classificationRequest])
            } catch {
                print(error)
            }
            
            if savePhotosSwitch.isOn {
                let uiImage = UIImage(cgImage: croppedImage)
                UIImageWriteToSavedPhotosAlbum(uiImage, nil, nil, nil)
            }
        }
        
        self.updateLayerGeometry()
        CATransaction.commit()
    }
    
    func drawVisionRequestResults(_ results: [Any]) {
        CATransaction.begin()
        CATransaction.setValue(kCFBooleanTrue, forKey: kCATransactionDisableActions)
        detectionOverlay.sublayers = nil
        
        for observation in results where observation is VNRecognizedObjectObservation {
            guard let objectObservation = observation as? VNRecognizedObjectObservation else {
                continue
            }
            
            let topLabelObservation = objectObservation.labels[0]
            let objectBounds = VNImageRectForNormalizedRect(objectObservation.boundingBox, Int(bufferSize.width), Int(bufferSize.height))
            
            let shapeLayer = self.createRoundedRectLayerWithBounds(objectBounds)
            let textLayer = self.createTextSubLayerInBounds(objectBounds,
                                                            identifier: topLabelObservation.identifier,
                                                            confidence: topLabelObservation.confidence)
            
            shapeLayer.addSublayer(textLayer)
            
            detectionOverlay.addSublayer(shapeLayer)
        }
        self.updateLayerGeometry()
        CATransaction.commit()
    }
    

    func getImageFromPixelBuffer(sampleBuffer: CMSampleBuffer) -> CGImage? {
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let context = CIContext()
            
            let imageRect = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
            
            return context.createCGImage(ciImage, from: imageRect)
        }
        
        return nil
    }
    
    override func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        let exifOrientation = exifOrientationFromDeviceOrientation()
        let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: exifOrientation, options: [:])
        
        if capturePhoto {
            capturePhoto = false
            
            DispatchQueue.main.async {
                self.stopCaptureSession()
            }
            
            if let image = self.getImageFromPixelBuffer(sampleBuffer: sampleBuffer) {
                previewLayer.contents = image
                
                do {
                    self.coinClassifications = [Coin]()
                    try imageRequestHandler.perform([self.staticCoinDetectionRequest])
                } catch {
                    print(error)
                }
            }
            
            return
        }
        
        do {
            try imageRequestHandler.perform([self.liveCoinDetectionRequest])
        } catch {
            print(error)
        }
    }

    
    override func setupAVCapture() {
        super.setupAVCapture()
        
        // Setup Vision
        setupLayers()
        updateLayerGeometry()
        setupVision()
        
        // Start capturing
        startCaptureSession()
    }
    
    
    func setupLayers() {
        detectionOverlay = CALayer()
        detectionOverlay.name = "DetectionOverlay"
        detectionOverlay.bounds = CGRect(x: 0.0,
                                         y: 0.0,
                                         width: bufferSize.width,
                                         height: bufferSize.height)
        detectionOverlay.position = CGPoint(x: rootLayer.bounds.midX, y: rootLayer.bounds.midY)
        rootLayer.addSublayer(detectionOverlay)
    }
    
    func updateLayerGeometry() {
        let bounds = rootLayer.bounds
        var scale: CGFloat
        
        let xScale: CGFloat = bounds.size.width / bufferSize.height
        let yScale: CGFloat = bounds.size.height / bufferSize.width
        
        scale = fmax(xScale, yScale)
        if scale.isInfinite {
            scale = 1.0
        }
        
        CATransaction.begin()
        CATransaction.setValue(kCFBooleanTrue, forKey: kCATransactionDisableActions)
        
        detectionOverlay.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(.pi / 2.0)).scaledBy(x: scale, y: -scale))
        
        detectionOverlay.position = CGPoint(x: bounds.midX, y: bounds.midY)
        
        CATransaction.commit()
    }
    
    func createTextSubLayerInBounds(_ bounds: CGRect, identifier: String, confidence: VNConfidence) -> CATextLayer {
        let textLayer = CATextLayer()
        textLayer.name = "Object Label"
        let formattedString = NSMutableAttributedString(string: String(format: "\(identifier)\nConfidence: %.2f", confidence))
        let largeFont = UIFont(name: "Helvetica", size: 24.0)!
        
        formattedString.addAttributes([NSAttributedString.Key.font: largeFont], range: NSRange(location: 0, length: identifier.count))
        textLayer.string = formattedString
        textLayer.bounds = CGRect(x: 0, y: 0, width: bounds.size.width - 10, height: bounds.size.height - 10)
        textLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        textLayer.shadowOpacity = 0.7
        textLayer.shadowOffset = CGSize(width: 2, height: 2)
        textLayer.foregroundColor = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0.0, 0.0, 0.0, 1.0])
        textLayer.contentsScale = 2.0 // retina
        textLayer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(.pi / 2.0)).scaledBy(x: 1.0, y: -1.0))
        
        return textLayer
    }
    
    func createRoundedRectLayerWithBounds(_ bounds: CGRect) -> CALayer {
        let shapeLayer = CALayer()
        shapeLayer.bounds = bounds
        shapeLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        shapeLayer.name = "Found Object"
        shapeLayer.backgroundColor = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [1.0, 1.0, 0.2, 0.4])
        shapeLayer.cornerRadius = 7
        return shapeLayer
    }

}
