# Codex Pet Meter ユーザーガイド

Codex Pet Meter は、Codex Pet の周りに使用量の残量リングを表示するmacOS用の非公式補助アプリです。

Codex本体やCodex Petの画像は変更しません。自分のMac上にあるCodexの状態と使用量情報を読み、Petに追従する透明なオーバーレイを表示します。

## 1. 事前に必要なもの

- macOS
- Codexデスクトップアプリ
- Codex Petが画面に表示されていること
- Xcode Command Line Tools
- このリポジトリのフォルダ

Xcode Command Line Toolsが入っていない場合は、Terminalで次を実行してください。

```bash
xcode-select --install
```

## 2. インストール

Terminalでこのフォルダを開き、次を実行します。

```bash
tools/install-hunger-meter.sh
```

インストールすると、次が行われます。

- アプリをビルドする
- `~/Applications/CodexPetHungerMeter.app` にコピーする
- `~/Library/LaunchAgents/com.codex-pet.hunger-meter.plist` を作成する
- すぐにアプリを起動する
- 標準出力ログを `/tmp/codex-pet-hunger-meter.out.log` に出す
- エラーログを `/tmp/codex-pet-hunger-meter.err.log` に出す

起動すると、macOSのメニューバーに `Pet Meter` が表示されます。インストール後はmacOSログイン時にも自動起動します。

## 3. 終了と再起動

一時的に止める場合は、メニューバーの `Pet Meter` から `Quit` を選びます。

もう一度起動する場合は、Finderで `ホーム > Applications > CodexPetHungerMeter.app` を開くか、Spotlightで `Pet Meter` と検索してください。このアプリはDockには残りません。起動すると、macOSメニューバーに `Pet Meter` が戻ります。

## 4. 更新方法

Gitでインストールした場合:

```bash
cd codex-pet-meter
git pull
tools/install-hunger-meter.sh
```

ZIPでダウンロードした場合は、GitHubから最新ZIPをもう一度ダウンロードして解凍し、新しいフォルダでTerminalを開いて次を実行します。

```bash
tools/install-hunger-meter.sh
```

インストーラを再実行すると、`~/Applications/CodexPetHungerMeter.app` が置き換わり、ログイン時自動起動の設定も読み込み直されます。

## 5. アンインストール

インストール済みアプリと自動起動設定を削除する場合:

```bash
tools/uninstall-hunger-meter.sh
```

この操作で削除されるもの:

- `~/Library/LaunchAgents/com.codex-pet.hunger-meter.plist`
- `~/Applications/CodexPetHungerMeter.app`
- アプリ設定ドメイン `com.codex-pet.hunger-meter`

Codex本体、Codex Pet、`~/.codex/auth.json`、`~/.codex/logs_2.sqlite` は削除・変更しません。

## 6. 表示の見方

- 外側リング: Weeklyリミットの残量
- 内側リング: 5時間リミットの残量
- 上部表示: リセット時刻
- フードボウル: クリックすると手動更新

表示されるパーセントは「使用済み」ではなく「残量」です。内部APIやローカルログの `used_percent` を `100 - used_percent` に変換して表示しています。

## 7. サイズ調整

リングの基本サイズは、現在のCodex Petのサイズに自動で追従します。

微調整したい場合は、フードボウル画像の上にカーソルを合わせてください。フードボウルの下に小さなバーが表示されます。このバーを左右にドラッグすると、Petサイズに対するリングの大きさを調整できます。調整値はアプリ設定に保存され、次回起動時にも引き継がれます。

フードボウル画像のクリックによる手動更新は従来通りです。バーをドラッグしている間だけ、サイズ調整操作として扱われます。

## 8. メニュー

`Pet Meter` メニューでは次を操作・確認できます。

- `Hide Hunger Meter`: オーバーレイを非表示にする
- `Show Hunger Meter`: オーバーレイを再表示する
- `Refresh Now`: 使用量とリセット時刻を手動更新する
- `Outer Weekly`: 外側リングと同じWeekly残量
- `Inner 5h`: 内側リングと同じ5時間残量
- `Weekly Reset`: Weeklyリセット日時
- `5h Reset`: 5時間リセット時刻
- `Data Updated`: 表示中データを取得した時刻
- `Data Source`: `Live` / `Cached` / `Unavailable`
- `Quit`: アプリを終了する

