#!/usr/bin/env bash
#
# rocket.sh - Ephemeral Rocket.Chat メンテ切り替えスクリプト
#
#   rocket.sh stop   停止(メンテ)化:
#     1. EC2 インスタンスを停止
#     2. CloudFront ビヘイビアに /* (errorpage-s3-origin) を /error.html の直後へ追加。
#        併せてメンテ用 CloudFront Function を viewer-request として関連付け、
#        あらゆる URI を /error.html に書き換える。
#
#   rocket.sh start  再開:
#     1. EC2 インスタンスを開始
#     2. CloudFront ビヘイビア /* (errorpage-s3-origin) を削除
#     3. CloudFront デフォルトルートオブジェクトをクリア(旧構成の後始末)
#
# 補足: キャッシュビヘイビアは「どのオリジンへ送るか」を決めるだけで URI は書き換えない。
#       DefaultRootObject も / にしか効かないため、/channel/general のような任意パスを
#       準備中ページに向けるには viewer-request Function での URI 書き換えが必要。
#       Function は 03-app.yaml で定義し、ARN をスタック出力 MaintenanceFunctionArn で公開する。
#       502/503/504 のカスタムエラーレスポンスはバックストップとして残している。
#
# 依存: aws CLI, jq
# 対象リソースは CloudFormation スタック (ephemeral-rocketchat-app) の出力から自動取得します。
#
set -euo pipefail

# --- 設定 -------------------------------------------------------------------
REGION="${REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-ephemeral-rocketchat-app}"
# メンテ中に全パスを向ける S3 オリジン ID と、その直前に来るべきビヘイビア
MAINT_PATH="/*"
MAINT_ORIGIN="errorpage-s3-origin"
ERRORPAGE_PATH="/error.html"
# ---------------------------------------------------------------------------

log()  { printf '\033[1;34m[rocket]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[rocket]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[rocket]\033[0m %s\n' "$*" >&2; exit 1; }

require_deps() {
  command -v aws >/dev/null 2>&1 || die "aws CLI が見つかりません。"
  command -v jq  >/dev/null 2>&1 || die "jq が見つかりません。(brew install jq)"
}

stack_output() {
  # $1: OutputKey
  aws cloudformation describe-stacks \
    --region "$REGION" --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}

resolve_resources() {
  log "スタック '$STACK_NAME' ($REGION) から対象リソースを取得します..."
  INSTANCE_ID="$(stack_output InstanceId)"
  DIST_ID="$(stack_output CloudFrontDistributionId)"
  [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ] || die "InstanceId を取得できませんでした。"
  [ -n "$DIST_ID" ]     && [ "$DIST_ID" != "None" ]     || die "CloudFrontDistributionId を取得できませんでした。"
  log "  InstanceId   = $INSTANCE_ID"
  log "  Distribution = $DIST_ID"
}

# CloudFront の DistributionConfig を取得し、jq フィルタで加工して update する。
# $1: 現在の config(JSON) を受け取り、更新後の DistributionConfig を返す jq フィルタ
# $2: (任意) jq に --arg func_arn で渡す CloudFront Function の ARN
update_distribution() {
  local jq_filter="$1"
  local func_arn="${2:-}"
  local tmp etag new_config
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN

  aws cloudfront get-distribution-config \
    --region "$REGION" --id "$DIST_ID" --output json > "$tmp"

  etag="$(jq -r '.ETag' "$tmp")"
  new_config="$(jq --arg func_arn "$func_arn" "$jq_filter" "$tmp")"

  # 変更が無ければ update をスキップ(冪等)。
  if [ "$(jq -cS '.DistributionConfig' "$tmp")" = "$(printf '%s' "$new_config" | jq -cS '.')" ]; then
    log "  CloudFront の設定に変更はありません(スキップ)。"
    return 0
  fi

  aws cloudfront update-distribution \
    --region "$REGION" --id "$DIST_ID" --if-match "$etag" \
    --distribution-config "$new_config" >/dev/null
  log "  CloudFront を更新しました(反映まで数分かかります)。"
}

