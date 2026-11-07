# Third-party notices

`TraciveSDK` has no third-party code. These notices cover `TraciveSDKExtended` and
`TraciveSDKExtendedUI`, whose `TraciveReportCore` binary embeds these native components. They ship
inside your app.

| Component | Used for | Licence |
|---|---|---|
| [AvifKit](https://github.com/alfikri-rizky/AvifKit) 1.0.0 | Encoding evidence as AVIF | MIT |
| [libavif](https://github.com/AOMediaCodec/libavif), through AvifKit | AVIF container | BSD 2-Clause |
| [libaom](https://aomedia.googlesource.com/aom), through AvifKit | AV1 encoder | BSD 2-Clause, with the AOM Patent License |

The binary is built by the Kotlin SDK, which pins that version and moves it only by a reviewed change.

Everything else in the binary, such as the Kotlin runtime, kotlinx and Ktor, is Apache-2.0.
