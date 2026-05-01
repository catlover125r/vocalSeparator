# Stem Separator

A macOS app that separates any audio file into a **vocals track** and an **instrumental track** using [Demucs](https://github.com/facebookresearch/demucs) (Meta AI).

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.0-orange) ![Demucs](https://img.shields.io/badge/Demucs-4.0.1-green)

## Features

- Drag & drop any audio file onto the window (or use the file picker)
- Live progress output while Demucs runs
- Save vocals only, instrumental only, or both at once
- Supports MP3, WAV, FLAC, M4A, AIFF

## Requirements

- macOS 13 (Ventura) or later
- Python 3.11–3.13
- Xcode (to build)

## Setup

### 1. Install Python dependencies

```bash
pip3 install demucs torchcodec
```

If you're using Python.org's Python installer, also run the SSL certificate installer:

```
/Applications/Python 3.13/Install Certificates.command
```

> On first run, Demucs will automatically download the `htdemucs` model (~80 MB) and cache it at `~/.cache/torch/hub/checkpoints/`. You can pre-download it to avoid the wait:
> ```bash
> python3 -c "from demucs.pretrained import get_model; get_model('htdemucs')"
> ```

### 2. Build the app

```bash
git clone https://github.com/catlover125r/vocalSeparator.git
cd vocalSeparator

xcodebuild \
  -project StemSeparator.xcodeproj \
  -scheme StemSeparator \
  -configuration Release \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  CONFIGURATION_BUILD_DIR=./build \
  build
```

### 3. Install

```bash
cp -R ./build/StemSeparator.app /Applications/
codesign --sign - --force --deep /Applications/StemSeparator.app
```

Then open **Stem Separator** from your Applications folder.

## How It Works

1. Drop an audio file onto the window (or click **Choose File…**)
2. The app runs `demucs --two-stems vocals` on the file in the background
3. When complete, choose to save:
   - **Save Vocals** — the isolated vocal track
   - **Save Instrumental** — everything minus vocals
   - **Save Both** — pick a folder and both files are saved together

## Demucs Path Detection

The app looks for `demucs` at the following locations (in order):

- `/opt/homebrew/bin/demucs`
- `/usr/local/bin/demucs`
- `/Library/Frameworks/Python.framework/Versions/3.13/bin/demucs`
- `/Library/Frameworks/Python.framework/Versions/3.12/bin/demucs`
- `/Library/Frameworks/Python.framework/Versions/3.11/bin/demucs`
- Falls back to `which demucs`

## Project Structure

```
StemSeparator.xcodeproj/   Xcode project
StemSeparator/
  StemSeparatorApp.swift   App entry point
  ContentView.swift        UI + Demucs integration
  Info.plist               Bundle metadata
```
