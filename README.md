
# DeepEraseKit

DeepEraseKit is a universal Swift package for iOS and macOS that removes backgrounds in real time while capturing video. Powered by Apple's Vision framework, it supports multiple background options: none, blur, color, and image, making it ideal for virtual backgrounds and augmented reality applications.



https://github.com/user-attachments/assets/96589a8a-0aad-4d9d-a7f4-69379546d760



## Features
- **Real-time Background Removal**: Uses Vision framework for seamless segmentation.
- **Multiple Background Modes**:
  - None (transparent background)
  - Blur (adjustable intensity)
  - Color (custom solid color background)
  - Image (replace background with a custom image)
- **Universal Support**: Works across all iOS devices.
- **Optimized for Performance**: Uses Metal and Core Image for efficient processing.

## Installation
### Swift Package Manager
1. Open Xcode and go to **File > Swift Packages > Add Package Dependency**
2. Enter the repository URL: `https://github.com/abbasjoyia99/DeepEraseKit.git`
3. Choose the latest version and add it to your project.

## Usage
```swift
import DeepEraseKit

let backgroundManager = DeepEraseKit()
backgroundManager.setBackground(.blur(radius: 10.0))
backgroundManager.startCapturing()
```

### Changing Background
```swift
backgroundManager.setBackground(.color(UIColor.blue))
backgroundManager.setBackground(.image(UIImage(named: "background")))
```

## Requirements
- iOS 15.0+
- Swift 5.9
- Vision Framework

## Contribution
We welcome contributions! Please submit a pull request or open an issue.

## License
DeepEraseKit is available under the MIT license. See the LICENSE file for more details.

