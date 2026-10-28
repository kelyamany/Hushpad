# Third-party notices

Hushpad's own code is under the [MIT License](LICENSE). It uses the third-party work below, each under its own
licence. If you ship a built copy of Hushpad, ship this file with it.

## Swift packages

Swift Package Manager downloads these when you build; none of their code is copied into this repository.

| Package | Licence | Copyright |
|---|---|---|
| [Argmax Open-Source SDK](https://github.com/argmaxinc/argmax-oss-swift) (WhisperKit, SpeakerKit) | MIT | © 2024 argmax, inc. |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache-2.0 with Runtime Library Exception | Apple Inc. and the Swift project authors |

The full licence texts are in each package's repository and at
[apache.org/licenses/LICENSE-2.0](https://www.apache.org/licenses/LICENSE-2.0) and
[opensource.org/license/mit](https://opensource.org/license/mit).

### NOTICE (Apache-2.0)

The Argmax Open-Source SDK includes code derived from Hugging Face's
[swift-transformers](https://github.com/huggingface/swift-transformers) (Hub and Tokenizers), Copyright 2022 Hugging Face
SAS, under Apache-2.0 and modified by Argmax, Inc. See its
[NOTICES](https://github.com/argmaxinc/argmax-oss-swift/blob/main/NOTICES) file.

## Speech models

The app downloads these to your device the first time it needs them. They are not part of this repository.

| Model | Used for | Licence |
|---|---|---|
| [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml), Core ML builds of OpenAI's [Whisper](https://github.com/openai/whisper) | Transcription | MIT |
| [argmaxinc/speakerkit-coreml](https://huggingface.co/argmaxinc/speakerkit-coreml) by Argmax, built on [pyannote](https://github.com/pyannote/pyannote-audio) | Telling speakers apart | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |

Hushpad uses the SpeakerKit models as published, without changes.

## Fonts

Bundled, unmodified, in `HushpadKit/Sources/HushpadUI/Fonts`, each next to its full licence text.

| Font | Licence | Copyright |
|---|---|---|
| [IBM Plex Serif](https://github.com/IBM/plex) | SIL Open Font License 1.1 | © 2017 IBM Corp., with Reserved Font Name "Plex" |
| [Hanken Grotesk](https://github.com/marcologous/hanken-grotesk) | SIL Open Font License 1.1 | © 2021 The Hanken Grotesk Project Authors |
