# Third-party notices

LocalScribe's own code is under the [MIT License](LICENSE). It uses the third-party work below, each under its own
licence. If you ship a built copy of LocalScribe, ship this file with it.

## Swift packages

Swift Package Manager downloads these when you build; none of their code is copied into this repository.

| Package | Licence | Copyright |
|---|---|---|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) (WhisperKit, SpeakerKit) | MIT | © 2024 argmax, inc. |
| [yyjson](https://github.com/ibireme/yyjson) | MIT | © 2020 YaoYuan |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | Apache-2.0 | Hugging Face |
| [swift-jinja](https://github.com/huggingface/swift-jinja) | Apache-2.0 | Hugging Face |
| [swift-crypto](https://github.com/apple/swift-crypto) | Apache-2.0 | © 2019 The SwiftCrypto Project |
| [swift-asn1](https://github.com/apple/swift-asn1) | Apache-2.0 | © 2022 The SwiftASN1 Project |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache-2.0 with Runtime Library Exception | Apple Inc. and the Swift project authors |
| [swift-collections](https://github.com/apple/swift-collections) | Apache-2.0 with Runtime Library Exception | Apple Inc. and the Swift project authors |

The full licence texts are in each package's repository and at
[apache.org/licenses/LICENSE-2.0](https://www.apache.org/licenses/LICENSE-2.0) and
[opensource.org/license/mit](https://opensource.org/license/mit).

### NOTICE files (Apache-2.0)

**swift-crypto**: Copyright 2019 The SwiftCrypto Project. Contains test vectors from Google's
[wycheproof](https://github.com/google/wycheproof) project and a derivation of files from
[SwiftNIO](https://github.com/apple/swift-nio), both under Apache-2.0.

**swift-asn1**: Copyright 2022 The SwiftASN1 Project. Contains derivations of scripts from
[SwiftNIO](https://github.com/apple/swift-nio) and
[Swift OpenAPI Generator](https://github.com/apple/swift-openapi-generator), both under Apache-2.0.

## Speech models

The app downloads these to your device the first time it needs them. They are not part of this repository.

| Model | Used for | Licence |
|---|---|---|
| [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml), Core ML builds of OpenAI's [Whisper](https://github.com/openai/whisper) | Transcription | MIT |
| [argmaxinc/speakerkit-coreml](https://huggingface.co/argmaxinc/speakerkit-coreml) by Argmax, built on [pyannote](https://github.com/pyannote/pyannote-audio) | Telling speakers apart | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |

LocalScribe uses the SpeakerKit models as published, without changes.

## Fonts

Bundled, unmodified, in `LocalScribeKit/Sources/LocalScribeUI/Fonts`, each next to its full licence text.

| Font | Licence | Copyright |
|---|---|---|
| [IBM Plex Serif](https://github.com/IBM/plex) | SIL Open Font License 1.1 | © 2017 IBM Corp., with Reserved Font Name "Plex" |
| [Hanken Grotesk](https://github.com/marcologous/hanken-grotesk) | SIL Open Font License 1.1 | © 2021 The Hanken Grotesk Project Authors |
