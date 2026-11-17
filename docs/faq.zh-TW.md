[English](faq.md) | [简体中文](faq.zh-CN.md) | **繁體中文** | [日本語](faq.ja.md) | [Español](faq.es.md) | [Français](faq.fr.md) | [Русский](faq.ru.md)

# 常見問題

### 第一次打開為什麼被系統擋住？

App 使用自簽憑證，尚無 Developer ID 簽章，也未經 Apple 公證。到「系統設定 → 隱私權與安全性」按「強制打開」放行一次，或者執行 `xattr -d com.apple.quarantine /Applications/Bowerbird.app`。

### 為什麼需要輔助使用權限？

按 Return 時替你在原本的 App 裡按 ⌘V。第一次貼上時才會要求。不給也能用，Return 只拷貝，你自己貼上。

### 給了權限，但 Return 貼不出來。

授權綁定 App 的簽章，開關可能看起來是開的，對應的卻是舊簽章。到「系統設定 → 隱私權與安全性 → 輔助使用」，用「−」移除 Bowerbird，再用「+」加回來。

### 關掉了權限，App 還顯示已授權。

macOS 不會通知執行中的 App。結束 Bowerbird 再打開。

### 需要螢幕錄製或完整磁碟取用權限嗎？

不需要。圖片來自剪貼板，檔案只儲存路徑。

### 會連網嗎？

不會。不回報、不檢查更新、不同步。

### 資料在哪裡？

`~/Library/Application Support/Bowerbird/`：一個 SQLite 資料庫加上圖片檔，未加密。設定在 `defaults` 的 `app.bowerbird.mac` 網域。

### 怎麼全部刪掉？

「設定 → 記錄 → 清除 → 全部記錄」會清掉記錄；已固定的項目有自己的清除按鈕，在下面一列。同一頁的「結束時清除」會在每次結束時自動清掉，固定的保留。要完全不留痕跡，結束 App 後執行：

```sh
rm -rf ~/Library/Application\ Support/Bowerbird
defaults delete app.bowerbird.mac
```

### 哪些內容不會記錄？

- 密碼管理工具標示為密碼的內容。
- 從忽略列表裡的 App 拷貝的內容。預設有 1Password、Bitwarden 和鑰匙圈存取。
- 符合忽略規則的文字。
- 暫停記錄期間拷貝的任何內容。

### 記錄保留多久？

文字和檔案 30 天，圖片 7 天，可在「設定 → 記錄」裡更改。固定的項目永久保留。

### 為什麼找不到我的截圖？

macOS 預設把截圖存成桌面上的檔案，不會放進剪貼板，Bowerbird 看不到。改按 ⌃⇧⌘4，截圖會直接拷貝到剪貼板；或者按 ⇧⌘5，在「選項」裡把「儲存到」改成「剪貼板」。

### 收得到 iPhone、iPad 上拷貝的內容嗎？

文字和圖片可以，在「設定 → 記錄」裡打開。檔案不行。
