# Security and Privacy

Codex Pet Meter is designed as a local macOS companion overlay for personal use.

## What It Reads

- `~/.codex/.codex-global-state.json`
  - Used to find whether Codex Pet is open, where it is on screen, and the current pet size.
- `~/.codex/auth.json`
  - Used only in memory to call the live ChatGPT usage endpoint.
- `~/.codex/logs_2.sqlite`
  - Used as a local fallback when live usage cannot be refreshed.

## What It Does Not Do

- It does not modify Codex.
- It does not modify Codex Pet assets.
- It does not modify Codex Pet size settings.
- It does not import, export, paste, or print auth tokens.
- It does not store usage responses.
- It does not save screenshots.
- It does not transmit local logs or pet position data.

## What It Saves

- Whether the overlay is shown or hidden.
- The ring size fine-tune value selected from the food-bowl size bar.

## Network Behavior

The app attempts live usage refreshes against the ChatGPT usage endpoint using the same local Codex OAuth token already used by Codex. If a request fails, the app falls back to local logs.

For privacy and predictability, live refresh uses a fixed interval and does not start a rapid retry loop after failures.

You can verify the cached, no-network path at any time:

```bash
tools/build-hunger-meter.sh
build/codex-pet-hunger-meter --status --cached-only
```

This prints only the plan name, source, reset times, and remaining percentages. It does not print tokens or raw log rows.

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

Codex Pet Meter は、個人利用向けのローカルmacOS補助オーバーレイとして設計されています。

## 読み取るもの

- `~/.codex/.codex-global-state.json`
  - Codex Pet が開いているか、画面上の位置、現在のPetサイズを確認するために使います。
- `~/.codex/auth.json`
  - ライブのChatGPT使用量エンドポイントを呼び出すため、メモリ上でのみ使います。
- `~/.codex/logs_2.sqlite`
  - ライブ使用量を更新できない場合のローカルフォールバックとして使います。

## 行わないこと

- Codex本体は変更しません。
- Codex Petの画像素材は変更しません。
- Codex Petのサイズ設定は変更しません。
- 認証トークンをインポート、エクスポート、貼り付け、表示しません。
- 使用量レスポンスは保存しません。
- スクリーンショットは保存しません。
- ローカルログやPet位置データは送信しません。

## 保存するもの

- オーバーレイを表示するか非表示にするかの設定
- フードボウル下のサイズバーで選択したリングサイズの微調整値

## ネットワーク動作

このアプリは、Codexがすでに使用しているローカルのCodex OAuthトークンを使って、ChatGPT使用量エンドポイントにライブ更新を試みます。失敗した場合は、ローカルログにフォールバックします。

プライバシーと予測しやすさのため、ライブ更新は固定間隔で行い、失敗後に高速な再試行ループは開始しません。

キャッシュのみを使う、ネットワークなしの経路はいつでも確認できます。

```bash
tools/build-hunger-meter.sh
build/codex-pet-hunger-meter --status --cached-only
```

このコマンドが表示するのは、プラン名、データ取得元、リセット時刻、残量パーセントだけです。トークンや生のログ行は表示しません。

## アンインストール

次を実行します。

```bash
tools/uninstall-hunger-meter.sh
```

これにより次のものが削除されます。

- ログイン項目のLaunchAgent
- `~/Applications/CodexPetHungerMeter.app` にあるインストール済みアプリ本体
- アプリ設定ドメイン `com.codex-pet.hunger-meter`
