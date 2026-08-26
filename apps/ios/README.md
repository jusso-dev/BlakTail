# BlakTail for iPhone

Native SwiftUI client. One session searches and administers machines across
every authorised network workspace, and **This iPhone** joins that network as a
WireGuard node. See [`docs/ios.md`](../../docs/ios.md).

```sh
swift test
open BlakTailPhone.xcodeproj
```

Minimum iOS 17. Session tokens go in Keychain (`au.org.blaktail.ios`). Node
enrolment is shared with the packet-tunnel extension through
`TEAMID.au.org.blaktail.ios.shared`.