# --- stop -------------------------------------------------------------------
do_stop() {
  resolve_resources

  # メンテ用 CloudFront Function の ARN をスタック出力から解決。
  MAINT_FUNC_ARN="$(stack_output MaintenanceFunctionArn)"
  [ -n "$MAINT_FUNC_ARN" ] && [ "$MAINT_FUNC_ARN" != "None" ] \
    || die "MaintenanceFunctionArn を取得できませんでした。更新版の 03-app.yaml を先に deploy してください(Function が未作成です)。"
  log "  MaintenanceFunc = $MAINT_FUNC_ARN"

  log "1/2 EC2 インスタンスを停止します..."
  aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
  log "  stop-instances を発行しました。"

  log "2/2 CloudFront ビヘイビアに $MAINT_PATH ($MAINT_ORIGIN) を追加します..."
  # /error.html の直後に /* を挿入。既に /* があれば何もしない(冪等)。
  # /* には viewer-request Function を関連付け、全 URI を /error.html に書き換える。
  update_distribution '
    .DistributionConfig as $c
    | ($c.CacheBehaviors.Items // []) as $items
    | if ($items | map(.PathPattern) | index("'"$MAINT_PATH"'")) != null then
        .
      else
        # /error.html のビヘイビアを雛形に、PathPattern だけ /* へ差し替えて作る。
        ($items | map(select(.PathPattern == "'"$ERRORPAGE_PATH"'")) | .[0]) as $tmpl
        | if $tmpl == null then
            error("テンプレート元の '"$ERRORPAGE_PATH"' ビヘイビアが見つかりません。")
          else
            ($tmpl
              | .PathPattern = "'"$MAINT_PATH"'"
              | .TargetOriginId = "'"$MAINT_ORIGIN"'"
              # 雛形の古い関連付けを継がないよう明示的に上書きする。
              | .FunctionAssociations = {Quantity: 1, Items: [{EventType: "viewer-request", FunctionARN: $func_arn}]}
            ) as $new
            # /error.html の直後に挿入(index順 = precedence順)。
            | ($items | map(.PathPattern) | index("'"$ERRORPAGE_PATH"'")) as $i
            | .DistributionConfig.CacheBehaviors.Items =
                ($items[0:($i+1)] + [$new] + $items[($i+1):])
            | .DistributionConfig.CacheBehaviors.Quantity =
                (.DistributionConfig.CacheBehaviors.Items | length)
          end
      end
    | .DistributionConfig
  ' "$MAINT_FUNC_ARN"

  log "完了: メンテナンス状態にしました。"
}

# --- start ------------------------------------------------------------------
do_start() {
  resolve_resources

  log "1/3 EC2 インスタンスを開始します..."
  aws ec2 start-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
  log "  start-instances を発行しました。"

  log "2/3 CloudFront ビヘイビア $MAINT_PATH を削除します..."
  # /* ビヘイビアを除去。無ければ何もしない(冪等)。
  update_distribution '
    .DistributionConfig.CacheBehaviors.Items =
      ((.DistributionConfig.CacheBehaviors.Items // [])
        | map(select(.PathPattern != "'"$MAINT_PATH"'")))
    | .DistributionConfig.CacheBehaviors.Quantity =
        (.DistributionConfig.CacheBehaviors.Items | length)
    | .DistributionConfig
  '

  log "3/3 デフォルトルートオブジェクトをクリアします(旧構成の後始末, 既に空ならスキップ)..."
  update_distribution '.DistributionConfig | .DefaultRootObject = ""'

  log "完了: 再開しました。EC2 内の Docker 復帰まで数分、CloudFront 反映まで数分かかります。"
}

# --- entrypoint -------------------------------------------------------------
main() {
  require_deps
  case "${1:-}" in
    stop)  do_stop ;;
    start) do_start ;;
    *)
      cat >&2 <<USAGE
使い方: $(basename "$0") {start|stop}

  stop   EC2停止 + CloudFrontをメンテ(準備中ページ)へ切り替え
  start  EC2開始 + CloudFrontを通常へ戻す

環境変数で上書き可: REGION(=$REGION), STACK_NAME(=$STACK_NAME)
USAGE
      exit 2 ;;
  esac
}

main "$@"
