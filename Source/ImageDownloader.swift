// ImageDownloader.h
//
// Copyright (c) 2014–2015 Alamofire (http://alamofire.org)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Alamofire
import UIKit

public class ImageDownloader {
    
    public typealias ImageDownloadSuccessHandler = (NSURLRequest?, NSHTTPURLResponse?, UIImage) -> Void
    public typealias ImageDownloadFailureHandler = (NSURLRequest?, NSHTTPURLResponse?, NSError?) -> Void
    
    public enum DownloadPrioritization {
        case FIFO, LIFO
    }
    
    // MARK: - Properties
    
    let sessionManager: Alamofire.Manager
    
    private var queuedRequests: [Request]
    private let synchronizationQueue: dispatch_queue_t
    private let downloadPrioritization: DownloadPrioritization
    
    private var activeRequestCount: Int
    private let maximumActiveDownloads: Int
    
    // MARK: - Initialization Methods
    
    public class var defaultInstance: ImageDownloader {
        struct Singleton {
            static let instance: ImageDownloader = {
                let configuration: NSURLSessionConfiguration = {
                    let defaultConfiguration = NSURLSessionConfiguration.defaultSessionConfiguration()
                    
                    defaultConfiguration.HTTPAdditionalHeaders = Manager.defaultHTTPHeaders()
                    defaultConfiguration.HTTPShouldSetCookies = true // true by default
                    defaultConfiguration.HTTPShouldUsePipelining = true // risky change...
//                    defaultConfiguration.HTTPMaximumConnectionsPerHost = 4 on iOS or 6 on OSX
                    
                    defaultConfiguration.requestCachePolicy = .UseProtocolCachePolicy // Let server decide
                    defaultConfiguration.allowsCellularAccess = true
                    defaultConfiguration.timeoutIntervalForRequest = 30 // default is 60
                    
                    return defaultConfiguration
                }()
                
                return ImageDownloader(configuration: configuration)
            }()
        }
        
        return Singleton.instance
    }
    
    public init(
        configuration: NSURLSessionConfiguration? = nil,
        downloadPrioritization: DownloadPrioritization = .FIFO,
        maximumActiveDownloads: Int = 4)
    {
        self.sessionManager = Alamofire.Manager(configuration: configuration)
        self.sessionManager.startRequestsImmediately = false
        
        self.downloadPrioritization = downloadPrioritization
        self.maximumActiveDownloads = maximumActiveDownloads
        
        self.queuedRequests = []
        self.activeRequestCount = 0
        
        self.synchronizationQueue = {
            let name = String(format: "com.alamofire.alamofireimage.imagedownloader-%08%08", arc4random(), arc4random())
            return dispatch_queue_create(name, DISPATCH_QUEUE_SERIAL)
        }()
    }
    
    // MARK: - Download Methods
    
    public func downloadImage(
        #URLRequest: URLRequestConvertible,
        success: ImageDownloadSuccessHandler?,
        failure: ImageDownloadFailureHandler?)
        -> Request
    {
        let request = self.sessionManager.request(URLRequest)
        request.validate()
        request.responseImage { [weak self] URLRequest, response, image, error in
            if let strongSelf = self {
                if let image = image as? UIImage {
                    success?(URLRequest, response, image)
                } else {
                    failure?(URLRequest, response, error)
                }
                
                println("Finished Request: \(request.request.URLString)")
                
                strongSelf.safelyDecrementActiveRequestCount()
                strongSelf.safelyStartNextRequestIfNecessary()
            }
        }
        
        safelyStartRequestIfPossible(request)
        
        return request
    }
    
    // MARK: - Private - Thread-Safe Request Methods
    
    private func safelyStartRequestIfPossible(request: Request) {
        dispatch_sync(self.synchronizationQueue) {
            if self.isActiveRequestCountBelowMaximumLimit() {
                self.startRequest(request)
            } else {
                self.enqueueRequest(request)
            }
        }
    }
    
    private func safelyStartNextRequestIfNecessary() {
        dispatch_sync(self.synchronizationQueue) {
            if self.isActiveRequestCountBelowMaximumLimit() {
                if let request = self.dequeueRequest() {
                    self.startRequest(request)
                }
            }
        }
    }
    
    private func safelyDecrementActiveRequestCount() {
        dispatch_sync(self.synchronizationQueue) {
            if self.activeRequestCount > 0 {
                self.activeRequestCount -= 1
                println("Decremented Active Request Count: \(self.activeRequestCount)")
            }
        }
    }
    
    // MARK: - Private - Non Thread-Safe Request Methods
    
    private func startRequest(request: Request) {
        println("Starting Request: \(request.request.URLString)")
        request.resume()
        ++self.activeRequestCount
        println("Active Request Count: \(self.activeRequestCount)")
    }
    
    private func enqueueRequest(request: Request) {
        switch self.downloadPrioritization {
        case .FIFO:
            self.queuedRequests.append(request)
        case .LIFO:
            self.queuedRequests.insert(request, atIndex: 0)
        }
        
        println("Enqueued Request: \(request.request.URLString)")
    }
    
    private func dequeueRequest() -> Request? {
        var request: Request?
        
        if !self.queuedRequests.isEmpty {
            switch self.downloadPrioritization {
            case .FIFO:
                request = self.queuedRequests.removeAtIndex(0)
            case .LIFO:
                request = self.queuedRequests.removeLast()
            }
        }
        
        if let request = request {
            println("Dequeued Request: \(request.request.URLString)")
        }
        
        return request
    }
    
    private func isActiveRequestCountBelowMaximumLimit() -> Bool {
        return self.activeRequestCount < self.maximumActiveDownloads
    }
}
