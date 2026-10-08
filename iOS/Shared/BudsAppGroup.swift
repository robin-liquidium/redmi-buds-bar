import Foundation

/// Both the app and controls must use the App Group authorized by their signing team.
enum BudsAppGroup {
    static let identifier = Bundle.main.object(forInfoDictionaryKey: "BudsAppGroupIdentifier") as! String
}
