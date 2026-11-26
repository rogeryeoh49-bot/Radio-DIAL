import Foundation
@main struct Test {
 static func main() throws {
  precondition(TrackMetadataQuality.assess("NY's #1 Hit Music Station", station: "Z100") == .promotional)
  precondition(TrackMetadataQuality.assess("Z100", station: "Z100") == .promotional)
  precondition(TrackMetadataQuality.assess("Artist – Song", station: "Z100") == .song)
  precondition(TrackMetadataQuality.assess("Tame Impala", station: "Z100") == .ambiguous)
  precondition(TrackMetadataQuality.assess("Tame Impala - Unknown Title", station: "Z100") == .ambiguous)
  precondition(TrackMetadataQuality.assess("Tame Impala – Tame Impala", station: "Z100") == .ambiguous)
  precondition(TrackMetadataQuality.availableLabel("Tame Impala – Unknown Title") == "Tame Impala")
  precondition(TrackMetadataQuality.availableLabel("Unknown Title – Tame Impala") == "Tame Impala")
  precondition(TrackMetadataQuality.availableLabel("Tame Impala") == "Tame Impala")
  precondition(TrackMetadataQuality.assess("", station: "Z100") == .promotional)
  let display = TrackDisplayInfo.parse("Artist – Song - Live")
  precondition(display.title == "Song - Live" && display.artist == "Artist")
  precondition(TrackDisplayInfo.parse("Singer — Title").title == "Title")
  precondition(TrackDisplayInfo.parse("Title only").artist.isEmpty)
  let matched = TrackDisplayInfo.parse("Title - Singer", matchedTitle: "Title", matchedArtist: "Singer")
  precondition(matched.title == "Title" && matched.artist == "Singer")
  let icy = PlaylistMetadata.icyTrack(#"artist="Simon - Garfunkel",title="N/A""#)
  precondition(icy?.name == "Simon - Garfunkel" && icy?.artistOnly == true)
  let hls = PlaylistMetadata.current(in: [#"#EXTINF:6.0,artist="Tame Impala",title="""#])
  precondition(hls?.name == "Tame Impala" && hls?.artistOnly == true)
  let full = PlaylistMetadata.current(in: [#"#EXTINF:6.0,title="The Less I Know the Better",artist="Tame Impala",url="amgArtworkURL=\"https://example.com/cover.png\"""#])
  precondition(full?.name == "Tame Impala – The Less I Know the Better" && full?.artistOnly == false)
  precondition(full?.artwork?.absoluteString == "https://example.com/cover.png")

  let catalog = Data(#"""
  {"results":[
    {"trackName":"The Song","artistName":"Tribute Band","artworkUrl100":"https://example.com/tribute.jpg"},
    {"trackName":"The Song","artistName":"The Artist"},
    {"trackName":"The Song","artistName":"The Artist","artworkUrl100":"https://is1-ssl.mzstatic.com/image/100x100bb.jpg"}
  ]}
  """#.utf8)
  let cover = try Catalog.songMatch(in: catalog, for: "The Artist – The Song")
  precondition(cover?.artwork?.lastPathComponent == "1200x1200bb.jpg")
  precondition(cover?.originalArtwork?.lastPathComponent == "100x100bb.jpg")
  let edit = try Catalog.songMatch(in: catalog, for: "The Song (Radio Edit) - The Artist")
  precondition(edit?.artist == "The Artist")
  let remix = try Catalog.songMatch(in: catalog, for: "The Song (Remix) - The Artist")
  precondition(remix == nil)
  let playing = Catalog.SongQuery("The Song (Radio Edit) – The Artist")
  precondition(playing.matches(title: "The Song", artist: "The Artist"))
  precondition(!playing.matches(title: "The Song", artist: "Tribute Band"))
  precondition(!playing.matches(title: "The Other Song", artist: "The Artist"))
  print("Metadata classification, ICY/HLS parsing, display parsing and catalog artwork matching passed")
 }
}
