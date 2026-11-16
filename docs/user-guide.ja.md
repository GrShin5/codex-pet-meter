# Codex Pet Hunger Meter ユーザーガイド

Codex Pet Hunger Meter は、Codex Pet の周囲に使用量の残量リングを重ねて表示するmacOS用のローカル補助ツールです。Codex本体やPet画像は変更せず、Codexのローカル状態と使用量情報を読んで透明なオーバーレイを描画します。

## 1. 事前条件

- macOS 13以降（macOS 27.0.1で検証。旧バージョンの実行は未検証）
- Xcode Command Line Tools
- Codexデスクトップアプリ
- Codex Pet が有効で、画面上に表示されていること
- このリポジトリのルートでコマンドを実行すること

## 2. 起動方法

一時的に起動する場合:

```bash
tools/run-hunger-meter.sh
```

このコマンドは毎回ビルドしてから、`build/CodexPetHungerMeter.app` 内の実行ファイルを起動します。動作確認や開発中の利用に向いています。

終了するには、macOSメニューバーの `Pet Meter` メニューから `Quit` を選びます。

## 3. インストール

ログイン時に自動起動する常用アプリとして入れる場合:

```bash
tools/install-hunger-meter.sh
```

このスクリプトは次を行います。

- アプリをビルドする
- `~/Applications/CodexPetHungerMeter.app` にコピーする
- `~/Library/LaunchAgents/com.codex-pet.hunger-meter.plist` を作成する
- `launchctl` でLaunchAgentを読み込み、すぐ起動する
- 標準出力ログを `/tmp/codex-pet-hunger-meter.out.log` に出す
- エラーログを `/tmp/codex-pet-hunger-meter.err.log` に出す

インストール後は、macOSログイン時に自動起動します。

Quit後にもう一度起動したい場合は、Finderで `ホーム > Applications > CodexPetHungerMeter.app` を開くか、Spotlightで `Pet Meter` と検索して起動してください。起動するとDockには残らず、macOSメニューバーに `Pet Meter` が戻ります。

## 4. アンインストール

インストール済みアプリと自動起動設定を削除する場合:

```bash
tools/uninstall-hunger-meter.sh
```

このスクリプトは次を削除します。

- `~/Library/LaunchAgents/com.codex-pet.hunger-meter.plist`
- `~/Applications/CodexPetHungerMeter.app`
- アプリ設定 `com.codex-pet.hunger-meter`

Codex本体、Codex Pet、`~/.codex/auth.json`、`~/.codex/logs_2.sqlite` は削除・変更しません。

## 5. ON / OFF の切り替え

アプリ起動中は、macOSメニューバーに `Pet Meter` が表示されます。

- `Hide Hunger Meter`: オーバーレイを非表示にする
- `Show Hunger Meter`: オーバーレイを再表示する
- `Refresh Now`: 使用量とリセット時刻を手動更新する
- `Quit`: アプリを終了する

`Hide Hunger Meter` は表示だけをOFFにします。アプリ自体は終了しません。表示状態はアプリ設定に保存され、次回起動時にも引き継がれます。

完全に停止したい場合は `Quit` を選んでください。ログイン時自動起動も止めたい場合は `tools/uninstall-hunger-meter.sh` を実行してください。

## 6. 表示の見方

### リング

- 外側リング: Weeklyリミットの残量
- 内側リング: 5hリミットの残量
- リングが長いほど残量が多い
- リングが短いほど残量が少ない

認識済みの個人Proプランで、ライブ取得したWeeklyが有効・5hウィンドウなし・不正または矛盾するウィンドウなしの場合、`5h No Limit` を静止した全周パステル虹色リングで表示し、リセット欄は `5h ---` になります。実際の5hウィンドウがある場合はその値を優先します。不明な期間は灰色と `—` で表示し、0%とは扱いません。

表示されるパーセントは「使用率」ではなく「残量」です。ライブAPIの `used_percent` を `100 - used_percent` に変換して表示しています。

### 情報バッヂ

- `Weekly 82%` のような表示: Weeklyリミット残量
- `5h 83%` のような表示: 5hリミット残量
- 上部の `W yyyy/MM/dd HH:mm`: Weeklyリミットのリセット日時
- 上部の `5h HH:mm`: 5hリミットのリセット時刻

日時はローカルタイムで表示されます。

### サイズ調整

リングの基本サイズは、現在のCodex Petのサイズに自動で追従します。

微調整したい場合は、餌箱画像の上にカーソルを合わせてください。餌箱の下に小さなバーが表示されます。このバーを左右にドラッグすると、Petサイズに対するリングの大きさを調整できます。調整値はアプリ設定に保存され、次回起動時にも引き継がれます。

餌箱画像のクリックによる手動更新は従来通りです。バーをドラッグしている間だけ、サイズ調整操作として扱われます。

### メニューの情報

`Pet Meter` メニューには次の状態が表示されます。

- `Outer Weekly`: 外側リングと同じWeekly残量
- `Inner 5h`: 内側リングと同じ5h残量
- `Weekly Reset`: Weeklyリセット日時
- `5h Reset`: 5hリセット時刻
- `Last Success`: 最後にライブ取得が成功した時刻
- `Data Source`: `Live` / `Cached` / `Unavailable`

`Data Source` の意味:

- `Live`: ChatGPT usage endpoint から直接取得した最新データ
- `Cached`: 同じアカウントの直近の成功結果をメモリ上で一時利用中（最大300秒。リセット時刻を過ぎた期間は不明）
- `Unavailable`: 利用可能な結果がない状態。不明な期間は灰色のリングと `—` を表示

