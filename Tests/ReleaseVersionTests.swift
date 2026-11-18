import Foundation
@main struct Test {
 static func main() {
  precondition(ReleaseVersion("v2.0.1")! > ReleaseVersion("2.0.0")!)
  precondition(ReleaseVersion("v2.10.0")! > ReleaseVersion("2.9.99")!)
  precondition(ReleaseVersion("2.0")! == ReleaseVersion("2.0.0")!)
  precondition(ReleaseVersion("v2.0.0-beta") == nil)
  precondition(ReleaseVersion("../../evil") == nil)
  print("Version comparison passed")
 }
}
