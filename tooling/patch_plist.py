#!/usr/bin/env python3
import plistlib
import sys

if len(sys.argv) < 2:
    print("Usage: patch_plist.py <path_to_Info.plist>")
    sys.exit(1)

plist_path = sys.argv[1]

with open(plist_path, 'rb') as f:
    data = plistlib.load(f)

# 追加/修正必要键值，保持原生键值完好
data['CFBundleDisplayName'] = 'DSH Go'
data['NSCameraUsageDescription'] = '用于拍摄照片并发送给 DeepSeek Harness 分析。'
data['NSMicrophoneUsageDescription'] = '用于语音输入与 DeepSeek 对话。'
data['NSPhotoLibraryUsageDescription'] = '用于选择相册图片发送给 DeepSeek Harness。'
data['NSLocalNetworkUsageDescription'] = '用于连接局域网电脑上的 DeepSeek Harness 远程节点与设备通信。'
data['UIFileSharingEnabled'] = True
data['LSSupportsOpeningDocumentsInPlace'] = True
data['UIBackgroundModes'] = ['audio', 'fetch', 'processing']

with open(plist_path, 'wb') as f:
    plistlib.dump(data, f)

print(f"Patched {plist_path} successfully.")
