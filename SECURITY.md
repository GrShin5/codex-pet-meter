# Security and Privacy

Codex Pet Hunger Meter is designed as a local-only companion overlay for personal use.

## What It Reads

- `~/.codex/.codex-global-state.json`
  - Read only to find whether Codex Pet is open, its saved geometry, and the active owner’s pet-width override.
- macOS on-screen window metadata
  - Read only owner PID, layer and bounds for the running Codex app to resolve a unique supported single-screen pet window. No window titles, screenshots, accessibility input or process attachment are used.
- `~/.codex/config.toml`
  - Read only to resolve the numeric `[desktop]` pet width setting. Other configuration values are not exposed.
- `~/.codex/auth.json`
  - Used only in memory to call the live ChatGPT usage endpoint.
- `~/.codex/logs_2.sqlite`
  - Read only by the explicit `--status --cached-only` legacy diagnostic. Never used by the overlay.

## What It Does Not Do

- It does not modify Codex.
- It does not modify Codex Pet assets.
- It does not modify Codex Pet size settings.
- It does not import, export, paste, or print auth tokens.
- It does not persist usage responses.
- The running overlay does not save screenshots. Explicit `--preview` writes only synthetic fixture images.
- It does not transmit local logs or pet position data.

## What It Saves

- Whether the overlay is shown or hidden.
- The ring size fine-tune value selected from the food-bowl size bar.

## Network Behavior

The app attempts live usage refreshes against the ChatGPT usage endpoint using only the local Codex access token. It validates HTTP status and transport success. On failure, it can reuse the last successful response held in memory for the same account for up to 300 seconds. A period becomes unknown once its reset time passes; expired data is never shown as live. Account changes clear the previous success. No usage cache or account identity is persisted.

For privacy and predictability, live refresh uses a 20-second interval and refreshes on wake; overlapping requests coalesce. It does not start a rapid retry loop after failures.

An optional, unverified legacy log diagnostic (account identity unknown) is available without network access:

```bash
tools/build-hunger-meter.sh
build/codex-pet-hunger-meter --status --cached-only
```

This prints only safe usage summaries and timestamps. Legacy logs never establish No Limit. It does not print tokens or raw log rows.

## Uninstall

Run:

```bash
tools/uninstall-hunger-meter.sh
```

This removes:

- The login item LaunchAgent
- The installed app bundle in `~/Applications/CodexPetHungerMeter.app`
- The app preference domain `com.codex-pet.hunger-meter`

---

# セキュリティとプライバシー

このアプリは個人利用向けのローカル補助オーバーレイです。CodexやPet画像、Petサイズ設定は変更しません。

## 読み取る情報

- `~/.codex/.codex-global-state.json`: Petの表示状態、保存位置とサイズ、アクティブな所有元の幅設定を読み取ります。
- macOSの画面上のウィンドウメタデータ: 対象の所有プロセス、レイヤー、矩形だけを使い、対応する単一画面のPet位置を解決します。タイトル、画像、アクセシビリティ操作、プロセス接続は使いません。
- `~/.codex/config.toml`: `[desktop]` のPet幅を読み取ります。他の設定値は公開しません。
- `~/.codex/auth.json`: ライブ使用量取得のためトークンをメモリ内で読み取ります。
- `~/.codex/logs_2.sqlite`: 明示的な `--status --cached-only` 旧ログ診断だけが読みます。画面表示には使用しません。

## 保存と通信

表示のON/OFFとリングの微調整値を保存します。使用量レスポンス、Petの位置履歴、通常動作中のスクリーンショットは保存せず、ローカルログやPet位置を送信しません。明示的なプレビューは架空データ画像を書き出します。トークンは表示・コピー・保存せず、HTTPSの使用量取得に使用します。

ライブ取得は20秒ごととスリープ復帰時に行い、重複要求をまとめます。失敗時は同じアカウントの直近成功結果をメモリ内で最大300秒再利用できます。リセット時刻を過ぎた期間は不明とし、アカウント変更時は破棄します。永続使用量キャッシュや自動ログ切り替えはありません。

旧ログ診断はネットワークを使いませんが、アカウント一致は未確認で、No Limitの根拠にはなりません。使用量の要約と時刻のみを表示し、トークンや生ログ行は表示しません。アンインストールは `tools/uninstall-hunger-meter.sh` を実行してください。ログイン項目、インストール済みアプリ、アプリ設定を削除します。
