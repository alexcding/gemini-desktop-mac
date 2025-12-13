# Gemini Desktop for macOS (Unofficial)

An **unofficial macOS desktop wrapper** for Google Gemini, built as a lightweight desktop app that loads the official Gemini website.

![Desktop](docs/desktop.png)

![Chat Bar](docs/chat_bar.png)

> **Disclaimer:**
> This project is **not affiliated with, endorsed by, or sponsored by Google**.
> "Gemini" is a trademark of **Google LLC**.
> This app does not modify, scrape, or redistribute Gemini content — it simply loads the official website.

---

## Features

### 悬浮聊天栏
- **快捷访问面板** - 悬浮窗口，始终置顶于所有应用之上

### 全局快捷键
- **切换聊天栏** - 在设置中自定义快捷键，随时随地呼出/隐藏聊天栏
- 可视化快捷键录制器，设置简单直观

### 菜单栏应用
- **常驻菜单栏** - 轻量级菜单栏应用，不占用 Dock 栏空间
- **快捷菜单** - 一键访问：打开 Gemini、切换聊天栏、设置、退出
- **开机自启** - 可选随 Mac 启动

### 其他功能
- 原生 macOS 桌面体验
- 轻量级 WebView 封装
- 可调节字体大小 (80%-120%)
- 支持摄像头和麦克风（用于 Gemini 语音/视频功能）
- 隐私控制：可清除网站数据
- 使用官方 Gemini 网页界面
- 无追踪、无数据收集
- 开源

---

## What This App Is (and Isn't)

**This app is:**
- A thin desktop wrapper around `https://gemini.google.com`
- A convenience app for macOS users

**This app is NOT:**
- An official Gemini client
- A replacement for Google's website
- A modified or enhanced version of Gemini
- A Google-authored product

All functionality is provided entirely by the Gemini web app itself.

---

## Login & Security Notes

- Authentication is handled by Google on their website
- This app does **not** intercept credentials
- No user data is stored or transmitted by this app

> Note: Google may restrict or change login behavior for embedded browsers at any time.

---

## Installation

### Download
- Grab the latest release from the **Releases** page
  *(or build from source below)*

### Build from Source
```bash
git clone https://github.com/alexcding/gemini-desktop-mac.git
cd gemini-desktop-mac
open GeminiMac.xcodeproj
# Build and run in Xcode
```
