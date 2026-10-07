# Ephemeral Rocket.Chat on AWS

イベント当日だけ使う Rocket.Chat を、EC2 + CloudFront VPC オリジンで立てるための CloudFormation 一式です。**イベント後は全スタックを削除**してください（下記「後片付け」）。

## 構成

```
ユーザー
  → chat.example.com  (Route 53 Alias ← 手動で後付け)
  → CloudFront  (ACM証明書 + 独自ドメイン ← 手動で後付け / HTTPS終端 / WebSocket許可 / キャッシュ無効)
  → VPC Origin (HTTP:80)
  → EC2 t8i.medium (プライベートサブネット, Ubuntu 24.04)
       └ Docker Compose: Rocket.Chat + MongoDB(レプリカセット)

  ※ メンテ中は rocket.sh が /* ビヘイビア + viewer-request Function を追加し、
     全 URI を /error.html に書き換えて S3 の準備中ページを返す
     → S3 バケット (OAC で CloudFront からのみ読取可) / 準備中ページ
     ※ 502/503/504 のカスタムエラーレスポンスはバックストップとして併存
```

- **リージョン**: `us-east-1`
- EC2 はプライベートサブネット。CloudFront だけが 80 番に到達可能（CloudFront マネージドプレフィックスリストで制限）。
- SSH が必要なときだけ **EC2 Instance Connect Endpoint (EICE)** 経由。EICE は追加料金なし。
- SSM の VPC エンドポイントは**使わない**（課金回避）。
- NAT ゲートウェイは**別スタック**。Docker イメージ取得後に削除して課金を止められる。

### スタック構成とファイル

| 順序 | ファイル | 役割 | 寿命 |
|---|---|---|---|
| 1 | `01-network.yaml` | VPC・サブネット・IGW・ルートテーブル・EICE・SG | 常設（安い） |
| 2 | `02-nat.yaml` | NAT Gateway + EIP + プライベートRTへの既定ルート | **使い捨て**（高い） |
| 3 | `03-app.yaml` | EC2(Rocket.Chat) + CloudFront(VPCオリジン) + S3(準備中ページ) | イベント期間 |
| - | `error.html` | 停止中に表示する準備中ページ（S3 にアップロード） | - |

`ProjectName` パラメータ（既定 `ephemeral-rocketchat`）は3スタックで**同じ値**を使ってください。スタック間は Export/ImportValue で連携します。

---

## デプロイ手順

事前確認: `aws sts get-caller-identity` が通ること、リージョンが `us-east-1` であること。

### 1. ネットワークスタック

```bash
aws cloudformation deploy \
  --region us-east-1 \
  --stack-name ephemeral-rocketchat-network \
  --template-file 01-network.yaml \
  --capabilities CAPABILITY_IAM
```

> `01-network.yaml` は CloudFront のオリジン向けプレフィックスリスト ID を解決する小さな Lambda（カスタムリソース）を含むため `CAPABILITY_IAM` が必要です。

### 2. NAT スタック（イメージ取得のため一時的に作成）

```bash
aws cloudformation deploy \
  --region us-east-1 \
  --stack-name ephemeral-rocketchat-nat \
  --template-file 02-nat.yaml
```

### 3. アプリスタック（EC2 + CloudFront）

```bash
aws cloudformation deploy \
  --region us-east-1 \
  --stack-name ephemeral-rocketchat-app \
  --template-file 03-app.yaml \
  --capabilities CAPABILITY_IAM
```

- `UbuntuAmiId` は SSM パラメータで最新の Ubuntu 24.04 を自動解決します。
- `RocketChatVersion`（既定 `7.4.0`）や `RootUrl` を変えたいときは `--parameter-overrides Key=Value` を付けてください。
- CloudFront ディストリビューションと VPC オリジンのデプロイは**最大15分**ほどかかります。

### 4. 起動確認

アプリスタック作成後、EC2 内で Docker が起動するまで数分かかります。確認したいときは EICE 経由で SSH:

```bash
# InstanceId はアプリスタックの出力に出る
INSTANCE_ID=$(aws cloudformation describe-stacks \
  --region us-east-1 --stack-name ephemeral-rocketchat-app \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)

aws ec2-instance-connect ssh --region us-east-1 --instance-id "$INSTANCE_ID"
# 接続後:
sudo docker compose -f /opt/rocketchat/compose.yml ps
sudo docker compose -f /opt/rocketchat/compose.yml logs -f rocketchat
```

Rocket.Chat が `Server is running on port 3000` 相当のログを出せば OK です。

---

## デプロイ後の手動作業（HTTPS + 独自ドメイン）

CloudFront はまず**デフォルトドメイン（`xxxx.cloudfront.net`）のみ**で立ち上がります。ここに独自ドメインと証明書を手で足します。

### A. CloudFront ドメインを確認

```bash
aws cloudformation describe-stacks \
  --region us-east-1 --stack-name ephemeral-rocketchat-app \
  --query "Stacks[0].Outputs[?OutputKey=='CloudFrontDomainName'].OutputValue" --output text
# 例: d1234abcd.cloudfront.net
```

