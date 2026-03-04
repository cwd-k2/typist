# Typist 包括的レビュー

> **レビュー実施日**: 2026-03-04  
> **対象バージョン**: v0.01  
> **レビュー範囲**: アーキテクチャ、型システム、静的解析、LSP、テスト、コード品質

---

## 目次

1. [エグゼクティブサマリー](#1-エグゼクティブサマリー)
2. [プロジェクト統計](#2-プロジェクト統計)
3. [アーキテクチャ評価](#3-アーキテクチャ評価)
4. [型システム詳細分析](#4-型システム詳細分析)
5. [静的解析パイプライン](#5-静的解析パイプライン)
6. [ランタイム型強制](#6-ランタイム型強制)
7. [LSP サーバー実装](#7-lsp-サーバー実装)
8. [エラーハンドリングシステム](#8-エラーハンドリングシステム)
9. [状態管理とレジストリ](#9-状態管理とレジストリ)
10. [Prelude システム](#10-prelude-システム)
11. [テストスイート評価](#11-テストスイート評価)
12. [コード品質評価](#12-コード品質評価)
13. [懸念事項と改善提案](#13-懸念事項と改善提案)
14. [総合評価](#14-総合評価)

---

## 1. エグゼクティブサマリー

### 1.1 プロジェクト概要

**Typist** は Perl 5.40+ のための純粋 Perl 型システムです。**静的解析優先のアーキテクチャ**を採用し、コンパイル時（CHECK phase）および LSP を通じてエラーを検出します。ランタイム強制はオプトインです。

#### 主要機能

| 機能 | 説明 |
|------|------|
| **Generics** | 型パラメータによる汎用プログラミング |
| **Type Classes** | Haskell 風の型クラスとインスタンス |
| **Higher-Kinded Types** | `* -> *` 種を持つ型コンストラクタ |
| **Nominal Types** | `newtype` と `struct` による名前的型付け |
| **Algebraic Data Types** | `datatype` による直和型、GADT サポート |
| **Algebraic Effects** | Row polymorphism による効果システム |
| **Protocol FSM** | 状態機械による効果プロトコル検証 |
| **Gradual Typing** | 型アノテーション省略可能 |

### 1.2 設計哲学

```
Static-First (default)       Runtime (opt-in: -runtime)
──────────────────────       ─────────────────────────
CHECK phase diagnostics      Tie::Scalar による代入監視
LSP real-time feedback       関数シグネチャラッパー
PPI-based static analysis    値の contains() 検証
```

**3層検証アーキテクチャ**:

1. **Layer 1 — Static Analysis** (常時): PPI ベースの静的解析
2. **Layer 2 — Boundary Enforcement** (常時): コンストラクタ境界検証
3. **Layer 3 — Runtime Monitoring** (opt-in): 代入時の型検証

### 1.3 評価サマリー

| 項目 | 評価 | コメント |
|------|------|----------|
| **アーキテクチャ** | ⭐⭐⭐⭐⭐ | 明確な責務分離、高い拡張性 |
| **型システム** | ⭐⭐⭐⭐⭐ | 学術的に洗練、実用性も高い |
| **静的解析** | ⭐⭐⭐⭐☆ | 包括的だがパフォーマンス未検証 |
| **LSP 実装** | ⭐⭐⭐⭐⭐ | Enterprise-grade の機能セット |
| **テスト品質** | ⭐⭐⭐⭐☆ | 高カバレッジ、統合テスト増強推奨 |
| **ドキュメント** | ⭐⭐⭐⭐☆ | 詳細だが初学者向け不足 |
| **コード品質** | ⭐⭐⭐⭐⭐ | 一貫した規約、Perl::Critic 活用 |

---

## 2. プロジェクト統計

### 2.1 コードベース規模

| 指標 | 数値 |
|------|------|
| **モジュール数** | 65 |
| **テストファイル数** | 78 |
| **ライブラリコード行数** | 22,362 |
| **サブルーチン数** | 808 |
| **Perl 最小バージョン** | v5.40 |

### 2.2 ディレクトリ構造

```
typist/
├── lib/                    # コアモジュール (65 files)
│   └── Typist/
│       ├── Type/          # 型表現 (16 submodules)
│       ├── Static/        # 静的解析 (12 submodules)
│       ├── LSP/           # Language Server (10 submodules)
│       ├── Error/         # エラーシステム
│       ├── Tie/           # ランタイム tie
│       ├── Struct/        # Struct 基底クラス
│       └── Newtype/       # Newtype 基底クラス
├── bin/                    # 実行可能ファイル
│   ├── typist-check       # CLI 型チェッカー
│   ├── typist-lsp         # LSP サーバー
│   └── debug              # デバッグツール
├── t/                      # テストスイート (78 files)
│   ├── static/            # 静的解析テスト (17 files)
│   ├── lsp/               # LSP テスト (20 files)
│   └── critic/            # Perl::Critic テスト (4 files)
├── docs/                   # ドキュメント
├── editors/                # エディタ統合 (VSCode)
├── example/                # サンプルコード
└── script/                 # ユーティリティスクリプト
```

### 2.3 依存関係

**必須依存**:
- `PPI` — Perl コードパーサー（静的解析の基盤）
- `JSON::PP` — JSON 処理（LSP 通信、コア Perl モジュール）

**オプション依存**:
- `Perl::Critic` — エディタポリシー強制

---

## 3. アーキテクチャ評価

### 3.1 レイヤー構成

```
┌─────────────────────────────────────────────────────────────┐
│                      Editor Layer                           │
│  VSCode Extension, Emacs, Vim (via LSP)                    │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Interface Layer                          │
│  ┌─────────────────┐    ┌─────────────────────────────┐    │
│  │   LSP Server    │    │        CLI (Check.pm)       │    │
│  │   (Server.pm)   │    │    typist-check command     │    │
│  └─────────────────┘    └─────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                  Static Analysis Layer                      │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │Extractor │→│Registration│→│ Checker  │→│TypeChecker│   │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘   │
│       │                                          │          │
│       ▼                                          ▼          │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │  Infer   │  │  Unify   │  │EffectChk │  │ProtocolChk│  │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘   │
│                              │                              │
│                     NarrowingEngine                         │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Type System Layer                        │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    Type::*                           │   │
│  │  Atom, Param, Union, Intersection, Func, Record,    │   │
│  │  Struct, Var, Alias, Literal, Newtype, Quantified,  │   │
│  │  Row, Eff, Data                                      │   │
│  └─────────────────────────────────────────────────────┘   │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │  Parser  │  │ Subtype  │  │   Kind   │  │ TypeClass│   │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Runtime Layer                            │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │Attribute │  │Tie::Scalar│ │  Handler │  │ Registry │   │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘   │
│  ┌──────────┐  ┌──────────┐                                │
│  │Struct/Base│ │Newtype/Base│                              │
│  └──────────┘  └──────────┘                                │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 データフロー

```
Source Code (.pm)
       │
       ▼
┌─────────────────┐
│  PPI::Document  │  ← Perl Parser Interface
└─────────────────┘
       │
       ▼
┌─────────────────┐
│   Extractor     │  ← 型定義、関数、変数を抽出
└─────────────────┘
       │
       ▼
┌─────────────────┐
│  Registration   │  ← Registry に型/関数を登録
└─────────────────┘
       │
       ▼
┌─────────────────┐
│    Checker      │  ← 構造検証（サイクル、未宣言変数）
└─────────────────┘
       │
       ▼
┌─────────────────┐
│  TypeChecker    │  ← 型推論 + 型検査
└─────────────────┘
       │
       ▼
┌─────────────────┐
│  EffectChecker  │  ← 効果行包含検査
└─────────────────┘
       │
       ▼
┌─────────────────┐
│ProtocolChecker  │  ← FSM 状態遷移検証
└─────────────────┘
       │
       ▼
┌─────────────────┐
│   Diagnostics   │  ← エラー/警告/ヒント
└─────────────────┘
```

### 3.3 強み

#### 3.3.1 明確な責務分離

各モジュールが単一責務を持ち、依存関係が明確です：

- **Type::*** — 不変値オブジェクトとしての型表現
- **Static::*** — 静的解析パイプラインの各フェーズ
- **LSP::*** — Language Server Protocol の各機能
- **Error::*** — エラー収集と報告

#### 3.3.2 不変値オブジェクト

型は不変（immutable）として実装され、関数型スタイルで扱いやすい：

```perl
# substitute() は新しいオブジェクトを返す
my $new_type = $old_type->substitute({ T => $actual });
```

#### 3.3.3 パフォーマンス最適化

- **Memoization**: サブタイプチェックとパーサーで LRU キャッシュ
- **Flyweight パターン**: Atom 型（Int, Str など）は singleton
- **遅延解決**: Alias 型は参照時に解決
- **差分更新**: LSP ワークスペースは差分登録のみ

### 3.4 改善余地

#### 3.4.1 Global State の存在

`Typist::Registry` はデフォルトで singleton として動作：

```perl
Typist::Registry->define_alias(...);  # singleton を操作
my $reg = Typist::Registry->new;      # instance も可能
$reg->define_alias(...);
```

**リスク**: テスト間での状態汚染  
**緩和策**: instance-based registry を使用（LSP は既にこの方式）

#### 3.4.2 PPI 依存

静的解析が PPI に完全依存：

- PPI は Perl の全構文を正確にパースできない場合がある
- 特に複雑な正規表現や heredoc で問題が発生する可能性

---

## 4. 型システム詳細分析

### 4.1 型コンストラクタ階層

```
                    Typist::Type (抽象基底クラス)
                           │
    ┌──────────┬───────────┼───────────┬──────────┐
    │          │           │           │          │
  Atom      Param        Func       Record      Var
    │          │           │           │          │
 (Int,Str)  (Array[T])  ((A)->B)   ({k=>V})   (T,U)
    │          │           │           │          │
    │          │           │           │          │
    ▼          ▼           ▼           ▼          ▼
 ┌──────┐  ┌──────┐   ┌──────┐   ┌──────┐   ┌──────┐
 │Literal│ │ Data │   │  Eff │   │Struct│   │Quant │
 │("hi") │ │Option│   │![IO] │   │Point │   │forall│
 └──────┘  └──────┘   └──────┘   └──────┘   └──────┘
              │           │
           ┌──┴──┐     ┌──┴──┐
           │     │     │     │
         Union Inter  Row  Newtype
         (A|B) (A&B) [E,r] (UserId)
```

### 4.2 型コンストラクタ詳細

| 型 | クラス | 目的 | 例 |
|----|--------|------|-----|
| **Atom** | `Type::Atom` | プリミティブ singleton | `Int`, `Str`, `Bool`, `Any`, `Void`, `Never` |
| **Var** | `Type::Var` | 型変数 | `T`, `U`, `T: Eq` (bounded) |
| **Param** | `Type::Param` | パラメータ化型 | `ArrayRef[T]`, `HashRef[K,V]`, `Tuple[A,B]` |
| **Func** | `Type::Func` | 関数シグネチャ | `(Int, Str) -> Bool ![IO]` |
| **Quantified** | `Type::Quantified` | 量化型 | `forall T. (T -> T) -> ArrayRef[T]` |
| **Union** | `Type::Union` | 直和型 | `Int \| Str`, `Option[T]` の展開 |
| **Intersection** | `Type::Intersection` | 直積型 | `Readable & Writable` |
| **Record** | `Type::Record` | 構造的レコード | `{ name => Str, age? => Int }` |
| **Row** | `Type::Row` | 効果行 | `[Console, State, r]` |
| **Eff** | `Type::Eff` | 効果アノテーション | `![IO, Exn]` |
| **Data** | `Type::Data` | 代数的データ型 | `Option[T] = Some(T) \| None()` |
| **Literal** | `Type::Literal` | リテラル型 | `"hello"`, `42` |
| **Newtype** | `Type::Newtype` | 名前的型 | `newtype UserId = Int` |
| **Alias** | `Type::Alias` | 型エイリアス参照 | `typedef StringList = ArrayRef[Str]` |
| **Struct** | `Type::Struct` | 名前的構造体 | `struct Point { x => Int, y => Int }` |

### 4.3 型インターフェース

すべての型は以下のインターフェースを実装：

```perl
# 必須メソッド
$type->name()           # 型識別子
$type->to_string()      # 人間可読表現
$type->equals($other)   # 構造的等価性
$type->contains($value) # ランタイムメンバーシップ
$type->free_vars()      # 自由型変数のリスト
$type->substitute(\%b)  # 変数置換（新オブジェクト返却）

# 型述語（デフォルト false）
$type->is_atom()
$type->is_param()
$type->is_union()
$type->is_func()
# ... etc
```

### 4.4 サブタイプ関係

#### 4.4.1 プリミティブ格子

```
                     Any
                   /  |  \
                  /   |   \
               Int   Str   Undef
                |          
             Double        
                |          
              Num          
                |          
              Bool         

Never (bottom type) <: すべての型
```

#### 4.4.2 サブタイプ規則

| 規則 | 定義 |
|------|------|
| **Union (左)** | `T\|U <: S ⟺ T <: S ∧ U <: S` |
| **Union (右)** | `S <: T\|U ⟺ S <: T ∨ S <: U` |
| **Intersection (左)** | `T&U <: S ⟺ T <: S ∨ U <: S` |
| **Intersection (右)** | `S <: T&U ⟺ S <: T ∧ S <: U` |
| **Parameterized** | `ArrayRef[T] <: ArrayRef[U] ⟺ T <: U` (covariant) |
| **Function** | `(A → B) <: (A' → B') ⟺ A' <: A ∧ B <: B'` |
| **Literal** | `Literal(42) <: Int` (widens) |
| **Newtype** | 名前的: 構造互換性なし |
| **Data** | 名前的: 型引数は covariant |

#### 4.4.3 LUB (Least Upper Bound)

```perl
common_super(Int, Double)     → Double
common_super(Int, Str)        → Any
common_super(ArrayRef[Int], ArrayRef[Str]) → ArrayRef[Any]
```

### 4.5 Kind システム

#### 4.5.1 Kind 階層

```perl
*           # 具体型の kind (Int, Str)
Row         # 効果行の kind
* -> *      # 単項型コンストラクタ (ArrayRef, Maybe)
* -> * -> * # 二項型コンストラクタ (HashRef)
```

#### 4.5.2 組み込み Kind 登録

```perl
ArrayRef  : * -> *
HashRef   : * -> * -> *
Ref       : * -> *
Maybe     : * -> *
Tuple     : * -> ... -> *  # 可変長
```

#### 4.5.3 HKT サポート

```perl
# F は * -> * の kind を持つ型変数
sub fmap :sig(forall F: (* -> *), A, B => (A -> B) -> F[A] -> F[B])
```

### 4.6 Type Class システム

#### 4.6.1 単一パラメータ Type Class

```perl
typeclass Eq where { T }
  method eq => (T, T) -> Bool
  method ne => (T, T) -> Bool

instance Eq[Int]
  method eq => (Int, Int) -> Bool { $_[0] == $_[1] }
  method ne => (Int, Int) -> Bool { $_[0] != $_[1] }
```

#### 4.6.2 多パラメータ Type Class

```perl
typeclass Convertible where { T, U }
  method convert => T -> U

instance Convertible[Int, Str]
  method convert => Int -> Str { "$_[0]" }
```

#### 4.6.3 Bounded Quantification

```perl
sub sort :sig(forall T: Ord => ArrayRef[T] -> ArrayRef[T])
```

### 4.7 Effect システム

#### 4.7.1 Effect 定義

```perl
effect Console {
    readLine  => () -> Str
    writeLine => Str -> ()
}

effect State[S] {
    get => () -> S
    put => S -> ()
}
```

#### 4.7.2 Row Polymorphism (Rémy-style)

```perl
# Open row: 追加の効果を許容
sub process :sig(forall r. Int -> Str ![Console, r])

# Closed row: 明示した効果のみ
sub pure_compute :sig(Int -> Int ![])
```

#### 4.7.3 Row Unification

```
[Console, State, r1] ⊆ [IO, r2]

Common labels: []
r1 binds to [IO, r2]     (actual's excess + tail)
r2 binds to [Console, State, r1] (formal's excess + tail)
```

#### 4.7.4 Effect Handler

```perl
handle {
    my $input = Console::readLine();
    Console::writeLine("You said: $input");
} Console => {
    readLine  => sub { <STDIN> },
    writeLine => sub ($msg) { say $msg },
};
```

### 4.8 Protocol FSM

#### 4.8.1 Protocol 定義

```perl
effect FileHandle {
    open  => Str -> ()
    read  => () -> Str
    write => Str -> ()
    close => () -> ()
}

protocol FileHandle {
    initial => Closed
    final   => Closed
    
    Closed -> Open   : open
    Open   -> Open   : read, write
    Open   -> Closed : close
}
```

#### 4.8.2 Protocol 検証

静的解析が関数本体をトレースし、状態遷移を検証：

```perl
sub process_file :Eff(forall r. Str -> () ![FileHandle<Closed -> Closed>, r]) {
    my ($path) = @_;
    FileHandle::open($path);   # Closed -> Open
    my $content = FileHandle::read();  # Open -> Open
    FileHandle::write($content);       # Open -> Open
    FileHandle::close();       # Open -> Closed ✓
}
```

---

## 5. 静的解析パイプライン

### 5.1 パイプライン概要

```
Source Code
    │
    ▼
┌───────────────────────────────────────────────────────────┐
│ Stage 1: EXTRACTION (Extractor.pm)                        │
│ ─────────────────────────────────────────────────────────│
│ • PPI::Document でソースをパース                          │
│ • 単一パス木走査                                          │
│ • 抽出対象:                                               │
│   - typedefs, newtypes, datatypes, structs               │
│   - effects, typeclasses, instances                      │
│   - functions (:sig annotations)                         │
│   - variables (:sig annotations)                         │
│   - protocols                                            │
│ • @typist-ignore 行をキャプチャ                          │
└───────────────────────────────────────────────────────────┘
    │
    ▼
┌───────────────────────────────────────────────────────────┐
│ Stage 2: REGISTRATION (Registration.pm)                   │
│ ─────────────────────────────────────────────────────────│
│ • 2フェーズ登録:                                          │
│   Phase 1: 型定義 (aliases, newtypes, effects, etc.)     │
│   Phase 2: 関数シグネチャ (typeclass 解決後)             │
│ • Prelude のビルトイン型をマージ                         │
│ • Registry に型/関数を登録                               │
└───────────────────────────────────────────────────────────┘
    │
    ▼
┌───────────────────────────────────────────────────────────┐
│ Stage 3: STRUCTURAL CHECKING (Checker.pm)                 │
│ ─────────────────────────────────────────────────────────│
│ • エイリアスサイクル検出                                  │
│ • 未宣言型変数検出                                        │
│ • Kind エラー検出                                         │
│ • Typeclass 上位クラス参照/サイクル検査                  │
│ • Protocol 状態機械検証 (状態、遷移、到達可能性)         │
│                                                           │
│ エラー種別: CycleError, TypeError, UnknownType, KindError │
└───────────────────────────────────────────────────────────┘
    │
    ▼
┌───────────────────────────────────────────────────────────┐
│ Stage 4: TYPE CHECKING (TypeChecker.pm)                   │
│ ─────────────────────────────────────────────────────────│
│ • グローバル環境構築 (全変数 + 関数)                     │
│ • ループ変数型推論                                        │
│ • ローカル変数型推論                                      │
│ • 変数初期化型互換性検査                                  │
│ • 代入型互換性検査                                        │
│ • CallChecker で全呼び出し箇所を検査                     │
│ • 戻り値型互換性検査                                      │
│ • NarrowingEngine で制御フロー型絞り込み                 │
│                                                           │
│ エラー種別: TypeMismatch, ArityMismatch, ResolveError    │
└───────────────────────────────────────────────────────────┘
    │
    ▼
┌───────────────────────────────────────────────────────────┐
│ Stage 5: EFFECT CHECKING (EffectChecker.pm)               │
│ ─────────────────────────────────────────────────────────│
│ • 各アノテーション付き関数について:                      │
│   - 呼び出し先関数とその効果を収集                       │
│   - 呼び出し先の効果ラベル ⊆ 呼び出し元の宣言効果行     │
│ • 未アノテーション関数の効果を推論 (LSP ヒント用)        │
│                                                           │
│ エラー種別: EffectMismatch                                │
└───────────────────────────────────────────────────────────┘
    │
    ▼
┌───────────────────────────────────────────────────────────┐
│ Stage 6: PROTOCOL CHECKING (ProtocolChecker.pm)           │
│ ─────────────────────────────────────────────────────────│
│ • Protocol 状態機械を持つ各効果について:                 │
│   - 関数本体の文をトレース                               │
│   - 直接操作: Label::op(...) → 状態遷移                 │
│   - if/else 分岐 → 分岐状態の union                     │
│   - ループ → 冪等性検証 (状態不変)                      │
│   - handle ブロック → * → * でトレース                  │
│   - match 腕 → 腕終了状態の union                       │
│ • 最終状態が宣言終了状態と一致するか検証                 │
│                                                           │
│ エラー種別: ProtocolMismatch                              │
└───────────────────────────────────────────────────────────┘
    │
    ▼
┌───────────────────────────────────────────────────────────┐
│ OUTPUT                                                     │
│ ─────────────────────────────────────────────────────────│
│ • diagnostics        (重大度ランク付きエラー)            │
│ • symbols            (型強化シンボルインデックス)        │
│ • registry           (型定義)                            │
│ • protocol_hints     (状態遷移ヒント)                    │
│ • narrowed_accessors (struct フィールド型)               │
│ • inferred_effects   (未アノテーション関数の効果)        │
│ • inferred_fn_returns (推論された戻り値型)               │
└───────────────────────────────────────────────────────────┘
```

### 5.2 型推論アルゴリズム

#### 5.2.1 値からの型推論 (Inference::infer_value)

```perl
infer_value(undef)     → Undef
infer_value(42)        → Int
infer_value(3.14)      → Double
infer_value("hello")   → Str
infer_value([1, 2, 3]) → ArrayRef[Int]
infer_value({a => 1})  → HashRef[Int]
```

配列/ハッシュ要素には LUB を使用：

```perl
infer_value([1, "a"]) → ArrayRef[Any]  # LUB(Int, Str) = Any
```

#### 5.2.2 静的型推論 (Static::Infer)

PPI AST 上で型推論を実行：

- **リテラル**: 数値、文字列、ワードリスト
- **コンストラクタ**: 配列 `[...]`、ハッシュ `{...}`、無名 sub
- **演算子**: 単項/二項演算子と優先順位テーブル
- **制御フロー**: `if/then/else` (分岐型の union)、`match` 式
- **関数呼び出し**: Registry でシグネチャ検索、パラメータ/戻り値型推論
- **変数**: 環境で変数型を追跡、添字チェーンを追跡

#### 5.2.3 Unification アルゴリズム

```perl
sub _unify($formal, $actual, $bindings) {
    # 型変数: バインド
    if ($formal->is_var) {
        $bindings->{$formal->name} = $actual;
        return 1;
    }
    
    # パラメータ化型: 再帰的 unify
    if ($formal->is_param && $actual->is_param) {
        return 0 unless $formal->name eq $actual->name;
        for my $i (0 .. $#formal_params) {
            return 0 unless _unify($formal_params[$i], $actual_params[$i], $b);
        }
        return 1;
    }
    
    # 関数型: contravariant params, covariant return
    if ($formal->is_func && $actual->is_func) {
        # params: actual <: formal (contravariant)
        # return: formal <: actual (covariant)
    }
    
    # Row: Rémy-style unification
    # ...
}
```

### 5.3 Narrowing Engine

制御フローベースの型絞り込み：

```perl
sub process($x) {  # $x: Int | Undef
    if (defined $x) {
        # ここでは $x: Int
        return $x + 1;
    } else {
        # ここでは $x: Undef
        return 0;
    }
}
```

サポートするパターン：

| パターン | 絞り込み |
|----------|----------|
| `if (defined $x)` | `T \| Undef` → `T` |
| `if ($x)` | 真値に絞り込み |
| `unless (defined $x)` | `T \| Undef` → `Undef` |
| `if (ref($x) eq 'ARRAY')` | `ArrayRef[T]` に絞り込み |
| 早期 return | 残りのコードで型を絞り込み |

---

## 6. ランタイム型強制

### 6.1 有効化メカニズム

```perl
# 方法 1: import フラグ
use Typist -runtime;

# 方法 2: 環境変数
$ENV{TYPIST_RUNTIME} = 1;

# 方法 3: 直接代入
$Typist::RUNTIME = 1;
```

### 6.2 強制メカニズム

#### 6.2.1 Scalar Variable Tie

```perl
my $x :sig(Int) = 10;

# $Typist::RUNTIME が真の場合:
# tie $$x, 'Typist::Tie::Scalar', type => Int, ...
```

**Tie 実装**:

```perl
package Typist::Tie::Scalar;

sub TIESCALAR ($class, %args) {
    bless { type => $args{type}, value => undef, ... }, $class;
}

sub STORE ($self, $value) {
    my $type = $self->{type};
    unless ($type->contains($value)) {
        die "Typist: type error — expected $type, got $value\n";
    }
    $self->{value} = $value;
}

sub FETCH ($self) { $self->{value} }
```

#### 6.2.2 Function Wrapper

```perl
sub add :sig((Int, Int) -> Int) { ... }

# Runtime wrapper (simplified):
sub add {
    my @args = @_;
    
    # パラメータ検証
    die "..." unless $ptypes[0]->contains($args[0]);
    die "..." unless $ptypes[1]->contains($args[1]);
    
    # 元関数呼び出し
    my @result = $original->(@args);
    
    # 戻り値検証
    die "..." unless $return_type->contains($result[0]);
    
    @result;
}
```

#### 6.2.3 Generic Function Wrapper

```perl
sub first :sig(forall T => ArrayRef[T] -> T) { ... }

# Runtime wrapper:
# 1. 引数から型推論: T → Int
# 2. Bound 検査
# 3. TypeClass 制約検査
# 4. 型を置換してパラメータ/戻り値検証
```

### 6.3 Constructor 検証 (常時有効)

**Struct コンストラクタ**:

```perl
my $point = Point(x => 1, y => 2);

# 検証ステップ:
# 1. 未知フィールド検査
# 2. 必須フィールド検査
# 3. Generic 型変数推論
# 4. Bound 検査
# 5. TypeClass インスタンス検査
# 6. フィールド型検証
```

**Newtype コンストラクタ**:

```perl
my $id = UserId(42);

# 検証: Int->contains(42)
```

### 6.4 Effect Handler ランタイム

**LIFO スタックアーキテクチャ**:

```perl
my %EFFECT_STACKS;  # effect_name => [handlers, ...]

sub push_handler ($class, $effect_name, $handlers) {
    push @{$EFFECT_STACKS{$effect_name} //= []}, $handlers;
}

sub find_handler ($class, $effect_name) {
    my $stack = $EFFECT_STACKS{$effect_name} // return undef;
    @$stack ? $stack->[-1] : undef;  # O(1) 検索
}
```

### 6.5 パフォーマンス影響

| コンポーネント | コスト | 頻度 |
|----------------|--------|------|
| **Scalar 代入** | `contains()` 呼び出し | 毎代入 |
| **関数エントリ** | パラメータ検証 + 推論 | 毎呼び出し |
| **Generic インスタンス化** | 型推論 + バインド検索 | 毎多相呼び出し |
| **Struct 構築** | フィールド検証 + generic バインド | 毎コンストラクタ |
| **Effect handler 検索** | Hash O(1) + Array O(1) | 毎効果操作 |

**最適化**:

- Atom 型プール (singleton)
- 遅延型パース + キャッシュ
- Bound 式の事前パース

**Runtime 無効時** (`$Typist::RUNTIME = 0`):

- 変数: tie なし → 代入は**無料**
- 関数: ラップなし → 呼び出しは**無料**
- Struct/Newtype: 検証は**常時** (オプトアウト不可)

---

## 7. LSP サーバー実装

### 7.1 アーキテクチャ概要

```
┌─────────────────────────────────────────────────────────────┐
│                    Client (Editor)                          │
│              VSCode, Emacs, Vim, etc.                       │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│               Transport (Transport.pm)                      │
│  • Content-Length header framing (LSP 標準)                │
│  • JSON-RPC 2.0 プロトコル                                 │
│  • JSONL トレース (TYPIST_LSP_TRACE)                       │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                  Server (Server.pm)                         │
│  • メッセージディスパッチ (%DISPATCH テーブル)             │
│  • ライフサイクル管理 (initialize, shutdown, exit)         │
│  • 例外安全なハンドラ呼び出し                              │
└─────────────────────────────────────────────────────────────┘
                           │
              ┌────────────┴────────────┐
              ▼                         ▼
┌─────────────────────┐    ┌─────────────────────────────────┐
│  Document (Doc.pm)  │    │      Workspace (Workspace.pm)   │
│  • URI ごとの状態   │    │  • 共有 Registry                │
│  • 分析キャッシュ   │    │  • 2フェーズスキャン            │
│  • シンボル解決     │    │  • 差分更新                     │
└─────────────────────┘    │  • クロスファイルクエリ         │
                           └─────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                  Feature Providers                          │
│  Hover, Completion, Definition, References, Rename,        │
│  SignatureHelp, InlayHints, CodeActions, SemanticTokens,   │
│  DocumentSymbols, Diagnostics                              │
└─────────────────────────────────────────────────────────────┘
```

### 7.2 サポート機能

| 機能 | クラス | 説明 |
|------|--------|------|
| **Hover** | `Hover.pm` | 関数、変数、パラメータ、型、効果、typeclass、datatype、struct、フィールド、メソッド |
| **Completion** | `Completion.pm` | 型式 (primitives, parametrics, typedefs)、generics、effects、constraints、コードレベル (fields, methods, effect ops, match arms) |
| **Diagnostics** | `_publish_diagnostics()` | 型検査、効果検査、戻り値型ミスマッチ |
| **Code Actions** | `CodeAction.pm` | Quick-fix: 不足効果追加、型変更、カスタム提案 |
| **Semantic Tokens** | `SemanticTokens.pm` | デルタエンコードトークン (11 types × 3 modifiers) |
| **Definition** | `_handle_definition()` | 同一ファイル、クロスファイル、効果定義、struct フィールド |
| **References** | `_handle_references()` | 変数スコープ aware、名前付きシンボルはワークスペース全体 |
| **Signature Help** | `_handle_signature_help()` | 関数シグネチャ、struct コンストラクタ、メソッド解決 |
| **Document Symbols** | `_handle_document_symbol()` | 関数、型、変数のアウトライン |
| **Rename** | `_handle_rename()` | ワークスペーススキャンによるクロスファイルリネーム |
| **Inlay Hints** | `_handle_inlay_hint()` | 推論/narrowing からの型アノテーション |

### 7.3 クロスファイル型解決

**フロー**:

1. ドキュメント open/save → `Workspace::update_file()` が型を抽出・登録
2. クライアントが hover/completion/diagnostics 要求 → `Document::analyze()` が `workspace_registry` で呼び出される
3. Analyzer が共有 registry で型を解決: `$registry->lookup_type()`, `lookup_function()`, etc.
4. Struct フィールド/メソッド呼び出し: `_resolve_var_type()` → parse → `_resolve_type_deep()` → registry 検索

**キーポイント**:

- ワークスペースは起動時に全 `.pm` ファイルをスキャン; save 時は差分のみ
- Registry は全 aliases, newtypes, datatypes, effects, typeclasses, functions をワークスペース全体で追跡
- 2フェーズ登録により typeclass 制約がメソッド登録前にパース可能
- "Ghost" 型防止: 新規登録前に古いエントリを登録解除

### 7.4 Capability 登録

`initialize` レスポンスで宣言:

- テキスト同期 (full + save)
- Hover, Definition, References, Rename
- Completion (トリガー文字: `(`, `[`, `,`, `|`, `&`, `>`, `{`, `:`)
- Signature help
- Semantic tokens (full), Inlay hints, Code actions (quickfix)
- Document symbols

---

## 8. エラーハンドリングシステム

### 8.1 エラーコンポーネント

#### 8.1.1 Error 値オブジェクト

```perl
Typist::Error->new(
    kind          => 'TypeError',    # エラー分類
    message       => '...',          # 人間可読メッセージ
    file          => 'foo.pm',       # ソースファイル
    line          => 42,             # 行番号
    col           => 5,              # 列番号
    end_line      => 42,             # 終了行 (optional)
    end_col       => 15,             # 終了列 (optional)
    expected_type => 'Int',          # 期待型 (optional)
    actual_type   => 'Str',          # 実際型 (optional)
    related       => [...],          # 関連情報 (optional)
    suggestions   => [...],          # 修正提案 (optional)
);
```

#### 8.1.2 出力フォーマット

```
  - [TypeError] expected Int, got Str
      at myfile.pm line 42 col 5
```

### 8.2 エラー収集アーキテクチャ

**2層収集システム**:

| 層 | クラス | 用途 | スコープ |
|----|--------|------|----------|
| **Instance-based** | `Error::Collector` | LSP、静的チェッカー | 分析ごと |
| **Singleton** | `Error::Global` | CHECK phase | パッケージ全体 |

### 8.3 エラー重大度

| 重大度 | レベル | エラー種別 |
|--------|--------|------------|
| **1** | Critical | `CycleError` — 型解決を阻止 |
| **2** | High | `TypeError`, `TypeMismatch`, `ArityMismatch`, `ResolveError`, `EffectMismatch`, `UnknownTypeClass`, `ProtocolMismatch` |
| **3** | Medium | `UndeclaredTypeVar`, `UndeclaredRowVar`, `UnknownEffect` |
| **4** | Low | `UnknownType` |

### 8.4 エラー回復メカニズム

1. **Parse エラー**: `eval { ... }` ブロックでラップ
2. **未定義解決フォールバック**: 不足関数シグネチャ → untyped として扱う (gradual typing)
3. **位置エンリッチメント**: 汎用位置 → 抽出データから検索
4. **行フィルタリング**: `@typist-ignore` コメントで診断抑制

---

## 9. 状態管理とレジストリ

### 9.1 データ構造

**Registry.pm** は 13 のハッシュベースストアを使用:

| ストア | 目的 | キー構造 |
|--------|------|----------|
| `aliases` | 型エイリアス定義 | name → expr string |
| `resolved` | パース済みエイリアスキャッシュ | name → Type object |
| `newtypes` | 名前的型ラッパー | name → Type::Newtype |
| `datatypes` | 代数的データ型 | name → Type::Data |
| `structs` | レコード型 | name → Type::Struct |
| `effects` | 効果ラベル | name → Effect |
| `typeclasses` | 型クラス定義 | name → TypeClass::Def |
| `instances` | Typeclass 実装 | class_name → [instances] |
| `functions` | 関数シグネチャ | "pkg::name" → sig hashref |
| `methods` | メソッドシグネチャ | "pkg::name" → sig hashref |
| `variables` | 型付き変数参照 | stringify(ref) → info |
| `name_index` | 高速ベア名検索 | name → [fqn_list] |
| `instance_index` | Typeclass インスタンスキャッシュ | class_name → {type_expr → inst} |

### 9.2 Singleton vs Instance-based

**ハイブリッドデュアルモードパターン**:

```perl
my $DEFAULT;
sub _default ($class) { $DEFAULT //= $class->new }

sub _self ($invocant) {
    ref $invocant ? $invocant : $invocant->_default;
}
```

- **クラスメソッド呼び出し**: `Typist::Registry->define_alias(...)` → `$DEFAULT` singleton
- **インスタンスメソッド呼び出し**: `$registry->define_alias(...)` → 特定インスタンス

### 9.3 メモリリーク防止

```perl
sub register_variable ($invocant, $info) {
    my $key = $info->{ref} // die "register_variable requires ref";
    $self->{variables}{"$key"} = $info;
    weaken($self->{variables}{"$key"}{ref});  # 重要
}
```

変数は Registry を通じてレキシカルキャプチャで参照する可能性 → 弱参照なしで循環参照になる。

### 9.4 潜在的問題

| 重大度 | 問題 | 影響 |
|--------|------|------|
| 🔴 | `resolved` キャッシュはワークスペース変更時のみクリア | テスト信頼性 |
| 🔴 | 型オブジェクトの循環参照保護なし | メモリリーク |
| 🟡 | 名前インデックス衝突処理 (最初のマッチを無言で返却) | 曖昧な解決 |
| 🟡 | `_rebuild_registry()` が未使用 | デッドコード? |

---

## 10. Prelude システム

### 10.1 カバレッジ

**84 のビルトイン関数**:

| カテゴリ | 関数 |
|----------|------|
| **IO** | `say`, `print`, `warn`, `die`, `open`, `close`, `read`, `write`, `binmode`, `eof`, `seek`, `tell` |
| **String** | `length`, `substr`, `uc`, `lc`, `ucfirst`, `lcfirst`, `index`, `rindex`, `chomp`, `chop`, `chr`, `ord`, `hex`, `oct`, `quotemeta`, `sprintf` |
| **Numeric** | `abs`, `int`, `sqrt`, `log`, `exp`, `sin`, `cos`, `atan2`, `rand`, `srand` |
| **Introspection** | `defined`, `ref`, `wantarray`, `caller` |
| **Arrays** | `scalar`, `push`, `pop`, `shift`, `unshift`, `splice`, `reverse`, `sort`, `map`, `grep` |
| **Hashes** | `keys`, `values`, `each`, `delete`, `exists` |
| **String Match** | `split`, `join`, `pack`, `unpack` |
| **System** | `eval`, `require`, `use`, `exit`, `system`, `exec`, `sleep`, `time`, `localtime`, `gmtime` |
| **Typist** | `typedef`, `newtype`, `effect`, `typeclass`, `instance`, `declare`, `datatype`, `enum`, `struct` |

### 10.2 効果アノテーション

3つの**アンビエント効果** (handler 不要):

```perl
IO   # I/O 操作 (say, print, read, open, time, rand, sleep)
Exn  # 例外 (die, exit, eval)
Decl # 宣言 (typedef, struct, enum, etc.)
```

例:

```perl
say  => '(...Any) -> Bool ![IO]'
die  => '(...Any) -> Never ![Exn]'
typedef => '(...Any) -> Void ![Decl]'
```

### 10.3 拡張性

**ユーザーオーバーライド**:

```perl
declare say => '(Str) -> Void ![Console]';  # prelude を置換
```

**カスタム効果登録**:

```perl
$registry->register_effect('Console', 
    Typist::Effect->new(name => 'Console', operations => {...}));
```

### 10.4 カバレッジギャップ

**省略されているもの**:

- ファイルテスト演算子 (`-f`, `-d`, `-e`)
- モジュールリフレクション (`@ISA`, `%INC`)
- 参照操作 (`bless`, `tie`, `untie`)
- 多くのリストユーティリティ

**対策**: `declare` 文でユーザー拡張可能

---

## 11. テストスイート評価

### 11.1 テスト構造

| カテゴリ | ファイル数 | 範囲 |
|----------|------------|------|
| **Core** | 29 | parser, subtype, inference, effects, HKT, GADT, protocols |
| **Static** | 17 | extraction, inference, type checking, narrowing |
| **LSP** | 20 | transport, server, all features |
| **Critic** | 4 | Perl::Critic policies |
| **E2E** | 1 | LSP lifecycle (subprocess) |
| **合計** | 78 | |

### 11.2 テスト種別

#### 11.2.1 Core テスト (t/)

```
00_compile.t          - モジュールコンパイル (60+ modules)
01_parser.t           - 型パーサー (atoms, params, unions, etc.)
01b_parser_edge.t     - パーサーエッジケース
02_subtype.t          - サブタイプ関係
02b_subtype_edge.t    - サブタイプエッジケース
04_inference.t        - 値/型推論
05_integration.t      - E2E ランタイム型付け
...
12_typeclass.t        - 型クラス
13_hkt.t              - Higher-kinded types
13b_kind_edge.t       - Kind システムエッジケース
14-17_effects_*.t     - 効果システム
...
27_protocol.t         - Protocol FSM
27b_protocol_edge.t   - Protocol エッジケース
```

#### 11.2.2 Static テスト (t/static/)

```
00_extractor.t        - ソースコード抽出
01_analyzer.t         - 静的アナライザ
02_infer.t            - 静的型推論
03_typecheck.t        - 型検査 (150+ tests)
04_effects.t          - 静的効果検査
...
16_narrowing_edge.t   - Narrowing エッジケース
17_unify_edge.t       - Unification エッジケース
```

#### 11.2.3 LSP テスト (t/lsp/)

```
00_transport.t        - JSON-RPC transport
01_server.t           - サーバーライフサイクル
02_diagnostics.t      - 診断パブリッシュ
03_hover.t            - Hover プロバイダ
04_completion.t       - Completion プロバイダ
...
16_semantic_tokens.t  - Semantic Tokens
17_protocol.t         - Protocol hover/inlay hints
19_workspace_edge.t   - Workspace エッジケース
e2e_smoke.pl          - E2E 煙テスト (subprocess)
```

### 11.3 Edge Case テスト

**6つの専用エッジケースファイル**:

| ファイル | 内容 |
|----------|------|
| `01b_parser_edge.t` | 空入力、不正構文、閉じ忘れ括弧 |
| `02b_subtype_edge.t` | サブタイプ境界条件 |
| `13b_kind_edge.t` | Kind システム境界 |
| `27b_protocol_edge.t` | Protocol エッジケース |
| `16_narrowing_edge.t` | 型 narrowing 境界 |
| `17_unify_edge.t` | Unification エッジケース |
| `19_workspace_edge.t` | LSP workspace 境界 |
| `29_type_constructors_edge.t` | 型コンストラクタ境界 |

### 11.4 テストヘルパー

**Test::Typist::LSP** (`t/lib/Test/Typist/LSP.pm`):

```perl
frame()              # JSON-RPC メッセージフレーミング
run_session()        # インメモリ LSP サーバーテスト
parse_responses()    # レスポンスパース
lsp_request()        # リクエストビルダー
lsp_notification()   # 通知ビルダー
init_shutdown_wrap() # LSP ライフサイクルラップ
```

### 11.5 カバレッジ評価

**強み**:

✅ 包括的 — 70+ テストファイルが parser, inference, effects, static analysis, LSP をカバー  
✅ エッジケース — クリティカルシステムの専用エッジケーステスト  
✅ 統合 — runtime, static, LSP レベルの E2E テスト  
✅ 品質 — Perl::Critic によるコード品質チェック  

**ギャップ**:

⚠️ パフォーマンス — ベンチマーク/パフォーマンステストなし  
⚠️ エラー回復 — エラー回復パスの限定的テスト  
⚠️ モジュール相互作用 — static analyzer 以外のクロスモジュール統合テスト限定  
⚠️ 並行性 — スレッド/非同期テストなし  

---

## 12. コード品質評価

### 12.1 コーディング規約

すべてのモジュールが以下を使用:

```perl
use v5.40;
use strict;
use warnings;
```

**規約ドキュメント**:

- `CLAUDE.md` — AI アシスタント向けコンテキスト
- `docs/conventions.md` — コーディング規約

### 12.2 Perl::Critic ポリシー

`t/critic/` にカスタムポリシー:

| ポリシー | 説明 |
|----------|------|
| `00_policy.t` | Perl::Critic policy validation |
| `01_annotation_style.t` | アノテーションスタイル検査 |
| `02_effect_completeness.t` | 効果完全性検証 |
| `03_exhaustiveness.t` | 網羅性検査 |

### 12.3 モジュール化

- Registry は global state だが適切に抽象化
- Type::* の階層が明確で拡張しやすい
- LSP の feature provider が独立しており機能追加が容易

### 12.4 ドキュメンテーション

```
docs/getting-started.md      - 初学者向け
docs/type-system.md          - 型システム詳細
docs/architecture.md         - システム設計
docs/static-analysis.md      - 静的解析パイプライン
docs/conventions.md          - コーディング規約
docs/lsp-coverage.md         - LSP 機能マトリクス
docs/index.md                - ナビゲーションハブ
```

---

## 13. 懸念事項と改善提案

### 13.1 Critical (P0)

#### 13.1.1 パフォーマンステストの追加

**問題**: 大規模コードベース（10,000+ 行）での静的解析速度が未検証。

**提案**:

```bash
# mise.toml に追加
[tasks.bench]
run = "perl -Ilib t/bench/performance.t"
```

```perl
# t/bench/performance.t
use Benchmark qw(:all);

my $large_source = generate_large_source(10_000);
cmpthese(10, {
    'parse'   => sub { PPI::Document->new(\$large_source) },
    'analyze' => sub { Typist::Static::Analyzer->new->analyze($large_source) },
});
```

#### 13.1.2 エラーメッセージの改善 ✅

**対応済み**: メッセージ文面を能動態に改善し、`suggestions`/`related` フィールドを実装。

**改善前**:
```
[TypeMismatch] Variable $x: expected Int, got Str
```

**改善後**:
```
[TypeMismatch] Variable $x: cannot assign Str to Int
  suggestion: Change annotation to :sig(Str)
  related: declared here (line N)
```

**実装内容**:
- `TypeChecker.pm` / `CallChecker.pm` の全エラー発行箇所に `suggestions` と `related` を追加
- `CodeAction.pm` が `suggestions` を自動消費し LSP quickfix 化（重複排除あり）
- `related` は LSP `relatedInformation` として宣言箇所を参照

#### 13.1.3 初学者向けチュートリアル

**問題**: Effect システムや HKT は学術的に先進的だが、学習コストが高い。

**提案**:

```
docs/tutorial/
├── 01-basic-types.md        # Int, Str, Array, Hash
├── 02-function-signatures.md # :sig() アノテーション
├── 03-generics.md           # 型パラメータ
├── 04-newtypes-structs.md   # 名前的型
├── 05-effects-intro.md      # 効果の基本
├── 06-row-polymorphism.md   # Row polymorphism
├── 07-effect-handlers.md    # Handler の使い方
└── 08-protocols.md          # Protocol FSM
```

### 13.2 High (P1)

#### 13.2.1 クロスモジュール統合テスト

**問題**: 個別機能のテストは充実しているが、複数機能の組み合わせテストが不足。

**提案**:

```perl
# t/30_integration_matrix.t
subtest 'HKT + Effects' => sub {
    # Functor over effectful computations
};

subtest 'TypeClass + Generics + Narrowing' => sub {
    # Bounded polymorphism with control flow
};

subtest 'Protocol + DataType + Handler' => sub {
    # State machine over ADT operations
};
```

#### 13.2.2 Type Stub メカニズム

**問題**: CPAN モジュールの多くは型アノテーションなし。

**提案**:

```
.typist.d/
├── LWP/
│   └── UserAgent.pm.typist
├── DBI.pm.typist
└── JSON.pm.typist
```

```perl
# .typist.d/JSON.pm.typist
declare 'JSON::encode_json' => '(Any) -> Str';
declare 'JSON::decode_json' => '(Str) -> Any';
```

#### 13.2.3 LSP Async 化検討

**問題**: 現在の実装は sequential message handling。

**現状**:
```perl
while (my $msg = read_message()) {
    dispatch($msg);  # ブロッキング
}
```

**提案**: 大規模プロジェクトでの応答性を検証し、必要に応じて async 化。

### 13.3 Medium (P2)

#### 13.3.1 Playground Web UI

ブラウザで Typist を試せる環境。

#### 13.3.2 CI/CD 強化

- GitHub Actions で複数 Perl バージョンテスト
- Coverage レポート (Devel::Cover)

#### 13.3.3 コミュニティガイドライン

- CONTRIBUTING.md
- Issue/PR テンプレート

### 13.4 Low (P3)

#### 13.4.1 Registry キャッシュ一貫性

**問題**: `resolved` キャッシュが singleton 操作でクリアされない。

**提案**: `define_alias()` で自動的にキャッシュをクリア。

#### 13.4.2 型オブジェクト循環参照

**問題**: 変数のみ `weaken()` され、型オブジェクトは保護なし。

**提案**: `Type::Data` など自己参照可能な型で弱参照を使用。

---

## 14. 総合評価

### 14.1 スコアカード

| 項目 | 評価 | 詳細 |
|------|------|------|
| **アーキテクチャ** | ⭐⭐⭐⭐⭐ | 明確な責務分離、高い拡張性、適切な抽象化 |
| **型システム** | ⭐⭐⭐⭐⭐ | 学術的に洗練 (HKT, Row polymorphism)、実用性も高い |
| **静的解析** | ⭐⭐⭐⭐☆ | 包括的パイプライン、パフォーマンス未検証 |
| **LSP 実装** | ⭐⭐⭐⭐⭐ | Enterprise-grade、全主要機能をカバー |
| **テスト品質** | ⭐⭐⭐⭐☆ | 高カバレッジ、エッジケース充実、統合テスト増強推奨 |
| **ドキュメント** | ⭐⭐⭐⭐☆ | 詳細だが初学者向け不足 |
| **コード品質** | ⭐⭐⭐⭐⭐ | 一貫した規約、Perl::Critic 活用 |
| **革新性** | ⭐⭐⭐⭐⭐ | Effect System, Gradual Typing が先進的 |

### 14.2 SWOT 分析

#### Strengths (強み)

- **Static-First アーキテクチャ**: コンパイル時チェックを優先し、開発速度向上
- **学術的に先進的な型システム**: HKT, Row polymorphism, GADT を実用レベルで実装
- **包括的な LSP 統合**: 開発者体験 (DX) が良い
- **Gradual Typing**: 既存コードへの導入障壁が低い
- **高いテストカバレッジ**: 78 ファイル、エッジケース充実

#### Weaknesses (弱み)

- **学習コスト**: Effect System は Perl コミュニティに馴染みが薄い
- **パフォーマンス未検証**: 大規模プロジェクトでの動作が不明
- **初学者向けリソース不足**: チュートリアルが限定的
- **Global State**: Registry singleton によるテスト間汚染リスク

#### Opportunities (機会)

- **Perl モダナイゼーション**: 型安全性を求める Perl プロジェクトに価値提供
- **教育**: 型理論の実践的学習ツールとして
- **IDE 統合**: VSCode 以外のエディタサポート拡大

#### Threats (脅威)

- **Perl エコシステムとの統合**: CPAN モジュールの型なし問題
- **メンテナンス負荷**: 高度な型システムは継続的コストが高い
- **競合**: TypeScript などの静的型付け言語への移行圧力

### 14.3 結論

**Typist は Perl の型システムとして最先端の設計を持っています。**

技術的には極めて高水準であり、学術研究（HKT, Row polymorphism）を実用レベルに落とし込んでいます。静的解析優先の設計により、Perl に型安全性をもたらす可能性があります。LSP 統合が充実しており、開発者体験も良好です。

**今後の課題**:

1. **学習コスト低減**: 初学者向けチュートリアルとドキュメント整備
2. **エコシステム統合**: Type stub メカニズムで CPAN モジュールの型定義
3. **パフォーマンス検証**: 大規模プロジェクトでのベンチマーク

これらの推奨事項を段階的に実装することで、産業利用に耐えうる品質への成熟が期待できます。

---

## 付録

### A. 用語集

| 用語 | 説明 |
|------|------|
| **HKT** | Higher-Kinded Types — 型コンストラクタを型パラメータとして扱う |
| **Row Polymorphism** | 効果行の多相性 (Rémy-style) |
| **Gradual Typing** | 型アノテーションを段階的に導入可能 |
| **Nominal Type** | 名前による型同一性 (newtype, struct) |
| **Structural Type** | 構造による型同一性 (record, union) |
| **Effect** | 関数の副作用を型レベルで追跡 |
| **Protocol FSM** | 効果の状態遷移を有限状態機械で表現 |
| **LUB** | Least Upper Bound — 共通上界型 |
| **Narrowing** | 制御フローによる型絞り込み |

### B. 参考文献

- **Row Polymorphism**: Rémy, D. "Type Inference for Records in a Natural Extension of ML"
- **Algebraic Effects**: Plotkin, G. & Power, J. "Algebraic Operations and Generic Effects"
- **Gradual Typing**: Siek, J. & Taha, W. "Gradual Typing for Functional Languages"
- **Higher-Kinded Types**: Pierce, B. "Types and Programming Languages"

### C. 関連ドキュメント

- [docs/getting-started.md](getting-started.md) — 初学者向けガイド
- [docs/type-system.md](type-system.md) — 型システム詳細
- [docs/architecture.md](architecture.md) — システム設計
- [docs/static-analysis.md](static-analysis.md) — 静的解析パイプライン
- [docs/lsp-coverage.md](lsp-coverage.md) — LSP 機能マトリクス

---

## 15. 対応状況

> **更新日**: 2026-03-05

§13 の懸念事項・改善提案に対する対応状況。

### 対応済み

| 提案 | 対応内容 |
|------|---------|
| Parser 防御的制限 (P3) | 再帰深度制限 (`$_MAX_PARSE_DEPTH = 64`) + 入力長制限 (`$_MAX_INPUT_LENGTH = 10_000`) を追加 |
| LSP Transport 安全性 (P3) | `$MAX_CONTENT_LENGTH = 10MB` 上限チェックを追加 |
| Unification occurs check (P3) | `unify` / `collect_bindings` に occurs check を追加。無限型 (`T = ArrayRef[T]`) を拒否 |
| GADT 戻り値型検証 | `Registration::register_datatypes` に戻り値型のベース名検証を追加 |
| Row::substitute 非Row バインディング | 非Row バインディング時に row_var を除去した closed row を返すよう修正 |
| KindChecker 未知コンストラクタ | gradual kinding の設計意図をコメントで明文化 |
| Subtype キャッシュ上限 | `$_CACHE_SIZE_LIMIT = 5000` 超過時に自動クリア |
| Workspace キャッシュ無効化 | `_unregister_file_types` で Subtype キャッシュもクリア |
| Type::Alias エラー戦略統一 | `contains` を `local` depth ガード + 安全な失敗 (`return 0`) に統一 |
| LSP 命名規則統一 | `_resolve_var_type` → `resolve_var_type`, `_resolve_type_deep` → `resolve_type_deep` にリネーム |
| Infer.pm グローバル状態 | `@_CALLBACK_PARAMS` の安全性をコメントで明文化 |
| Parser キャッシュ epoch オーバーフロー | `2**53` 超過時のリセット処理を追加 |
| Typist.pm モジュール分割 | 5サブモジュールに分割 (Definition, Algebra, StructDef, EffectDef, External)。公開 API 不変 |
| エラーメッセージ改善 (§13.1.2) | `suggestions`/`related` フィールド実装。メッセージ文面を能動態に改善。CodeAction が自動消費し LSP quickfix 化 |

### 将来対応

| 提案 | 方針 |
|------|------|
| パフォーマンスベンチマーク (P0) | 大規模コードベースでの実測が必要。テストインフラ整備後に対応 |
| 初学者向けチュートリアル (P0) | getting-started.md の拡充で対応予定 |
| TypeChecker 責務分離 (P1) | multi-pass 最適化と同時に実施 |
| 型スタブ機構 (P1) | CPAN モジュール型定義の外部ファイル化。設計検討中 |
