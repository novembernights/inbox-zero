# Third-party notices and asset scope

The repository's MIT license applies to the project contribution, not to third-party packages or trademarks. Preserve all upstream licenses when redistributing dependencies or binaries.

## Swift packages

The notices below were copied verbatim from locally cached dependency checkouts whose Git revisions matched the committed `Package.resolved`. Package source is not vendored. Transitive packages are listed as well as direct dependencies.

| Dependency | Locked version/revision | Upstream | Notices |
| --- | --- | --- | --- |
| grdb.swift | 7.10.0 | https://github.com/groue/GRDB.swift.git | [notices](third-party-licenses/grdb.swift/) |
| lucide-icons-swift | 1.29.0 | https://github.com/JakubMazur/lucide-icons-swift.git | [notices](third-party-licenses/lucide-icons-swift/) |
| swift-argument-parser | 1.8.2 | https://github.com/apple/swift-argument-parser | [notices](third-party-licenses/swift-argument-parser/) |
| swift-atomics | 1.3.1 | https://github.com/apple/swift-atomics.git | [notices](third-party-licenses/swift-atomics/) |
| swift-collections | 1.6.0 | https://github.com/apple/swift-collections.git | [notices](third-party-licenses/swift-collections/) |
| swift-dotenv | 2.1.0 | https://github.com/thebarndog/swift-dotenv | [notices](third-party-licenses/swift-dotenv/) |
| swift-log | 1.15.0 | https://github.com/apple/swift-log.git | [notices](third-party-licenses/swift-log/) |
| swift-nio | 2.101.3 | https://github.com/apple/swift-nio | [notices](third-party-licenses/swift-nio/) |
| swift-nio-imap | 0.4.0 | https://github.com/apple/swift-nio-imap | [notices](third-party-licenses/swift-nio-imap/) |
| swift-nio-ssl | 2.37.2 | https://github.com/apple/swift-nio-ssl | [notices](third-party-licenses/swift-nio-ssl/) |
| swift-se0270-range-set | 1.0.1 | https://github.com/apple/swift-se0270-range-set.git | [notices](third-party-licenses/swift-se0270-range-set/) |
| swift-system | 1.8.1 | https://github.com/apple/swift-system.git | [notices](third-party-licenses/swift-system/) |
| swiftcross | 1.2.0 | https://github.com/Cocoanetics/SwiftCross | [notices](third-party-licenses/swiftcross/) |
| swiftmail | f8469b14f762 | https://github.com/Cocoanetics/SwiftMail.git | [notices](third-party-licenses/swiftmail/) |
| swipeactions | 71cca4164100 | https://github.com/aheze/SwipeActions.git | [notices](third-party-licenses/swipeactions/) |

## Other components

- Apple's system frameworks and SDKs are not redistributed here; developers supply their own Apple toolchain.
- Python relay packages are external dependencies listed in `relay/requirements.txt`, not vendored in this source archive. Review and preserve their licenses when building a relay image.
- The custom font and third-party campaign/reference media from development are excluded. The public app uses system typography.
- App mark SVGs and app icons are retained. Jason Johnson confirmed authorship of the star-shaped artwork; these project assets are included under the project MIT license. PNG metadata and extended filesystem attributes are not carried into the release archive. The desktop's former personal monogram is replaced by the app mark. An unused gradient with unconfirmed provenance was excluded.
- The Metal orb adapts [Liquid Orb Editor](https://github.com/LerSent001/orb/tree/8d1736e1fc5b41a5037b524403f35b7952b038f0), copyright 2026 LerSent001, under MIT. Its original [license](https://github.com/LerSent001/orb/blob/8d1736e1fc5b41a5037b524403f35b7952b038f0/LICENSE) is retained verbatim in [third-party-licenses/liquid-orb-editor/LICENSE](third-party-licenses/liquid-orb-editor/LICENSE). The supplied export's Chrome fluid, shading, refraction and highlight functions correspond to upstream `effect.wgsl`/`effect.metal`; the app narrows this to Chrome and adds the press dent and SwiftUI control. This is an adapted implementation, not a byte-identical export.
- The gooey-menu website was a visual reference only. The exported app uses native SwiftUI glass and animation code; no website artwork or JavaScript package from that reference is redistributed.

Third-party copyright holder names in upstream notices are legal attribution, not developer account data. No endorsement by those projects is implied.
