import Foundation

/// Display pixels only. Occupancy, camera coordinates and export sizes are unchanged.
struct PresentationBudget {
    private(set) var activeUntil:Double = -.infinity
    mutating func touch(at time:Double) {activeUntil=max(activeUntil,time+0.35)}
    func size(width:Double,height:Double,backing:Double,time:Double,adaptive:Bool)->CGSize {
        let native=max(1,backing)
        let scale=adaptive && time<activeUntil ? min(native,min(1280/max(1,width),900/max(1,height))):native
        return CGSize(width:max(1,(width*scale).rounded()),height:max(1,(height*scale).rounded()))
    }
    func active(at time:Double)->Bool {time<activeUntil}
}