`Hide Hunger Meter` は表示だけをOFFにします。アプリ自体は終了しません。

## 9. マウス操作

オーバーレイは基本的にマウス入力を背面のCodex Petやチャット欄へ通します。

例外は、フードボウル画像と、サイズバーが表示されている間のサイズバー部分だけです。フードボウルをクリックすると使用量データを手動更新します。サイズバーをドラッグするとリングサイズを調整します。それ以外の場所では入力を背面へ通します。

もしPetをドラッグできない、チャット入力ができない場合は、古い起動中プロセスが残っている可能性があります。`Pet Meter` メニューから `Quit` して、再度起動してください。

## 10. Codexにインストールを任せる場合

Terminal操作に慣れていない場合は、CodexにこのリポジトリURLを渡して、セットアップを依頼できます。

コピー用プロンプト:

```text
以下のリポジトリから、macOS用のCodex Pet Meterをインストールしてセットアップしてください。

https://github.com/GrShin5/codex-pet-meter

まずREADMEを確認し、このリポジトリだけを使ってインストールしてください。各手順を初心者にも分かる言葉で説明し、可能であれば検証スクリプトも実行してください。ローカルのトークンやCodexアカウント関連ファイルは、表示・コピー・アップロードしないでください。
```

Codexには、リポジトリのダウンロードまたはclone、`tools/install-hunger-meter.sh` の実行、メニューバーに `Pet Meter` が表示されたことの確認、アンインストール方法の説明まで依頼してください。

## 11. ステータス確認とプレビュー

アプリを開かずに現在の解析結果を見る場合:

```bash
tools/build-hunger-meter.sh
build/codex-pet-hunger-meter --status
```

ネットワークを使わず、ローカルキャッシュだけを確認する場合:

```bash
tools/build-hunger-meter.sh
build/codex-pet-hunger-meter --status --cached-only
```

プレビュー画像を生成する場合:

```bash
tools/build-hunger-meter.sh
build/codex-pet-hunger-meter --preview build/hunger-meter-preview.png --size 180
```

プレビューの `--size` はCodex Petの幅として扱われます。Codex Pet側の現在のリサイズ範囲はおおよそ `80`〜`224` px です。

## 12. データと安全性

ライブ取得では、`~/.codex/auth.json` のCodex OAuthトークンをメモリ上で読み、ChatGPT usage endpointにアクセスします。

ライブ取得に失敗した場合は、`~/.codex/logs_2.sqlite` のローカルログから使用量イベントだけを読みます。

このツールは次を行いません。

- Codex本体の変更
- Codex Pet画像の変更
- Codex Petのサイズ設定変更
- トークンの出力・保存・外部送信
- usageレスポンスの保存
- スクリーンショット保存
- Pet位置履歴の保存

保存されるアプリ設定は、表示ON/OFFとリングサイズの微調整値だけです。

詳細は [SECURITY.md](../SECURITY.md) を参照してください。

## 13. トラブルシュート

### 表示されない

- Codex Pet が画面に表示されているか確認してください。
- `Pet Meter` メニューが `Show Hunger Meter` になっている場合は、それを選んで表示をONにしてください。
- `tools/run-hunger-meter.sh` で起動し直してください。

### 情報が古い

- `Pet Meter` メニューの `Data Source` と `Data Updated` を確認してください。
- `Cached` の場合、ライブ取得に失敗してローカルログの値を使っています。
- `Refresh Now` またはフードボウルクリックで手動更新してください。

### 自動起動しない

再インストールしてください。

```bash
tools/install-hunger-meter.sh
```

それでも起動しない場合は、ログを確認してください。

```bash
tail -n 100 /tmp/codex-pet-hunger-meter.err.log
tail -n 100 /tmp/codex-pet-hunger-meter.out.log
```

## 14. 配布ZIPを作る場合

配布用ZIPを作る場合は次を実行します。

```bash
scripts/package-release.sh
```

生成されたZIPは `dist/` に入ります。
