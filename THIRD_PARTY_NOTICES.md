# Third-party notices

Willow uses source from [Breeze](https://github.com/breeze-project-org/Breeze), revision `d4888c8d4eaa866a526bd29b90564f6c60b86be3`, under the Mozilla Public License 2.0. The upstream license is preserved at `Vendor/Breeze/LICENSE`.

The unmodified `rust/rquickjs_playground` runtime and `rust/src/decode` image utilities are referenced directly from the submodule. Willow does not distribute the Flutter application or its UI assets.

QuickJS is supplied through Breeze's pinned [rquickjs-sys fork](https://github.com/deretame/breeze-rquickjs-sys), revision `846889c482ee7511f558595384673f55c00c9f4a`. Rust transitive dependencies and exact versions are recorded in `Bridge/Cargo.lock`; their individual upstream licenses continue to apply.

No third-party manga source bundle or manga content is bundled with the application. `Core/Tests/BreezePluginsTests/Fixtures/contract.cjs` is an original offline test fixture.

Plugin OpenCC compatibility uses [ferrous-opencc](https://github.com/apoint123/ferrous-opencc) 0.4.0 under Apache-2.0, matching Breeze's conversion library and built-in configurations. Its exact dependencies are pinned in `Bridge/Cargo.lock`.

## Binary distribution

The app bundles full license and copyright notices at
`Core/Sources/CoreStorage/Resources/ThirdPartyLicenses.json`, available offline in
Settings → About → Third-Party License Notices. The catalog includes runtime and
build-time dependencies from the locked iOS dependency graph, plus nested notices
(including QuickJS, Temporal polyfill, libwebp, and cryptographic libraries).
For alternative licenses, no GPL option is selected; Apache-2.0 is used where a
package offers Apache-2.0 OR GPL-2.0-only.

Each unsigned release includes a `Willow-X.Y.Z-sources.tar.gz` asset containing the
Breeze runtime and decode source, the Willow Rust integration source, and the exact
Rust dependencies recorded in `Bridge/Cargo.lock`. Breeze and other MPL-covered
source remain available under MPL-2.0. Recipients may obtain this source without
additional charge; no Willow terms restrict rights granted by those licenses.
Willow's original source code is available under MPL-2.0. See the root [LICENSE](LICENSE).

Breeze corresponding source: https://github.com/breeze-project-org/Breeze/tree/d4888c8d4eaa866a526bd29b90564f6c60b86be3

## Maintaining notices

Run `python3 Scripts/package-licenses.py` after changing Rust dependencies, using
Rust 1.96.1 with the locked dependencies downloaded. The release packaging script
checks that the bundled catalog is current and creates the source archive.
`Licenses/Overrides/SOURCES.json` records upstream sources for supplemental notices.
Standard texts in `Licenses/Standard` fill omissions in published crate archives;
package authors and declared license choices are retained in the catalog.
