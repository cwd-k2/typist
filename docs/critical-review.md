# Typist 批判的レビュー

> **レビュー実施日**: 2026-03-04  
> **対象バージョン**: v0.01  
> **レビュー目的**: 設計上の問題点、潜在的リスク、理論的健全性の批判的分析

---

## 目次

1. [エグゼクティブサマリー](#1-エグゼクティブサマリー)
2. [設計上の問題点](#2-設計上の問題点)
3. [API 一貫性の欠如](#3-api-一貫性の欠如)
4. [エッジケースと脆弱性](#4-エッジケースと脆弱性)
5. [スケーラビリティの懸念](#5-スケーラビリティの懸念)
6. [理論的健全性の問題](#6-理論的健全性の問題)
7. [運用上のリスク](#7-運用上のリスク)
8. [推奨事項](#8-推奨事項)

---

## 1. エグゼクティブサマリー

### 1.1 批判的評価の要約

Typist は技術的に野心的なプロジェクトですが、**本番環境での使用には重大なリスク**があります。

#### 🔴 Critical Issues (即座の対応が必要)

| 問題 | 影響 | 箇所 |
|------|------|------|
| **God Class** | 保守性、テスト困難 | `Typist.pm` (30KB) |
| **スタックオーバーフロー** | DoS、サーバークラッシュ | `Parser.pm` 再帰 |
| **並行処理の競合状態** | データ破損、型情報消失 | `Workspace.pm`, `Registry.pm` |
| **Unification の不完全性** | 型推論の不正確性 | `Unify.pm` occurs-check 欠如 |
| **GADT 実装の不健全性** | 型安全性違反 | `Type/Data.pm` |

#### 🟡 High Issues (早期対応推奨)

| 問題 | 影響 | 箇所 |
|------|------|------|
| **循環依存** | リファクタリング困難 | `Typist` ↔ `Registry` ↔ `TypeClass` |
| **グローバル可変状態** | テスト汚染、スレッド非安全 | `Infer.pm`, `Parser.pm` |
| **キャッシュ無効化** | パフォーマンス劣化 | `Workspace.pm` |
| **エラーハンドリング不統一** | デバッグ困難 | 全体 |

### 1.2 リスク評価

```
┌─────────────────────────────────────────────────────────────┐
│                    リスクマトリクス                         │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  影響度 ▲                                                   │
│         │                                                   │
│    高   │  ● 並行競合    ● スタックOF   ● GADT不健全      │
│         │                                                   │
│    中   │  ● God Class   ● キャッシュ   ● 循環依存        │
│         │                                                   │
│    低   │  ● API不統一   ● Magic数値                       │
│         │                                                   │
│         └───────────────────────────────────────────────▶  │
│              低           中           高      発生確率     │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. 設計上の問題点

### 2.1 God Class アンチパターン

#### 2.1.1 Typist.pm (30.1 KB)

**問題**: 単一ファイルに過剰な責務が集中

```
Typist.pm の責務:
├── import/export ディスパッチ
├── ランタイム/コンパイル時分岐
├── Protocol 定義・検証
├── Effect Handler 管理
├── match 式評価
├── Struct 生成・検証
├── Enum 定義
├── Effect 操作生成
└── 型チェック統合
```

**影響**:
- 変更時の影響範囲が予測困難
- 単体テストが困難
- コードレビューの効率低下
- 新規開発者の学習コスト増大

**推奨分割**:

```perl
# 現状: 1ファイル 30KB
Typist.pm

# 推奨: 責務別に分割
Typist/
├── Import.pm        # import/export ロジック
├── Struct.pm        # Struct 生成・検証
├── Match.pm         # match 式評価
├── Protocol.pm      # Protocol 管理
├── EffectOps.pm     # Effect 操作生成
└── Enum.pm          # Enum 定義
```

#### 2.1.2 Static::TypeChecker.pm (1000+ 行)

**問題**: 型検査、型推論、Narrowing が混在

```perl
# 現状: 単一クラスに3つの責務
TypeChecker->analyze()
  ├── 型推論 (infer_*)
  ├── 型検査 (check_*)
  └── Narrowing (narrow_*)
```

**推奨**:

```perl
# 分離された責務
Static/
├── TypeInfer.pm      # 型推論のみ
├── TypeCheck.pm      # 型検査のみ
└── TypeNarrow.pm     # Narrowing のみ
```

#### 2.1.3 Static::Analyzer.pm::_build_symbol_index (340 行)

**問題**: 単一メソッドに複雑なロジック

```perl
sub _build_symbol_index {
    # 340行の巨大メソッド
    # Cyclomatic complexity: 20+
    # 10+ のネストしたループ
}
```

**推奨**:

```perl
sub _build_symbol_index {
    $self->_build_alias_symbols;
    $self->_build_function_symbols;
    $self->_build_datatype_symbols;
    $self->_build_struct_symbols;
    $self->_build_effect_symbols;
}
```

### 2.2 循環依存

#### 2.2.1 Type System 循環

```
┌──────────────┐
│   Typist.pm  │
└──────┬───────┘
       │ imports
       ▼
┌──────────────┐     imports     ┌──────────────┐
│   Registry   │ ◄─────────────► │  TypeClass   │
└──────┬───────┘                 └──────────────┘
       │ requires                       │
       ▼                                │
┌──────────────┐                        │
│  Type::Alias │ ◄──────────────────────┘
└──────────────┘      references
```

**影響**:
- モジュール分離が困難
- テスト時のモック作成が複雑
- 循環参照によるメモリリーク可能性

**推奨**: 依存性注入パターンの採用

```perl
# 現状: 直接 require
package Typist::TypeClass;
require Typist::Registry;

# 推奨: コンストラクタ注入
package Typist::TypeClass;
sub new ($class, %args) {
    my $self = bless {
        registry_lookup => $args{registry_lookup}, # 関数参照
    }, $class;
}
```

### 2.3 グローバル可変状態

#### 2.3.1 Static::Infer.pm のグローバル変数

```perl
# lib/Typist/Static/Infer.pm (lines 35-39)
my @_CALLBACK_PARAMS;           # グローバル配列
my %_CALLBACK_PARAMS_SEEN;      # グローバルハッシュ
```

**問題**:
- スレッド非安全
- テスト間で状態汚染
- 複数ファイルの同時解析で競合

#### 2.3.2 Parser.pm のキャッシュ

```perl
# lib/Typist/Parser.pm (lines 37-40)
my %_PARSE_CACHE;     # グローバルキャッシュ
my $_CACHE_EPOCH = 0; # グローバルカウンタ
```

**問題**:
- ロックなしのハッシュアクセス
- `$_CACHE_EPOCH` の整数オーバーフロー (2^63 後)

### 2.4 コード重複

#### 2.4.1 LRU キャッシュの重複実装

```perl
# Parser.pm と Subtype.pm で同一パターン
sub _cache_evict {
    return if keys %_PARSE_CACHE <= $_CACHE_LIMIT;
    my @sorted = sort { $_CACHE_EPOCH{$a} <=> $_CACHE_EPOCH{$b} } 
                 keys %_PARSE_CACHE;
    my $keep = int(@sorted * 3/4);
    delete @_PARSE_CACHE{@sorted[0 .. $#sorted - $keep]};
}
```

**推奨**: 共通 LRU キャッシュクラスの抽出

```perl
# lib/Typist/Cache/LRU.pm
package Typist::Cache::LRU;
sub new ($class, %args) {
    bless {
        limit => $args{limit} // 1000,
        data  => {},
        epoch => {},
        counter => 0,
    }, $class;
}
sub get ($self, $key) { ... }
sub set ($self, $key, $value) { ... }
sub evict ($self) { ... }
```

### 2.5 密結合

#### 2.5.1 LSP Server のハードコードディスパッチ

```perl
# lib/Typist/LSP/Server.pm (lines 17-36)
my %DISPATCH = (
    'initialize'                    => \&_on_initialize,
    'initialized'                   => \&_on_initialized,
    'shutdown'                      => \&_on_shutdown,
    # ... 18 のハンドラ参照
);
```

**問題**:
- 新機能追加時にこのファイルを変更必須
- ハンドラのモック/差し替えが困難
- 機能のオン/オフが不可能

**推奨**: プラグインレジストリパターン

```perl
# lib/Typist/LSP/HandlerRegistry.pm
package Typist::LSP::HandlerRegistry;
my @HANDLERS;
sub register ($class, $method, $handler) {
    push @HANDLERS, { method => $method, handler => $handler };
}
sub dispatch ($class, $method, @args) {
    my ($h) = grep { $_->{method} eq $method } @HANDLERS;
    return $h->{handler}->(@args) if $h;
}

# lib/Typist/LSP/Handler/Hover.pm
Typist::LSP::HandlerRegistry->register(
    'textDocument/hover' => \&handle_hover
);
```

---

## 3. API 一貫性の欠如

### 3.1 Type::* コンストラクタの不統一

| クラス | パターン | 問題 |
|--------|----------|------|
| `Type::Atom` | `new($name)` | 位置引数のみ |
| `Type::Func` | `new($params, $returns, $effects, %opts)` | 混合パターン |
| `Type::Union` | `new(@members)` | 可変長引数 |
| `Type::Record` | `new(%all_fields)` | フラットハッシュ |
| `Type::Var` | `new($name, %opts)` | 位置 + オプション |
| `Type::Quantified` | `new(%opts)` | オプションのみ |
| `Type::Param` | `new($base, @params)` | 位置 + 可変長 |

**影響**:
- リファクタリング時のバグ混入リスク
- ドキュメントなしでは使用困難
- 一貫したファクトリパターンが不可能

**推奨**: 統一されたコンストラクタパターン

```perl
# すべての Type で named parameters を使用
Type::Atom->new(name => 'Int');
Type::Func->new(params => [...], returns => $ret, effects => $eff);
Type::Union->new(members => [@members]);
Type::Record->new(required => \%req, optional => \%opt);
```

### 3.2 戻り値の不統一

#### 3.2.1 LSP モジュール間の不統一

| モジュール | 空の場合 | フォーマット |
|------------|----------|--------------|
| `LSP::Completion` | `[]` | 配列参照 |
| `LSP::Hover` | `undef` | 未定義値 |
| `LSP::CodeAction` | `undef`, `+{}`, `[]` | **3種類混在** |
| `LSP::Definition` | `undef` | 未定義値 |

**問題**: クライアントコードが複数の戻り値型を処理する必要

```perl
# 現状: 呼び出し側で3パターン対応
my $result = $provider->get_result();
if (!defined $result) { ... }
elsif (ref $result eq 'ARRAY' && !@$result) { ... }
elsif (ref $result eq 'HASH' && !%$result) { ... }
```

**推奨**: 統一された Result 型

```perl
# lib/Typist/LSP/Result.pm
package Typist::LSP::Result;
sub empty ($class) { bless { items => [] }, $class }
sub of ($class, @items) { bless { items => \@items }, $class }
sub is_empty ($self) { !@{$self->{items}} }
sub to_lsp ($self) { $self->{items} }
```

### 3.3 エラーハンドリングの不統一

#### 3.3.1 Type::Alias の不統一

```perl
# lib/Typist/Type/Alias.pm
sub contains ($self, $value) {
    my $resolved = Typist::Registry->lookup_type($self->{name})
        // die "unresolved alias: $self->{name}";  # die
}

sub free_vars ($self) {
    my $resolved = Typist::Registry->lookup_type($self->{name})
        // return ();  # 空配列を返却 (サイレント)
}

sub substitute ($self, $bindings) {
    my $resolved = Typist::Registry->lookup_type($self->{name})
        // return $self;  # 自身を返却 (サイレント)
}
```

**問題**: 同じエラー条件に対して3つの異なる挙動

**推奨**: 統一されたエラー戦略

```perl
# オプション A: すべて die
sub free_vars ($self) {
    my $resolved = $self->_resolve_or_die;
    $resolved->free_vars;
}

# オプション B: Result 型を使用
sub free_vars ($self) {
    my $result = $self->try_resolve;
    return $result->is_err ? () : $result->ok->free_vars;
}
```

### 3.4 命名規則の不統一

#### 3.4.1 型解決メソッドの命名

| 場所 | メソッド名 |
|------|------------|
| `LSP::Document::Resolver` | `resolve_type_deep()` |
| `LSP::Completion` | `_resolve_var_type()` |
| `LSP::Document` | `_resolve_var_type()` |
| `Type::Alias` | `_resolve()` |

**問題**: 類似機能に異なる名前

**推奨**: 統一された命名規則

```perl
# パブリック API
resolve_type($name)       # 型名から型オブジェクト
resolve_variable($name)   # 変数名から型情報

# 内部 API
_do_resolve_type($name)   # プレフィックス統一
_do_resolve_variable($name)
```

---

## 4. エッジケースと脆弱性

### 4.1 スタックオーバーフロー (DoS)

#### 4.1.1 パーサーの無制限再帰

```perl
# lib/Typist/Parser.pm
# 相互再帰: _parse_union → _parse_intersection → _parse_primary → _parse_union

sub _parse_union { ... _parse_intersection() ... }
sub _parse_intersection { ... _parse_primary() ... }
sub _parse_primary { ... _parse_union() ... }  # 循環
```

**攻撃ベクトル**:

```perl
# 10000 レベルのネスト
my $malicious = "ArrayRef[" x 10000 . "Int" . "]" x 10000;
Typist::Parser->parse($malicious);  # スタックオーバーフロー
```

**テストカバレッジ**: `01b_parser_edge.t` は 4 レベルのみテスト

**推奨修正**:

```perl
sub _parse_union ($class, $tokens, $pos, $depth = 0) {
    die "maximum nesting depth exceeded" if $depth > 100;
    # ...
    $class->_parse_intersection($tokens, $pos, $depth + 1);
}
```

### 4.2 メモリ枯渇攻撃

#### 4.2.1 Content-Length の無制限受け入れ

```perl
# lib/Typist/LSP/Transport.pm (line 56)
if ($line =~ /Content-Length:\s*(\d+)/i) {
    $content_length = $1;  # 無制限の数値を受け入れ
}
# ...
read($self->{in}, $body, $content_length);  # 巨大バッファ割り当て
```

**攻撃ベクトル**:

```http
Content-Length: 999999999999
```

**推奨修正**:

```perl
my $MAX_CONTENT_LENGTH = 50_000_000;  # 50MB

if ($line =~ /Content-Length:\s*(\d+)/i) {
    $content_length = $1;
    if ($content_length > $MAX_CONTENT_LENGTH) {
        die "Content-Length exceeds maximum ($MAX_CONTENT_LENGTH)";
    }
}
```

#### 4.2.2 非常に長い型式

```perl
# lib/Typist/Parser.pm - _tokenize に長さ制限なし
sub _tokenize ($class, $input) {
    # $input の長さチェックなし
    while (pos($input) < length($input)) { ... }
}
```

**攻撃ベクトル**:

```perl
my $huge = "Int" . " | Int" x 1_000_000;  # 数 MB の型式
Typist::Parser->parse($huge);  # メモリ枯渇
```

**推奨修正**:

```perl
my $MAX_TYPE_EXPR_LENGTH = 100_000;  # 100KB

sub parse ($class, $input) {
    die "type expression too long" if length($input) > $MAX_TYPE_EXPR_LENGTH;
    # ...
}
```

### 4.3 並行処理の競合状態 (🔴 Critical)

#### 4.3.1 Registry の非原子的更新

```perl
# lib/Typist/LSP/Workspace.pm (lines 92-119)
sub update_file ($self, $path, $source) {
    my $old_info = $self->{files}{$path};
    
    if ($old_info) {
        $self->_unregister_file_types($old_info);  # ステップ 1
    }
    
    # ここでクラッシュすると型が消失
    
    my $extracted = $self->_extract_file($path, $source);
    $self->_register_file_types($extracted);  # ステップ 2
}
```

**競合シナリオ**:

```
Thread A                    Thread B
─────────────────────────   ─────────────────────────
unregister old types
                            unregister different file
                            register new types
register new types          ← overwrites Thread B's work
```

**推奨修正**:

```perl
use Fcntl ':flock';

sub update_file ($self, $path, $source) {
    flock($self->{lock}, LOCK_EX);
    
    eval {
        # トランザクション的更新
        my $old = delete $self->{files}{$path};
        my $new = $self->_extract_file($path, $source);
        $self->{files}{$path} = $new;
        
        $self->_rebuild_registry;  # 完全再構築 (安全だが遅い)
    };
    
    flock($self->{lock}, LOCK_UN);
    die $@ if $@;
}
```

### 4.4 Unicode 正規化の欠如

```perl
# lib/Typist/Parser.pm (line 82)
/\G([A-Za-z_]\w*)/gc  # \w は Unicode を含む (Perl 5.20+)
```

**問題**: `Café` と `Cafe´` (結合アクセント) が異なる型として扱われる

**推奨修正**:

```perl
use Unicode::Normalize 'NFC';

sub parse ($class, $input) {
    $input = NFC($input);  # 正規化
    # ...
}
```

### 4.5 ファイル削除時の不整合

```perl
# lib/Typist/LSP/Workspace.pm
# ファイル削除イベントのハンドラなし
# didDelete は LSP spec でオプションだが実装なし
```

**問題**: ファイルが削除されても型定義が残存

**推奨修正**:

```perl
# Server.pm に追加
'workspace/didDeleteFiles' => \&_on_did_delete_files,

sub _on_did_delete_files ($self, $params) {
    for my $file ($params->{files}->@*) {
        my $path = uri_to_path($file->{uri});
        $self->{workspace}->remove_file($path);
    }
}
```

---

## 5. スケーラビリティの懸念

### 5.1 アルゴリズム計算量

#### 5.1.1 O(n²) ホットスポット

| アルゴリズム | 場所 | 計算量 | トリガー |
|--------------|------|--------|----------|
| Record LUB | `Subtype.pm:95-127` | O(f²) | 大きな Record 型 |
| Reference 検索 | `Workspace.pm:334-355` | O(files × size) | Find All References |
| パーサーキャッシュ eviction | `Parser.pm:42-46` | O(n log n) | キャッシュ上限到達 |
| Workspace 再構築 | `Workspace.pm:233-252` | O(n²) | 循環依存 |

#### 5.1.2 Reference 検索の非効率性

```perl
# lib/Typist/LSP/Workspace.pm (lines 334-355)
sub find_all_references ($self, $name) {
    my @refs;
    
    # O(k) - 開いているドキュメント
    for my $uri (sort keys %$open_documents) {
        # O(lines × name_len)
        push @refs, _find_occurrences($doc->content, $name);
    }
    
    # O(m) - ワークスペースファイル
    for my $path (sort keys $self->{files}->%*) {
        my $content = read_file($path);  # O(file_size)
        push @refs, _find_occurrences($content, $name);  # O(lines × name_len)
    }
    
    return @refs;
}
```

**1000 ファイルのワークスペース**:
- 各ファイル平均 1000 行
- `find_all_references("$x")` → 1,000,000 行をスキャン

**推奨**: インデックス化

```perl
# シンボルインデックスを事前構築
sub _build_symbol_index ($self) {
    $self->{symbol_index} = {};  # name => [{file, line, col}, ...]
    
    for my $path (keys $self->{files}->%*) {
        # 抽出時にインデックス構築
    }
}

sub find_all_references ($self, $name) {
    return $self->{symbol_index}{$name} // [];  # O(1)
}
```

### 5.2 キャッシュ無効化の問題

#### 5.2.1 ファイル保存ごとの全キャッシュクリア

```perl
# lib/Typist/LSP/Workspace.pm (line 218)
sub _unregister_file_types ($self, $info) {
    # ...
    $reg->{resolved} = +{};  # 全キャッシュクリア！
}
```

**問題**: 1 ファイルの変更で全 resolved キャッシュが無効化

**影響**:
- 100 ファイルのワークスペース
- 1 ファイル保存 → 100 ファイル分のキャッシュ再構築

**推奨**: 差分キャッシュ無効化

```perl
sub _unregister_file_types ($self, $info) {
    # 変更されたファイルの型のみ無効化
    for my $alias (keys $info->{aliases}->%*) {
        delete $reg->{resolved}{$alias};
        # 依存する型も無効化 (依存グラフ必要)
    }
}
```

### 5.3 静的解析パイプラインの非効率

```perl
# lib/Typist/Static/Analyzer.pm (lines 46-107)
sub analyze {
    # 毎回サブタイプキャッシュをクリア
    Typist::Subtype->clear_cache;
    
    # 4 回のフルスキャン
    Checker->new(...)->analyze;        # Pass 1: 構造検証
    TypeChecker->new(...)->analyze;    # Pass 2: 型検査
    EffectChecker->new(...)->analyze;  # Pass 3: 効果検査
    ProtocolChecker->new(...)->analyze; # Pass 4: プロトコル検査
}
```

**問題**:
- 各チェッカーが独立して抽出データを走査
- 4 × O(n) で同じデータを繰り返し処理

**推奨**: 単一パス解析

```perl
sub analyze {
    my $visitor = Typist::Static::Visitor->new(
        on_function => sub {
            $checker->check_function(@_);
            $type_checker->check_function(@_);
            $effect_checker->check_function(@_);
        },
    );
    
    $visitor->visit($extracted);  # 1 回の走査
}
```

### 5.4 メモリ使用量の増大

#### 5.4.1 PPI Document の蓄積

```perl
# lib/Typist/Static/Extractor.pm
sub extract ($class, $source) {
    my $doc = PPI::Document->new(\$source);
    # $doc は返却されず、内部で保持される可能性
}
```

**問題**: 長時間稼働の LSP サーバーで PPI Document が蓄積

#### 5.4.2 Subtype キャッシュアンカー

```perl
# lib/Typist/Subtype.pm (lines 154-156)
$_CACHE_ANCHORS{refaddr($sub)} = $sub;
$_CACHE_ANCHORS{refaddr($super)} = $super;
```

**問題**: 
- GC による `refaddr` 再利用を防ぐためのアンカー
- しかしアンカー自体が解放されない → メモリリーク

---

## 6. 理論的健全性の問題

### 6.1 Unification の不完全性 (🔴 Critical)

#### 6.1.1 Occurs Check の欠如

```perl
# lib/Typist/Static/Unify.pm
sub _unify ($formal, $actual, $bindings) {
    if ($formal->is_var) {
        my $name = $formal->name;
        # ⚠️ occurs check なし！
        return +{ %$bindings, $name => $actual };
    }
}
```

**問題**: `T` を `ArrayRef[T]` にバインド可能 → 無限型

**攻撃例**:

```perl
sub broken :sig(forall T => T -> ArrayRef[T]) {
    my ($x) = @_;
    return [$x, broken($x)];  # T = ArrayRef[T] = ArrayRef[ArrayRef[T]] = ...
}
```

**推奨修正**:

```perl
sub _unify ($formal, $actual, $bindings) {
    if ($formal->is_var) {
        my $name = $formal->name;
        
        # Occurs check
        if (_occurs($name, $actual)) {
            return undef;  # 失敗
        }
        
        return +{ %$bindings, $name => $actual };
    }
}

sub _occurs ($var_name, $type) {
    return 1 if $type->is_var && $type->name eq $var_name;
    # 再帰的にチェック
    for my $child ($type->children) {
        return 1 if _occurs($var_name, $child);
    }
    return 0;
}
```

#### 6.1.2 Widening による情報損失

```perl
# lib/Typist/Static/Unify.pm (lines 31-32)
if (exists $bindings->{$name}) {
    my $widened = Typist::Subtype->common_super($bindings->{$name}, $actual);
    return +{ %$bindings, $name => $widened };
}
```

**問題**: Principal type inference の違反

```
T ~ Int, then T ~ Str
→ widened to Any (情報損失)
```

**影響**: 推論された型が最も一般的な型になりすぎる

### 6.2 GADT の不健全性 (🔴 Critical)

#### 6.2.1 コンストラクタ戻り値型の未検証

```perl
# lib/Typist/Type/Data.pm (lines 40-52)
sub constructor_return_type ($self, $tag) {
    my $v = $self->{variants}{$tag} // return undef;
    return $v->{return_type} if exists $v->{return_type};
    # ...
}
```

**問題**: 戻り値型がインスタンス化と一致するか検証されない

**攻撃例**:

```perl
datatype Expr[T] =>
    IntLit(Int) -> Expr[Int],
    StrLit(Str) -> Expr[Str],
    Bogus(Int) -> Expr[Str];  # T=Int で構築しても Expr[Str] を返す！

sub eval :sig(Expr[Int] -> Int) {
    my ($e) = @_;
    match ($e) {
        IntLit($n) => $n,
        Bogus($n) => $n,  # 型システムは通すが、意味的に不正
    }
}
```

**推奨修正**:

```perl
sub validate_gadt ($self) {
    for my $tag (keys $self->{variants}->%*) {
        my $ret = $self->{variants}{$tag}{return_type};
        # 戻り値型が Data 型のインスタンスであることを検証
        unless ($ret->is_data && $ret->name eq $self->{name}) {
            die "GADT constructor $tag must return $self->{name}[...]";
        }
    }
}
```

### 6.3 HKT Kind Checking の不完全性

```perl
# lib/Typist/KindChecker.pm (lines 52-53)
# 未知のコンストラクタは * を仮定
return Typist::Kind->new('Star') unless $self->_kind_of($name);
```

**問題**: 
- 未登録の型コンストラクタがサイレントに `*` として扱われる
- 部分適用が検出されない

```perl
# HashRef : * -> * -> *
# HashRef[Int] : * -> * (部分適用)
# 現状では検出されない
```

### 6.4 Row Variable の不整合

```perl
# lib/Typist/Type/Row.pm (lines 117-129)
sub substitute ($self, $bindings) {
    # ...
    if ($b && !$b->is_row) {
        # Non-row binding — just drop the row_var
        $self;  # ⚠️ row_var がサイレントに消失
    }
}
```

**問題**: Row 変数が非 Row 型にバインドされるとサイレントに無視

### 6.5 Gradual Typing の情報損失

```perl
# lib/Typist/Static/Infer.pm (line 44)
# Any 型のパラメータは型検査をスキップ
```

```perl
# lib/Typist/Static/Unify.pm (lines 35-36)
# Any バインディングは無視
if ($actual->is_atom && $actual->name eq 'Any') {
    return $bindings;  # バインディングに追加しない
}
```

**問題**: 
- Blame tracking なし
- どのアノテーションが型エラーの原因か特定不可能

---

## 7. 運用上のリスク

### 7.1 デバッグ困難性

#### 7.1.1 エラーメッセージの情報不足

```perl
# 現状のエラーメッセージ
[TypeMismatch] expected Int, got Str
```

**問題**: 
- どの変数/式が原因か不明
- ソースコードの該当箇所が不明確
- 修正方法の提案なし

#### 7.1.2 スタックトレースの不可読性

型チェックエラー時のスタックトレースが深すぎて追跡困難

### 7.2 監視・可観測性の欠如

- メトリクス収集機能なし
- パフォーマンスプロファイリング不可
- LSP サーバーの健全性チェックなし

### 7.3 設定の柔軟性不足

```perl
# ハードコードされた設定
$_CACHE_LIMIT = 1000;              # Parser.pm
my $MAX_DEPTH = ???;               # 存在しない
my $TIMEOUT = ???;                 # 存在しない
```

**問題**: 環境に応じた調整が不可能

---

## 8. 推奨事項

### 8.1 即座の対応 (P0)

| 問題 | 対応 | 工数見積 |
|------|------|----------|
| スタックオーバーフロー | 深度制限の追加 | 1日 |
| Content-Length 攻撃 | サイズ制限の追加 | 0.5日 |
| Occurs check 欠如 | Unify.pm に追加 | 2日 |
| 並行競合状態 | ロック機構の追加 | 3日 |

### 8.2 短期対応 (P1)

| 問題 | 対応 | 工数見積 |
|------|------|----------|
| God Class 分割 | `Typist.pm` のリファクタリング | 1週間 |
| グローバル状態排除 | インスタンス変数化 | 3日 |
| API 統一 | コンストラクタ標準化 | 1週間 |
| キャッシュ最適化 | 差分無効化の実装 | 3日 |

### 8.3 中期対応 (P2)

| 問題 | 対応 | 工数見積 |
|------|------|----------|
| シンボルインデックス | O(1) 参照検索 | 1週間 |
| 単一パス解析 | Visitor パターン導入 | 2週間 |
| GADT 検証 | 戻り値型検証の実装 | 1週間 |
| HKT 完全化 | Kind checking 強化 | 1週間 |

### 8.4 アーキテクチャ改善

```
現状                           推奨
─────────────────────────      ─────────────────────────
Typist.pm (30KB God Class)     Typist/
                               ├── Core.pm (エントリ)
                               ├── Import.pm
                               ├── Struct.pm
                               ├── Match.pm
                               └── Protocol.pm

グローバル状態                  インスタンス状態
─────────────────────────      ─────────────────────────
my %_PARSE_CACHE;              $self->{cache}
my @_CALLBACK_PARAMS;          $self->{params}

密結合                         疎結合
─────────────────────────      ─────────────────────────
直接 require                   依存性注入
ハードコード dispatch          プラグインレジストリ
```

---

## 結論

Typist は**技術的に野心的**なプロジェクトですが、**本番環境での使用には重大なリスク**があります。

### 主要な懸念

1. **セキュリティ**: DoS 攻撃に対する脆弱性（スタックオーバーフロー、メモリ枯渇）
2. **信頼性**: 並行処理時のデータ破損リスク
3. **正確性**: 型システムの理論的不健全性（occurs check 欠如、GADT 検証不足）
4. **保守性**: God Class、循環依存、グローバル状態による技術的負債
5. **スケーラビリティ**: O(n²) アルゴリズム、非効率なキャッシュ戦略

### 推奨アクション

1. **本番使用前に**: P0 の問題を解決すること
2. **アーキテクチャリファクタリング**: God Class の分割、依存性注入の導入
3. **理論的健全性の確保**: 型理論の専門家によるレビュー
4. **パフォーマンステスト**: 大規模コードベースでの検証

**総合評価**: 実験的使用には適しているが、本番環境での使用は P0 問題の解決後に再評価が必要

---

## 9. 対応状況

> **更新日**: 2026-03-06

### 対応済み

| 指摘 | 節 | 対応内容 |
|------|-----|---------|
| Parser スタックオーバーフロー DoS | §4.1 | 再帰深度制限 (`$_MAX_PARSE_DEPTH = 64`) + 入力長制限 (`$_MAX_INPUT_LENGTH = 10_000`) を追加 |
| LSP Content-Length メモリ枯渇 | §4.2 | `$MAX_CONTENT_LENGTH = 10MB` の上限チェックを追加 |
| Occurs check 欠如 | §6.1 | `Unify::unify` / `collect_bindings` に occurs check を追加。無限型 (`T = ArrayRef[T]`) を拒否 |
| GADT 戻り値型未検証 | §6.2 | `Registration::register_datatypes` に戻り値型のベース名検証を追加 |
| Row::substitute 非Row バインディング | §6.4 | 非Row バインディング時に row_var を除去した closed row を返すよう修正 |
| Subtype キャッシュ無制限成長 | §5.2 | `$_CACHE_SIZE_LIMIT = 5000` で自動クリアを追加 |
| Type::Alias エラー戦略不統一 | §3.2 | `contains` を `local` ガード + 安全な失敗に統一 |
| God Class: Typist.pm 934行 | §2.1.1 | 5モジュールに分割 (Definition, Algebra, StructDef, EffectDef, External) |
| Parser キャッシュ epoch オーバーフロー | §5.2 | `2**53` 超過時のリセット処理を追加 |
| Workspace キャッシュ無効化不完全 | §5.2 | `_unregister_file_types` で Subtype キャッシュもクリア |
| LSP 命名規則不統一 | §3.2 | `_resolve_var_type` → `resolve_var_type`, `_resolve_type_deep` → `resolve_type_deep` にリネーム |
| Infer.pm グローバル状態 | §5.1 | `@_CALLBACK_PARAMS` / `%_CALLBACK_PARAMS_SEEN` の安全性をコメントで明文化 |
| KindChecker 未知コンストラクタ | §6.3 | gradual kinding の設計意図をコメントで明文化 |
| TypeChecker 責務混在 (986行) | §2.1.2 | TypeEnv.pm (~380行) に環境構築責務を抽出。TypeChecker (~300行) は検査・収集のみに縮小。委譲パターンで疎結合化 |
| 単一パス解析・Visitor パターン | §5.3 | Analyzer を7フェーズパイプラインに再構成。Phase 5 で TypeChecker/EffectChecker/ProtocolChecker が統一関数ループ内で `check_function($name)` を呼ぶ Visitor パターンを導入。`extracted{functions}` の走査が4重→1重に |

### 対応しない（理由付き）

| 指摘 | 節 | 理由 |
|------|-----|------|
| 並行処理の競合状態 | §4.3 | Perl LSP サーバーは単一スレッド（sequential message dispatch）。理論的リスクのみで実害なし |
| Type コンストラクタ API 統一 | §3.1 | 各型の意味論が固有（Atom は singleton pool、Union は可変長、Quantified は構造化）であり、位置引数が自然 |
| Unicode 正規化 | §4.4 | Perl 型名に非 ASCII を使うユースケースが実質存在しない。`\w` の Unicode マッチは Perl の標準動作 |
| ファイル削除イベント | §4.5 | LSP `workspace/didDeleteFiles` はオプション仕様。エディタ再起動またはファイル保存で更新される |
| `Static::Analyzer._build_symbol_index` 340行 | §2.1.3 | Analyzer.pm にそのようなメソッドは存在しない（レビューの誤認） |
| LSP Server プラグインレジストリ | §2.5.1 | 18ハンドラのハッシュテーブルディスパッチは十分管理可能。プラグイン化は過剰設計 |
| LRU キャッシュ共通クラス | §2.4.1 | Parser と Subtype でデータ構造が異なる。共通化は抽象化の過剰 |
| 依存性注入 | §2.2 | Perl の `require` ベースのモジュールロードは十分に疎結合。DI コンテナは Perl エコシステムに不自然 |
| 監視・可観測性 | §7.2 | LSP Logger で十分。メトリクス収集はスコープ外 |
| 設定の柔軟性 | §7.3 | ハードコード定数は実用的な値で固定。環境変数による外部設定は複雑性を増す |

### 将来対応

| 指摘 | 節 | 方針 |
|------|-----|------|
| Gradual Typing の Blame tracking | §6.5 | 型理論の研究課題。現行の Any ガードは gradual typing の標準的実装 |
