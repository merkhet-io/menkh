import Foundation
import CoreGraphics

@main struct PresentationTest {
    static func main() {
        var budget=PresentationBudget()
        func pixels(_ time:Double,_ adaptive:Bool=true)->CGSize {budget.size(width:1280,height:900,backing:2,time:time,adaptive:adaptive)}
        precondition(pixels(0)==CGSize(width:2560,height:1800))
        budget.touch(at:1)
        precondition(budget.active(at:1) && pixels(1)==CGSize(width:1280,height:900))
        // Hysteresis prevents quality bouncing between 150–200 ms publications.
        budget.touch(at:1.2)
        precondition(pixels(1.4)==CGSize(width:1280,height:900))
        precondition(!budget.active(at:1.6) && pixels(1.6)==CGSize(width:2560,height:1800))
        budget.touch(at:2)
        precondition(pixels(2,false)==CGSize(width:2560,height:1800))
        precondition(budget.size(width:800,height:600,backing:2,time:2,adaptive:true)==CGSize(width:1200,height:900))
        precondition(budget.size(width:800,height:600,backing:1,time:2,adaptive:true)==CGSize(width:800,height:600))
        print("Presentation budget: native idle, capped motion, hysteresis and override passed")
    }
}
