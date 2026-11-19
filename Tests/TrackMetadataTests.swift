import Foundation
@main struct Test {
 static func main() {
  precondition(TrackMetadataQuality.assess("NY's #1 Hit Music Station", station: "Z100") == .promotional)
  precondition(TrackMetadataQuality.assess("Z100", station: "Z100") == .promotional)
  precondition(TrackMetadataQuality.assess("Artist – Song", station: "Z100") == .song)
  precondition(TrackMetadataQuality.assess("Tame Impala", station: "Z100") == .ambiguous)
  precondition(TrackMetadataQuality.assess("", station: "Z100") == .promotional)
  let display = TrackDisplayInfo.parse("Artist – Song - Live")
  precondition(display.title == "Song - Live" && display.artist == "Artist")
  precondition(TrackDisplayInfo.parse("Singer — Title").title == "Title")
  precondition(TrackDisplayInfo.parse("Title only").artist.isEmpty)
  let matched = TrackDisplayInfo.parse("Title - Singer", matchedTitle: "Title", matchedArtist: "Singer")
  precondition(matched.title == "Title" && matched.artist == "Singer")
  print("Metadata classification and display parsing checks passed")
 }
}