### B. ACM 証明書を発行（必ず `us-east-1`）

1. ACM（バージニア北部）で `chat.example.com` のパブリック証明書をリクエスト（DNS 検証）。
2. 表示される **CNAME 検証レコード**を Route 53 の `example.com` ホストゾーンに追加（コンソールの「Route 53 でレコードを作成」ボタンでOK）。
3. 証明書の状態が **発行済み (Issued)** になるまで待つ。

### C. CloudFront に独自ドメイン + 証明書を追加

対象ディストリビューション（アプリスタック出力の `CloudFrontDistributionId`）の設定で:

- **代替ドメイン名 (CNAME)**: `chat.example.com`
- **カスタム SSL 証明書**: B で発行した ACM 証明書を選択

変更を保存し、デプロイ完了（`Deployed`）まで待つ。

### D. Route 53 に本番レコードを追加

`example.com` ホストゾーンに:

- レコード名: `ephemeral-rocketchat`
- タイプ: `A`（エイリアス ON）
- エイリアス先: CloudFront ディストリビューション（A で確認したドメイン）

反映後、`https://chat.example.com` にアクセスするとセットアップウィザードが表示されます。管理者アカウントを作成して完了です。

---

## ⚠️ 重要: 03 を再 deploy するとカスタムドメインが外れる

上記 C で**カスタムドメインと ACM 証明書をコンソールで手動設定**した場合、その設定は `03-app.yaml` のテンプレートには**書かれていません**。この状態で `03-app.yaml` をそのまま再 `deploy` すると、CloudFormation が「テンプレートに無い設定＝不要」と判断して、手動で足した **代替ドメイン名と証明書を削除**します。結果 `https://chat.example.com` にアクセスできなくなります。

**対策（どちらか）:**

- **(推奨) 手動設定をテンプレートに取り込む** — `03-app.yaml` の `DistributionConfig` に以下を追記してから `deploy` する。こうすればテンプレートと実態が一致し、再 deploy しても崩れない。

  ```yaml
  # DistributionConfig: の中に追加
  Aliases:
    - chat.example.com
  ViewerCertificate:
    AcmCertificateArn: arn:aws:acm:us-east-1:123456789012:certificate/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    SslSupportMethod: sni-only
    MinimumProtocolVersion: TLSv1.2_2021
  ```

  証明書 ARN は次で確認:

  ```bash
  aws acm list-certificates --region us-east-1 \
    --query "CertificateSummaryList[?DomainName=='chat.example.com'].CertificateArn" \
    --output text
  ```

- **(非推奨) テンプレートを再 deploy しない** — 以降の変更も全部コンソールで手動対応する。IaC から外れるので管理が煩雑になる。

> 現状、S3 エラーページ（下記）を反映するには 03 の再 deploy が必要です。**先に上記の `Aliases` / `ViewerCertificate` をテンプレートへ取り込んでから** deploy してください。

---

## 停止中の「準備中」ページ（S3 + CloudFront Function）

当日までインスタンスを**停止**しておく運用のための仕組みです。メンテ中は `rocket.sh stop` が CloudFront に `/*` ビヘイビア（S3 オリジン `errorpage-s3-origin`）を追加し、そこへ **viewer-request の CloudFront Function** を関連付けます。この Function が**あらゆる URI を `/error.html` に書き換える**ので、`/` だけでなく `/channel/general` のような任意パスでも準備中ページが出ます。S3 配信なので EC2 が止まっていても表示できます。

> なぜ Function が要るのか: キャッシュビヘイビアは「どのオリジンへ送るか」を決めるだけで URI は書き換えません。また `DefaultRootObject` は `/` へのリクエストにしか効かず、`/channel/general` のようなサブパスには適用されません（AWS 公式ドキュメントでも明記）。そのため以前の「`/*` を S3 へ向け + `DefaultRootObject=error.html`」という構成では、任意パスが S3 の存在しないオブジェクトを取りに行ってエラーになり得ました。viewer-request Function で URI を `/error.html` に書き換えることで、どのパスでも確実に準備中ページを返します。

Function は `03-app.yaml` に `AWS::CloudFront::Function`（論理 ID `MaintenanceRewriteFunction`）として定義され、その ARN をスタック出力 `MaintenanceFunctionArn` で公開します。`rocket.sh stop` はこの出力を読み、`/*` ビヘイビアに関連付けます。S3 まわりの構成（S3 バケット + OAC + バケットポリシー + セカンドオリジン + `/error.html` のキャッシュビヘイビア）も `03-app.yaml` に含まれています。

> `502/503/504` のカスタムエラーレスポンス（S3 の `error.html` を `200` で返す）は**バックストップ**として残しています。`/*` の切り替えが主、エラーレスポンスは保険、という二段構えです。

**セットアップ手順:**

1. 03 を deploy（上の「⚠️ 重要」を踏まえて、先に `Aliases`/`ViewerCertificate` を取り込んでから）。S3 バケットが作られる。

