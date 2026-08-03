import AVFoundation
import Foundation

func t1(_ data: Data) {
    let r = AVContentKeyResponse(clearKeyData: data)
    _ = r
}

func t2(_ data: Data) {
    let r = AVContentKeyResponse(clearKeyData: data, initializationVector: nil)
    _ = r
}

func t3(_ data: Data) {
    let r = AVContentKeyResponse(clearKeyData: data, initializationVector: Data())
    _ = r
}
