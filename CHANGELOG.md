# Changelog

## 0.1.0 (2026-10-19)


### Features

* add auto-detect meetings (Phases 2-7) ([bc656af](https://github.com/ncerny/alembic/commit/bc656afd06e4fc861a8ff7218be804737f208da6))
* add calendar event list to meeting view ([599d947](https://github.com/ncerny/alembic/commit/599d947950dd7e72e29bb520419cc500999f3318))
* add calendar sync with polling and people management ([4cacce1](https://github.com/ncerny/alembic/commit/4cacce1e7092aecdc1821039d08ca3c852c0ba48))
* add Connect to M365 button in settings ([07c10e6](https://github.com/ncerny/alembic/commit/07c10e6986c727f12a4cb88ae2de27301afde4c0))
* add Graph API types and calendar settings ([cf51224](https://github.com/ncerny/alembic/commit/cf51224c8e9fc26280d25f6b7c5de57283a16a75))
* add Graph client for calendar view API ([72e1adf](https://github.com/ncerny/alembic/commit/72e1adfe1add23b6395c92ab8a67c35f077878a1))
* add M365 auth module using Azure CLI ([2276626](https://github.com/ncerny/alembic/commit/227662637f2fbbc4f73fc85bb144e0b1d549bc75))
* add M365 connection settings UI ([68694d0](https://github.com/ncerny/alembic/commit/68694d08b20d0f1960189ea4f33a5e265cf8f544))
* add people manager for auto-creating vault notes ([267583e](https://github.com/ncerny/alembic/commit/267583eb1b3e2debcf924d0a3e48c0eac5af6064))
* **alembic:** add automatic meeting detection and auto-start recording ([b8ffa0f](https://github.com/ncerny/alembic/commit/b8ffa0fc05b6f48fa1898a3794f39b45fc74ce0b))
* **app:** add standalone macOS real-time Teams transcription app ([6890809](https://github.com/ncerny/alembic/commit/689080947be79cd0cf0526d80eebb066699f56a3))
* **attribution:** add on-device Teams speaker attribution ([#7](https://github.com/ncerny/alembic/issues/7)) ([1945ab2](https://github.com/ncerny/alembic/commit/1945ab2533dc84c564fd2abc2d6bb60250e1f5ae))
* complete audio pipeline, vault vocabulary, and documentation ([fee30ce](https://github.com/ncerny/alembic/commit/fee30ce002484d708306da60947093c3de566c0c))
* **detection:** end interactive sessions on mic-input drop (~17s -&gt; ~3-4s) ([ee84b1b](https://github.com/ncerny/alembic/commit/ee84b1ba85fd4c7ea13e220e3b7de948d0a207da))
* **detection:** end interactive sessions on mic-input drop (~17s → ~3-4s) ([1e54086](https://github.com/ncerny/alembic/commit/1e5408606d92d6541cee26ff5d5fab7545e610a8))
* **detection:** tiered detection, sticky sessions, title splits, silent-session discard ([2083470](https://github.com/ncerny/alembic/commit/2083470f5db34fb13ec456fe46d6b798c4cc8fcc))
* **detection:** tiered detection, sticky sessions, title splits, silent-session discard ([9eff15b](https://github.com/ncerny/alembic/commit/9eff15b1394bf50b5db96e9b2cf3a31225007369))
* **disclosure:** add transcription notice policy, settings UI, and reliable auto-send ([a4a0198](https://github.com/ncerny/alembic/commit/a4a01981939d944be67c1a960237f2bf55d42b1f))
* **disclosure:** ax-dump diagnostic + bounded, off-main TeamsChatPoster ([b662c94](https://github.com/ncerny/alembic/commit/b662c9460d5fe53a9f7f8fd15516960ebeae71cd))
* **disclosure:** ax-dump diagnostic and bounded, off-main TeamsChatPoster ([784b2d3](https://github.com/ncerny/alembic/commit/784b2d3925090dd9dedee57f82f1ce16c10eaecd))
* initial Obsidian meeting notes plugin scaffold ([18487ba](https://github.com/ncerny/alembic/commit/18487ba3b1942f8dfbe40cc6bcb26a888f90f3e2))
* Phase 1 foundation-only meeting detection core ([f357b84](https://github.com/ncerny/alembic/commit/f357b847de6adb37028c76df3aadef31cc588825))
* replace Azure CLI auth with PKCE OAuth flow ([5c90b8e](https://github.com/ncerny/alembic/commit/5c90b8ee3a301100ab816bca43100b1e6954ff15))
* replace BlackHole with ScreenCaptureKit for audio capture ([e3da923](https://github.com/ncerny/alembic/commit/e3da9232204cfdc1c8395eae65ad1b183c715959))
* replace OAuth/Direct Line with Power Automate flow integration ([ea730b0](https://github.com/ncerny/alembic/commit/ea730b0002e83a93526a7a86dc83228a40834950))
* **transcript:** name transcripts from live window title with YAML frontmatter ([aefd8ae](https://github.com/ncerny/alembic/commit/aefd8aea9c3d7a4c7696261dd81c9404fdf157e2))
* use Flow Management API instead of SAS HTTP trigger ([6f661ed](https://github.com/ncerny/alembic/commit/6f661ed1216dec74866839f3946c97a21ae0ff3c))
* **vocab:** add VocabularyStore, SettingsView, contextualStrings injection, rewrite docs ([a3c8df2](https://github.com/ncerny/alembic/commit/a3c8df217a8b1eee6aeb35f87a6d485c044c6f8a))
* wire M365 calendar integration into plugin pipeline ([a97d81f](https://github.com/ncerny/alembic/commit/a97d81f50179ff8f74fcb070515ab0abc64ad8a5))


### Bug Fixes

* add Bearer token auth for Power Automate flow trigger ([2162d32](https://github.com/ncerny/alembic/commit/2162d32c69f1e6e978d024b3137ae44bbdaed530))
* address code review findings for M365 integration ([cb26d95](https://github.com/ncerny/alembic/commit/cb26d959ba2764b87ce64da4145e961b177b169f))
* **alembic:** keep one transcript per meeting and stop silencing notifications ([#8](https://github.com/ncerny/alembic/issues/8)) ([f9d94d0](https://github.com/ncerny/alembic/commit/f9d94d01beee13079e3298ab1121eca24fd47589))
* **app:** stable signing for TCC, target filtering, live-window activation ([046918b](https://github.com/ncerny/alembic/commit/046918b111fa68ba91ec3f6993a50964e0e2abab))
* **app:** transcription emitted no results (untimed AnalyzerInput) ([f7dc971](https://github.com/ncerny/alembic/commit/f7dc9718343a7474ffaf90d6657430f06dcc9cd6))
* **auto-start:** re-enumerate capture targets on detection so late-launched apps work ([7e36735](https://github.com/ncerny/alembic/commit/7e3673527d36cec548882101230243bf36df06ca))
* build CA bundle from system keychains for az CLI ([ab33a7b](https://github.com/ncerny/alembic/commit/ab33a7b7cdedc028f1fad291f190a439f01567f5))
* **capture:** exclude Teams "Meeting compact view" PiP overlay from title selection ([2dcda63](https://github.com/ncerny/alembic/commit/2dcda63f324328f5bf8ad799b6007f24b014e01a))
* **capture:** fix multi-display stream failure and strip Teams title suffix ([32a957c](https://github.com/ncerny/alembic/commit/32a957c21f5fb4a8a7fa61dc3d9c25bc78655f9c))
* **capture:** name transcripts from frontmost meeting window, not longest title ([04658e9](https://github.com/ncerny/alembic/commit/04658e9d7d43d0ff5ddea313301b995e3e571e93))
* **check:** reject unknown subcommands instead of silently running the suite ([7c18beb](https://github.com/ncerny/alembic/commit/7c18bebb4805ecb8d5c21df9bd88db3f709c8d44))
* correct env ID parsing and restore node_modules deploy ([0386908](https://github.com/ncerny/alembic/commit/0386908381f27ead9e702dba776c0600fcf384ff))
* deploy app bundle to Application Support ([0615c7a](https://github.com/ncerny/alembic/commit/0615c7a9e2d4837d33bd6e514a5571c3efacfe4b))
* **disclosure:** open the meeting chat pane — AXPress with physical-click fallback ([#6](https://github.com/ncerny/alembic/issues/6)) ([e68f389](https://github.com/ncerny/alembic/commit/e68f38928051ab2322e98f293bda610be74e8c7d))
* **menu:** use systemImage initializer so menu-bar icon renders for all users ([87aea22](https://github.com/ncerny/alembic/commit/87aea227ccde17f3180941142b624da9425f3f9e))
* remove --scope from az login command ([7896542](https://github.com/ncerny/alembic/commit/7896542d72979f6fc0b8b1510a5af36f2ff9d986))
* **settings:** show path hints as in-field placeholders, not labels ([d1aa073](https://github.com/ncerny/alembic/commit/d1aa0730834743cd40e0c4e66749ef6e2d334412))
* strip SAS params from flow URL when using Bearer auth ([7bea1e8](https://github.com/ncerny/alembic/commit/7bea1e8b5e17de25a705de02a8a7d88e08d8a4d6))
* switch from Graph API to Outlook REST API ([5610ddf](https://github.com/ncerny/alembic/commit/5610ddf63ff7f7b56acba79e583146c43fc00e58))
* use --allow-no-subscriptions for az login ([7e3894a](https://github.com/ncerny/alembic/commit/7e3894aadff030f68aa258f65d84ee601e405d21))


### Performance Improvements

* **capture:** throttle SCK video to 1fps, lower pipeline QoS, skip idle title probes ([ea6c1a5](https://github.com/ncerny/alembic/commit/ea6c1a5534fc720285d910e547e299ca2df63b4f))
* **capture:** throttle SCK video, lower pipeline QoS, skip idle title probes ([f5fd3b0](https://github.com/ncerny/alembic/commit/f5fd3b0aaea3cf74d10374f8b504cdb5f8aa9a4b))