2. バケット名を取得してアップロード:

   ```bash
   BUCKET=$(aws cloudformation describe-stacks --region us-east-1 \
     --stack-name ephemeral-rocketchat-app \
     --query "Stacks[0].Outputs[?OutputKey=='ErrorPageBucketName'].OutputValue" --output text)

   aws s3 cp error.html "s3://$BUCKET/error.html" \
     --content-type "text/html; charset=utf-8"
   ```

3. 動作確認: `./rocket.sh stop` を実行 → `https://chat.example.com/` でも `.../channel/general` でも準備中ページが出る。

### 当日の停止 / 再開

EC2 の停止/開始と CloudFront の切り替えをまとめて行う `rocket.sh` を使います（`aws ec2 stop/start` を手で叩く必要はありません）。対象リソースはスタック出力から自動解決します。

```bash
# 停止（EC2 停止 + /* ビヘイビア追加 → 準備中ページが全パスで出るようになる）
./rocket.sh stop

# 当日に再開（EC2 開始 + /* ビヘイビア削除 + 旧構成の DefaultRootObject クリア）
./rocket.sh start
```

> 前提: `rocket.sh stop` は CloudFront Function の ARN をスタック出力 `MaintenanceFunctionArn` から読むため、**更新版の `03-app.yaml` を先に deploy**しておく必要があります（Function が未作成だと stop は中断します）。
> `rocket.sh` は `aws` CLI と `jq` に依存します。環境変数 `REGION` / `STACK_NAME` で上書き可能です。
> CloudFront の反映には数分かかります。再開後、通常画面に戻るのも同様です。
> インスタンスを再開すると Docker コンテナは `restart: unless-stopped` で自動復帰します。
> 注意: 停止/再開でプライベート IP は変わりませんが、停止中は EICE 経由の SSH もできません（起動中のみ）。
> `rocket.sh` は冪等です。既にメンテ中に `stop` を、通常時に `start` を実行しても害はありません。

---

## NAT を落としてコストを止める

Docker イメージの取得が終わっていれば、NAT スタックを削除して NAT 課金を止められます。EC2・CloudFront はそのまま動き続けます（プライベートサブネットからの外向き通信だけが止まる）。

```bash
aws cloudformation delete-stack --region us-east-1 --stack-name ephemeral-rocketchat-nat
```

> 注意: NAT を落とすと Rocket.Chat の外向き通信（cloud.rocket.chat 登録、モバイルプッシュ通知ゲートウェイ、外部URLプレビューなど）は使えなくなります。チャット自体のデモには影響しません。再び必要になったら `02-nat.yaml` を再デプロイすればルートが復活します。

---

## 後片付け（イベント終了後）

**作成と逆順**で削除します。削除し忘れると EC2・CloudFront・（残っていれば）NAT の課金が続くので、当日中に実施してください。

```bash
# 0. S3 エラーページバケットを空にする（空でないとアプリスタック削除が失敗する）
BUCKET=$(aws cloudformation describe-stacks --region us-east-1 \
  --stack-name ephemeral-rocketchat-app \
  --query "Stacks[0].Outputs[?OutputKey=='ErrorPageBucketName'].OutputValue" --output text)
aws s3 rm "s3://$BUCKET" --recursive

# 1. アプリ（EC2 + CloudFront + S3）
aws cloudformation delete-stack --region us-east-1 --stack-name ephemeral-rocketchat-app
aws cloudformation wait stack-delete-complete --region us-east-1 --stack-name ephemeral-rocketchat-app

# 2. NAT（まだ残っていれば）
aws cloudformation delete-stack --region us-east-1 --stack-name ephemeral-rocketchat-nat
aws cloudformation wait stack-delete-complete --region us-east-1 --stack-name ephemeral-rocketchat-nat

# 3. ネットワーク
aws cloudformation delete-stack --region us-east-1 --stack-name ephemeral-rocketchat-network
```

手動で作ったものも忘れずに削除してください:

- Route 53: `ephemeral-rocketchat` の A(エイリアス) レコード、および ACM の CNAME 検証レコード
- ACM: 発行した証明書（us-east-1）

> ネットワークスタックの削除は、アプリスタック削除で CloudFront の VPC オリジン用 ENI が消えてからでないと失敗することがあります。上記の順序（app → nat → network）と `wait` を守ってください。

---

## 補足メモ

- `t8i.medium` は 2 vCPU / 4 GiB。Rocket.Chat + MongoDB の最小ラインです。
- サブネットは `us-east-1a` / `us-east-1b` を既定にしています（CloudFront VPC オリジン非対応の `use1-az3` を回避）。別AZにしたい場合は `01-network.yaml` の `AzA` / `AzB` を変更。
- 検証コマンド: `cfn-lint -r us-east-1 -i W1030 -- 01-network.yaml 02-nat.yaml 03-app.yaml`
  （`W1030` は cfn-lint の内蔵スペックが新しい `t8i` を未収録なだけの誤検知。EC2 API で実在を確認済み。）

---

