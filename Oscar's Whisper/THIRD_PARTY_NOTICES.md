# Third-party notices

Oscar's Whisper ships the following third-party components. This file is copied
into the installed app's `resources` folder.

| Component                                                                                                  | Used for                        | License                                                               |
| ---------------------------------------------------------------------------------------------------------- | ------------------------------- | --------------------------------------------------------------------- |
| [Electron](https://github.com/electron/electron) 44.9.0                                                    | App runtime                     | MIT (Chromium and Node.js components: see `LICENSES.chromium.html`)   |
| [uiohook-napi](https://github.com/SnosMe/uiohook-napi) 1.5.5                                               | Global hotkeys, paste keystroke | MIT                                                                   |
| [libuiohook](https://github.com/kwhat/libuiohook), compiled into uiohook-napi                              | Keyboard hook                   | LGPL-3.0-or-later; its source is included in the app's unpacked files |
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (`sherpa-onnx-node`) 1.13.8                           | Speech-to-text engine           | Apache-2.0                                                            |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime), shipped inside sherpa-onnx                       | Neural network inference        | MIT                                                                   |
| [NVIDIA Parakeet TDT 0.6B v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2), int8 sherpa-onnx export | Speech-to-text model            | CC-BY-4.0                                                             |

The speech model is "parakeet-tdt-0.6b-v2" by NVIDIA, licensed under
[Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/).
This app uses the int8-quantized ONNX export published by the sherpa-onnx project
(`sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8`). The weights are not modified
further.