## 7. 更新タイミング

通常は20秒ごとに自動更新し、macOSのスリープ復帰時にも取得します。重複した更新要求はまとめて実行し、アカウントが変わると以前の成功結果を破棄します。

自動更新では、リングやバッヂを一度消すアニメーションは使いません。表示中の数値やリング量だけが更新されます。

手動更新する方法:

- 餌箱画像をクリックする
- メニューバーの `Pet Meter` から `Refresh Now` を選ぶ

手動更新では、更新操作が分かりやすいように短いアニメーションが再生されます。リングが軽く再充填され、情報バッヂがフェードインします。餌箱画像は消えません。

## 8. マウス操作

オーバーレイは基本的にマウス入力を背面のCodex Petやチャット欄へ通します。

例外は餌箱画像の上だけです。餌箱上ではクリックを受け取り、使用量情報を手動更新します。

餌箱の上にカーソルを合わせてサイズ調整バーが出ている間は、餌箱とバーの部分だけマウス操作を受け取ります。それ以外の場所では、これまで通り背面のCodex Petやチャット欄へ入力を通します。

もしPetをドラッグできない、チャット入力ができない場合は、古い起動中プロセスが残っている可能性があります。`Pet Meter` メニューから `Quit` して、再度起動してください。

## 9. ステータス確認

アプリを開かずに現在の解析結果を見る場合:

```bash
tools/build-hunger-meter.sh
build/codex-pet-hunger-meter --status
```

ネットワークを使わない任意の旧ログ診断（アカウント一致は未確認。画面表示には使用しません）:

```bash
tools/build-hunger-meter.sh
build/codex-pet-hunger-meter --status --cached-only
```

プレビュー画像を生成する場合:

```bash
tools/build-hunger-meter.sh
build/codex-pet-hunger-meter --preview build/hunger-meter-preview.png --preview-fixture pro-no-limit --size 180 --side right --adjustment 1.0
```

プレビューの `--size` はCodex Petの幅として扱われます。Codex Pet側の現在のリサイズ範囲はおおよそ `80`〜`224` px です。

## 10. データ取得とプライバシー

ライブ取得では、`~/.codex/auth.json` のCodex OAuthトークンをメモリ上で読み、ChatGPT usage endpoint `/backend-api/wham/usage` にアクセスします。

ライブ取得に失敗した場合は、同じアカウントの成功結果をメモリ上で最大300秒だけ再利用します。リセット時刻を過ぎた期間は不明にします。使用量の永続キャッシュや、自動的な旧ログへの切り替えはありません。

このツールは次を行いません。

- Codex本体の変更
- Codex Pet画像の変更
- トークンの出力・保存（access tokenはHTTPSのusage endpointへの認証にのみ送信）
- usageレスポンスの保存
- 通常動作中のスクリーンショット保存（明示的なプレビューは架空データの画像を保存）
- Pet位置履歴の保存

保存されるアプリ設定は、表示ON/OFFとリングサイズの微調整値だけです。

詳細は `SECURITY.md` を参照してください。

## 11. トラブルシュート

### 表示されない

- Codex Pet が画面に表示されているか確認してください。
- `Pet Meter` メニューが `Show Hunger Meter` になっている場合は、それを選んで表示をONにしてください。
- `tools/run-hunger-meter.sh` で起動し直してください。

### 情報が古い

- `Pet Meter` メニューの `Data Source` と `Last Success` を確認してください。
- `Cached` の場合、ライブ取得に失敗し、同じアカウントの直近の成功結果を一時利用しています。小さな `Cached HH:mm` バッヂでも時刻を表示します。
- `Refresh Now` または餌箱クリックで手動更新してください。

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

### 完全に消したい

```bash
tools/uninstall-hunger-meter.sh
```

開発側の検証は `tools/verify-hunger-meter.sh` で実行できます。認証・通信・実ログ・設定書き込みを使わず、固定データの自己テストとPNGを生成します。固定データは `normal` / `pro-no-limit` / `unknown` / `cached`。`--anchor-status` はPet位置と画面・配置の安全な診断だけを出力します。現在のx/y形式と旧mascotオフセット形式に対応し、幅はアクティブな所有元のPet設定、`~/.codex/config.toml` の `[desktop]`、既定112pxの順に解決し、80〜224pxへ丸めて追従します。高さは現在の192:208比率から算出します。各ファイルの変更を別々に検知するため、サイズ設定の保存完了後に再起動なしで反映されます。一時的な読み取り失敗・書きかけ設定では直前の幅を維持し、有効なResetでは既定幅へ戻ります。旧形式の明示的なmascot寸法も維持します。

現在のPetの中央合わせは、画面が1枚で、CodexのPetウィンドウがソース由来の物理レイアウトと一意に一致する場合、所有プロセス・レイヤー・矩形の読み取り専用メタデータから実際の中心を解決します。保存x/yが変わらないリサイズにも追従します。未対応・曖昧な場合は既知の中心をサイズ変更中に維持し、保存位置の変化で移動を反映します。この代替経路では起動直後の古い保存中心は保証できません。画面撮影・ウィンドウ名・アクセシビリティ操作・プロセス接続は使いません。旧形式の実測寸法とは分けて扱います。`--anchor-status` にネイティブ座標か保存位置由来かを表示します。


リリースの `codex-pet-meter-0.1.1-macos-arm64.zip` はソースZIPとは別のApple silicon用アプリです。Intel版はなく、ad-hoc署名でDeveloper ID署名・公証はされていません。SHA-256チェックサムが付属します。ソースZIPからのインストールには上記のスクリプトを使います。
