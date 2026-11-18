import Foundation
@main struct Test {
 static func main() {
  precondition(TrackMetadataQuality.assess("NY's #1 Hit Music Station", station: "Z100") == .promotional)
  precondition(TrackMetadataQuality.assess("Z100", station: "Z100") == .promotional)
  precondition(TrackMetadataQuality.assess("Artist – Song", station: "Z100") == .song)
  precondition(TrackMetadataQuality.assess("Tame Impala", station: "Z100") == .ambiguous)
  precondition(TrackMetadataQuality.assess("", station: "Z100") == .promotional)
  print("Metadata classification checks passed")
 }
}
