# Typist 改善実行指示書

本文書は、Typist 型システムを次の段階へ進めるための包括的な実行指示書である。各タスクは独立したエージェントに渡せるよう、背景・目標・影響範囲・実装指針・テスト計画を含む。

優先度は A（基盤強化）> B（検出力向上）> C（表現力拡張）> D（最適化）の順。

---

## 目次

- [Phase A: 静的解析の基盤強化](#phase-a-静的解析の基盤強化)
  - [A-1: アリティ検査の追加](#a-1-アリティ検査の追加)
  - [A-2: 式レベル型推論の拡張](#a-2-式レベル型推論の拡張)
  - [A-3: 変数再代入の追跡](#a-3-変数再代入の追跡)
  - [A-4: メソッド呼び出しの型チェック](#a-4-メソッド呼び出しの型チェック)
- [Phase B: 型検査の深化](#phase-b-型検査の深化)
  - [B-1: ジェネリック関数の静的型チェック](#b-1-ジェネリック関数の静的型チェック)
  - [B-2: 制御フロー型（Type Narrowing）](#b-2-制御フロー型type-narrowing)
  - [B-3: 暗黙戻り値の分岐解析](#b-3-暗黙戻り値の分岐解析)
- [Phase C: 型システムの表現力拡張](#phase-c-型システムの表現力拡張)
  - [C-1: 代数的データ型（Tagged Union / ADT）](#c-1-代数的データ型tagged-union--adt)
  - [C-2: エフェクトハンドラ](#c-2-エフェクトハンドラ)
  - [C-3: HKT の完全化](#c-3-hkt-の完全化)
  - [C-4: 多引数型クラス](#c-4-多引数型クラス)
- [Phase D: ランタイム最適化](#phase-d-ランタイム最適化)
  - [D-1: bounded generic の bound パースキャッシュ](#d-1-bounded-generic-の-bound-パースキャッシュ)
  - [D-2: ラッパーのコンテキスト修正](#d-2-ラッパーのコンテキスト修正)
  - [D-3: Registry variables リーク修正](#d-3-registry-variables-リーク修正)
  - [D-4: unwrap 正規表現の事前コンパイル](#d-4-unwrap-正規表現の事前コンパイル)
- [Phase E: アーキテクチャ整理](#phase-e-アーキテクチャ整理)
  - [E-1: Inference.pm の静的パスへの統合](#e-1-inferencepm-の静的パスへの統合)
  - [E-2: ビルトイン関数のプレリュード化](#e-2-ビルトイン関数のプレリュード化)
  - [E-3: 診断のソースマップ精度向上](#e-3-診断のソースマップ精度向上)

---

## Phase A: 静的解析の基盤強化

### A-1: アリティ検査の追加

**優先度**: 最高 — 最も基本的なバグの検出漏れを修正する

**背景**:
現在 `TypeChecker._check_call_sites` は `min(@params, @args)` まで検査し、引数の過不足を検出しない。`add(1)` や `add(1, 2, 3)` は無警告で通過する。

**目標**:
- 引数が少なすぎる場合: `ArityMismatch: add() expects 2 arguments, got 1`
- 引数が多すぎる場合: `ArityMismatch: add() expects 2 arguments, got 3`

**影響ファイル**:
- `lib/Typist/Static/TypeChecker.pm` — `_check_call_sites` メソッド
- `lib/Typist/Static/Analyzer.pm` — 新しい diagnostic kind `ArityMismatch` の severity 登録

**実装指針**:

```perl
# TypeChecker._check_call_sites 内、引数チェックループの前に追加:
my @param_types = ($sig->{params} // [])->@*;
my @args = $self->_extract_args($arg_list);

# 可変長引数のスキップ: 最後のパラメータが ArrayRef の場合は上限チェックしない
my $is_variadic = @param_types && $param_types[-1]->is_param
    && $param_types[-1]->base eq 'ArrayRef';

if (@args < @param_types && !$is_variadic) {
    $self->{errors}->collect(
        kind    => 'ArityMismatch',
        message => "$name() expects ${\scalar @param_types} arguments, got ${\scalar @args}",
        file    => $self->{file},
        line    => $word->line_number,
    );
    next;  # 型チェックは不要
}

if (@args > @param_types && !$is_variadic) {
    $self->{errors}->collect(
        kind    => 'ArityMismatch',
        message => "$name() expects ${\scalar @param_types} arguments, got ${\scalar @args}",
        file    => $self->{file},
        line    => $word->line_number,
    );
    # 型チェックは min まで続行
}
```

**注意点**:
- `_extract_args` が `Word + List` ペアをグルーピングしている点に留意。ネストした関数呼び出しは1引数として数えられる
- gradual typing: unannotated 関数は `params_expr` が `[Any x N]` なので、正しくアリティが設定されているか確認
- EffectChecker 側は引数チェックしないのでそのまま

**テスト計画**:
- `t/static/03_typecheck.t` に追加:
  - `add(1)` → `ArityMismatch`
  - `add(1, 2, 3)` → `ArityMismatch`
  - `add(1, 2)` → エラーなし
  - ジェネリック関数 → スキップ（既存のガード）
  - `Pkg::func(...)` のクロスパッケージ版
- `t/20_check_diagnostics.t` にサブプロセステスト追加

---

### A-2: 式レベル型推論の拡張

**優先度**: 高 — TypeChecker の検出率に直接影響

**背景**:
`Static::Infer` は現在リテラル・変数参照・関数呼出しのみ推論可能。算術式、三項演算子、添字アクセスなどは `undef`（スキップ）。

**目標**:
以下の式の型推論を追加する（段階的に）。

**Phase A-2a: 算術・比較演算子**

```perl
$a + $b     # 両方 Num のサブタイプ → Num
$a . $b     # 文字列結合 → Str
$a == $b    # 比較 → Bool
$a eq $b    # 文字列比較 → Bool
!$a         # 論理否定 → Bool
```

**影響ファイル**:
- `lib/Typist/Static/Infer.pm` — `infer_expr` メソッドに新しい PPI ノードハンドラ追加

**実装指針**:

```perl
# Infer.pm の infer_expr に追加:

# 二項演算式: PPI::Token::Operator
if ($element->isa('PPI::Token::Operator')) {
    # これは演算子自体のノード。実際には
    # PPI::Statement::Expression の子を走査する必要がある
}

# PPI::Statement の場合: 子要素を走査して演算パターンを検出
# パターン: Expr Op Expr
# PPI は Expression を Statement の直接の子として保持する
```

PPI のツリー構造に注意が必要。PPI は式を `PPI::Statement` の子要素列として保持し、明示的な二項演算ノードを持たない。最も堅実なアプローチは:

1. `PPI::Statement` の直接の子を走査
2. `Symbol/Number/Quote` + `Operator(+,-,*,/,.,==,eq,...)` + `Symbol/Number/Quote` の3つ組パターンを検出
3. 演算子ごとに結果型を決定:
   - 算術 (`+`, `-`, `*`, `/`, `%`, `**`): `Num`
   - 整数除算 (`int(...)` パターン): `Int`
   - 文字列結合 (`.`): `Str`
   - 比較 (`==`, `!=`, `<`, `>`, `<=`, `>=`, `<=>`, `eq`, `ne`, `lt`, `gt`, `le`, `ge`, `cmp`): `Bool`
   - 論理 (`&&`, `||`, `//`, `and`, `or`): 左辺の型 (簡易)
   - 否定 (`!`, `not`): `Bool`

**Phase A-2b: 添字アクセス**

```perl
$arr->[0]        # ArrayRef[T] → T
$hash->{key}     # HashRef[K, V] → V
```

**実装指針**:
- `PPI::Token::Symbol` + `PPI::Token::Operator('->') ` + `PPI::Structure::Subscript` パターン
- `$arr` の型を env から引き、`is_param && base eq 'ArrayRef'` なら要素型を返す
- `$hash` が `HashRef[K, V]` なら V を返す
- Struct 型の場合: `$s->{key}` でフィールド型を返す

**Phase A-2c: 三項演算子**

```perl
$x ? $a : $b    # Union(type($a), type($b))
```

- PPI パターン: `Expr Operator('?') Expr Operator(':') Expr`
- 両ブランチの型を推論し、Union を返す

**テスト計画**:
- `t/static/02_infer.t` に各演算パターンのテスト追加
- `t/static/03_typecheck.t` に推論結果を使った型チェックテスト
- 推論不能な場合は `undef`（既存の gradual typing フォールバック）

---

### A-3: 変数再代入の追跡

**優先度**: 中

**背景**:
TypeChecker は変数の初期化時のみ型を決定する。以降の再代入は無視される。

**目標**:
```perl
my $x :Type(Int) = 0;
$x = "hello";  # TypeMismatch: expected Int, got "hello"
```

**影響ファイル**:
- `lib/Typist/Static/TypeChecker.pm` — 新メソッド `_check_assignments`
- `lib/Typist/Static/Infer.pm` — 代入文の右辺推論（既存 API で対応可能）

**実装指針**:

```perl
sub _check_assignments ($self) {
    my $ppi_doc = $self->{ppi_doc} // return;

    # PPI::Token::Operator '=' を全走査
    my $ops = $ppi_doc->find('PPI::Token::Operator') || [];
    for my $op (@$ops) {
        next unless $op->content eq '=';

        # 左辺: 直前の Symbol
        my $lhs = $op->sprevious_sibling // next;
        next unless $lhs->isa('PPI::Token::Symbol');

        my $var_name = $lhs->content;
        my $declared_type = $self->{env}{variables}{$var_name} // next;

        # my 文内の初期化は _check_variable_initializers が処理済み
        my $stmt = $op->parent;
        next if $stmt && $stmt->isa('PPI::Statement::Variable');

        # 右辺: 直後の式
        my $rhs = $op->snext_sibling // next;
        my $env = $self->_env_for_node($op);
        my $inferred = Typist::Static::Infer->infer_expr($rhs, $env);
        next unless defined $inferred;
        next if $inferred->is_atom && $inferred->name eq 'Any';

        unless (Typist::Subtype->is_subtype($inferred, $declared_type)) {
            $self->{errors}->collect(
                kind    => 'TypeMismatch',
                message => "Assignment to $var_name: expected ${\$declared_type->to_string}, got ${\$inferred->to_string}",
                file    => $self->{file},
                line    => $op->line_number,
            );
        }
    }
}
```

**注意点**:
- `$x += 1` などの複合代入は `+=` 演算子 — 別途対応が必要
- `my` 文内の `=` は `PPI::Statement::Variable` の子なのでスキップ

**テスト計画**:
- `t/static/03_typecheck.t`:
  - `$x :Type(Int) = 0; $x = "hello"` → TypeMismatch
  - `$x :Type(Int) = 0; $x = 42` → OK
  - `my` 文内は重複チェックしない

---

### A-4: メソッド呼び出しの型チェック

**優先度**: 高

**背景**:
`$obj->method()` 形式のメソッド呼び出しは完全にスキップされている。設計指示書が `docs/design/method-type-checking.md` に既にある。

**目標**:
設計指示書の Phase 1-4 を実装する。

**実装指針**:
`docs/design/method-type-checking.md` に詳細な実装計画がある。以下の順で進める:

1. **Phase 1**: TypeChecker に `->` ガード追加 + Extractor に `is_method` フラグ + Registry に `register_method`/`lookup_method`
2. **Phase 2**: 同一パッケージ内のメソッド引数型チェック
3. **Phase 3**: クロスパッケージ + メソッドチェーン + LSP 統合
4. **Phase 4**: EffectChecker のメソッド対応

**影響ファイル**: 設計指示書の「影響範囲」セクション参照。

**テスト計画**: 設計指示書の「テスト計画」セクション参照。新規テストファイル `t/static/07_method_typecheck.t` を作成。

---

## Phase B: 型検査の深化

### B-1: ジェネリック関数の静的型チェック

**優先度**: 高 — 現在ジェネリック関数呼び出しは型チェックが完全にスキップされている

**背景**:
`TypeChecker.pm:96` で `generics` が非空の関数は一律スキップ。ジェネリクスを多用するコードでは静的検査がほぼ無効化される。

**目標**:
呼出し側の引数から型変数を instantiate し、具象型でチェックする。

```perl
sub first :Type(<T>(ArrayRef[T]) -> T) ($arr) { $arr->[0] }

first([1, 2, 3]);     # T := Int, OK
first("not array");   # Error: expected ArrayRef[T], got Str
```

**影響ファイル**:
- `lib/Typist/Static/TypeChecker.pm` — ジェネリックスキップの代わりに instantiation ロジック
- `lib/Typist/Static/Infer.pm` — 引数型推論（既存 API）
- `lib/Typist/Inference.pm` — `instantiate` + `_unify` ロジック参考

**実装指針**:

```
1. 引数の型を推論: [infer_expr(arg1), infer_expr(arg2), ...]
2. 推論不能な引数がある場合は全体をスキップ（gradual fallback）
3. パラメータ型と引数型をペアにして型変数を束縛:
   unify(ArrayRef[T], ArrayRef[Int]) → { T => Int }
4. 束縛を使ってパラメータ型を具象化:
   substitute(ArrayRef[T], { T => Int }) → ArrayRef[Int]
5. 具象化されたパラメータ型と引数型のサブタイプチェック
6. 有界量化チェック: T: Num なら is_subtype(Int, Num)
```

**新規モジュール**: `Typist::Static::Unify` を新設する可能性あり。ランタイムの `Inference->instantiate` は値ベースだが、静的パスでは型ベースの unification が必要。

**設計選択**:
- 完全な Hindley-Milner 推論は不要。呼出しサイトでの forward-only instantiation で十分
- 型変数が束縛できない場合（推論不能な引数）はスキップ
- `contains` ではなく `Subtype->is_subtype` で検査

**テスト計画**:
- `t/static/03_typecheck.t`:
  - `first([1,2,3])` → OK (T := Int)
  - `first("str")` → TypeMismatch
  - `first($unknown_var)` → スキップ（推論不能）
  - bounded: `max_of(1, 2)` → OK, `max_of("a", "b")` → TypeMismatch (T: Num)
  - 複数型変数: `pair(1, "a")` → T := Int, U := Str

---

### B-2: 制御フロー型（Type Narrowing）

**優先度**: 中高 — TypeScript の最大の強みに相当する機能

**背景**:
`if (defined $x)` や `if (ref $x eq 'ARRAY')` の後で型が narrow されない。`Maybe[Str]` は if ブロック内でも `Str | Undef` のまま。

**目標**:
```perl
my $x :Type(Maybe[Str]) = get_name();
if (defined $x) {
    # ここでは $x: Str
    greet($x);     # OK: Str accepted
}
# ここでは $x: Str | Undef のまま
```

**影響ファイル**:
- `lib/Typist/Static/TypeChecker.pm` — `_env_for_node` にナローイングロジック追加
- `lib/Typist/Static/Infer.pm` — ナローイングされた環境での推論

**実装指針**:

これは大規模な変更。段階的に実装:

**Phase B-2a: `defined($x)` ナローイング**

```perl
# _env_for_node 内で、ノードの親チェーンを走査
# if (defined $x) { ... } パターンを検出
#
# PPI 構造:
#   Statement::Compound
#     Token::Word 'if'
#     Structure::Condition
#       Statement::Expression
#         Token::Word 'defined'
#         Structure::List
#           Token::Symbol '$x'
#     Block { ... }  ← この中のノードで env を narrow

sub _narrow_env ($self, $env, $node) {
    my $compound = _find_enclosing_compound($node) // return $env;
    my $condition = _extract_condition($compound) // return $env;

    # defined($x) パターン
    if (_is_defined_check($condition)) {
        my $var_name = _extract_defined_var($condition);
        my $var_type = $env->{variables}{$var_name} // return $env;

        # Union(T | Undef) → T
        if ($var_type->is_union) {
            my @non_undef = grep {
                !($_->is_atom && $_->name eq 'Undef')
            } $var_type->members;

            if (@non_undef < scalar $var_type->members) {
                my $narrowed = @non_undef == 1
                    ? $non_undef[0]
                    : Typist::Type::Union->new(@non_undef);
                my %new_vars = %{$env->{variables}};
                $new_vars{$var_name} = $narrowed;
                return { %$env, variables => \%new_vars };
            }
        }
    }

    $env;
}
```

**Phase B-2b: `ref($x)` ナローイング**

```perl
if (ref $x eq 'ARRAY') {
    # $x: ArrayRef[Any]
}
```

**Phase B-2c: Newtype ガード**

```perl
if (ref $x eq 'Typist::Newtype::UserId') {
    # $x: UserId
}
```

**テスト計画**:
- `t/static/03_typecheck.t`:
  - `Maybe[Str]` が `defined` 後に `Str` になる
  - if ブロック外では元の型のまま
  - ネストした if の扱い

---

### B-3: 暗黙戻り値の分岐解析

**優先度**: 中

**背景**:
`_check_return_types` は if/while/for (`PPI::Statement::Compound`) の最終文をスキップする。分岐ごとの戻り値型が未検査。

**目標**:
```perl
sub classify :Type((Int) -> Str) ($n) {
    if ($n > 0) {
        return "positive";
    } else {
        return 42;       # TypeMismatch: expected Str, got 42
    }
}
```

**影響ファイル**:
- `lib/Typist/Static/TypeChecker.pm` — `_check_return_types` の分岐走査

**実装指針**:

`PPI::Statement::Compound` の子ブロックを再帰的に走査し、各ブロック内の `return` 文を検査する。

```perl
sub _collect_returns_from_block ($self, $block) {
    my @returns;

    my $stmts = $block->find('PPI::Statement') || [];
    for my $stmt (@$stmts) {
        # return 文
        my $first = $stmt->schild(0);
        if ($first && $first->isa('PPI::Token::Word') && $first->content eq 'return') {
            push @returns, $first->snext_sibling;
            next;
        }

        # ネストした Compound (if/elsif/else)
        if ($stmt->isa('PPI::Statement::Compound')) {
            my @blocks = $stmt->find('PPI::Structure::Block') || [];
            for my $inner_block (@blocks) {
                push @returns, $self->_collect_returns_from_block($inner_block);
            }
        }
    }

    @returns;
}
```

**テスト計画**:
- if/else 両方の return を検査
- if のみ（else なし）は暗黙戻り値との Union
- ネストした if/elsif/else

---

## Phase C: 型システムの表現力拡張

### C-1: 代数的データ型（Tagged Union / ADT）

**優先度**: 高 — Union 型の型安全性に大きく影響

**背景**:
現在の Union 型にはタグがなく、パターンマッチで安全に分岐できない。`Shape = Circle(Int) | Rectangle(Int, Int)` のようなタグ付き Union が必要。

**目標**:
```perl
BEGIN {
    datatype Shape =>
        Circle    => '(Int)',
        Rectangle => '(Int, Int)';
}

my $s = Circle(5);
# $s は Shape 型

# パターンマッチ (将来)
# match $s {
#     Circle($r)       => 3.14 * $r * $r,
#     Rectangle($w,$h) => $w * $h,
# }
```

**影響ファイル**:
- `lib/Typist.pm` — `datatype` キーワードのエクスポート
- `lib/Typist/Type/` — 新規 `Data.pm`（タグ付き Union ノード）
- `lib/Typist/Parser.pm` — datatype 式のパース
- `lib/Typist/Subtype.pm` — Data 型のサブタイピング規則
- `lib/Typist/Registry.pm` — datatype 登録
- `lib/Typist/Static/Extractor.pm` — datatype 文の抽出

**実装指針**:

**新規 Type ノード: `Type::Data`**

```perl
package Typist::Type::Data;
use v5.40;
use parent 'Typist::Type';

sub new ($class, $name, $variants) {
    # $variants: { Circle => [Atom(Int)], Rectangle => [Atom(Int), Atom(Int)] }
    bless +{ name => $name, variants => $variants }, $class;
}

sub name ($self) { $self->{name} }
sub variants ($self) { $self->{variants} }
sub is_data ($self) { 1 }

sub to_string ($self) {
    my @parts;
    for my $tag (sort keys $self->{variants}->%*) {
        my @types = $self->{variants}{$tag}->@*;
        push @parts, @types
            ? "$tag(" . join(', ', map { $_->to_string } @types) . ")"
            : $tag;
    }
    join ' | ', @parts;
}

sub contains ($self, $value) {
    # blessed ref with tag check
    return 0 unless ref $value && ref($value) =~ /\ATypist::Data::/;
    my $tag = $value->{_tag};
    exists $self->{variants}{$tag};
}
```

**コンストラクタの生成**:

```perl
# Typist.pm の _datatype:
sub _datatype ($name, %variants) {
    my $caller = caller;
    my %parsed_variants;

    for my $tag (keys %variants) {
        my @types = map { Typist::Type->coerce($_) } @{$variants{$tag}};
        $parsed_variants{$tag} = \@types;

        # Install constructor: Circle(5) → { _tag => 'Circle', _values => [5] }
        no strict 'refs';
        *{"${caller}::${tag}"} = sub (@args) {
            die "..." unless @args == @types;
            for my $i (0 .. $#types) {
                die "..." unless $types[$i]->contains($args[$i]);
            }
            bless +{ _tag => $tag, _values => \@args }, "Typist::Data::${name}";
        };
    }

    my $data_type = Typist::Type::Data->new($name, \%parsed_variants);
    Typist::Registry->define_alias($name, $data_type);
}
```

**サブタイピング**:
- `Data(Shape) <: Data(Shape)` — 名前的等価のみ（newtype と同じ方針）
- 各コンストラクタの戻り値型は `Data(Shape)`

**テスト計画**:
- `t/21_datatype.t` 新規作成
- コンストラクタ生成、contains、subtype、to_string
- 静的チェック: `Circle(5)` の戻り値型が `Shape` であること
- 不正な引数: `Circle("five")` → die

---

### C-2: エフェクトハンドラ

**優先度**: 中 — エフェクトシステムの実用性を大幅に向上

**背景**:
現在のエフェクトシステムは「追跡のみ」。`handle` 構文がなく、エフェクトの実行方法を定義できない。

**目標**:
```perl
# エフェクトの定義
BEGIN {
    effect State => +{
        get => Func(returns => Int),
        put => Func(Int, returns => Void),
    };
}

# エフェクトの使用
sub counter :Type(() -> Int !Eff(State)) () {
    my $n = perform State::get();
    perform State::put($n + 1);
    $n;
}

# エフェクトの処理
my $result = handle {
    counter();
} State => +{
    get => sub ($resume) { $resume->($state) },
    put => sub ($resume, $n) { $state = $n; $resume->(undef) },
};
```

**これは最も大規模な変更**。段階的に実装:

**Phase C-2a: `perform` キーワード**

`perform Effect::operation(args)` を導入。compile time ではエフェクト使用の記録に、runtime では（ハンドラなしの場合）直接実行に使う。

**Phase C-2b: `handle` ブロック**

`handle { body } Effect => { handlers }` 構文。最初はシンプルな動的ディスパッチとして実装（continuation なし）。

**Phase C-2c: Continuation (Delimited)**

`handle` ハンドラに `$resume` コールバックを渡し、delimited continuation を実現。Perl での実装は `Coro` やクロージャベースのアプローチを検討。

**影響ファイル**: 多数。新規モジュール `Typist::Handler.pm` を中心に、Parser、Registry、Attribute、Static 全般。

**注意**: この変更は C-2a → C-2b → C-2c の順で小さく切り出して進めること。

---

### C-3: HKT の完全化

**優先度**: 中

**背景**:
型コンストラクタ変数（`F: * -> *`）は型クラスで宣言できるが、関数シグネチャで自由に使えない。

**目標**:
```perl
sub lift :Type(<F: * -> *, T>(T) -> F[T]) ($x) { ... }
```

**影響ファイル**:
- `lib/Typist/Parser.pm` — `F[T]` の型適用パース（型変数 + 型引数の組み合わせ）
- `lib/Typist/KindChecker.pm` — 型変数のカインド検査
- `lib/Typist/Transform.pm` — 型コンストラクタ変数の置換

**実装指針**:

Parser に型変数適用 `F[T]` のパースを追加:

```perl
# Parser._resolve_name:
# 大文字1文字 + '[' の場合: Var 適用
if ($name =~ /\A[A-Z]\z/ && $tokens->[$pos] && $tokens->[$pos] eq '[') {
    my $var = Typist::Type::Var->new($name);
    my @params = $self->_parse_param_list($tokens, $pos, ']');
    return Typist::Type::Param->new($var, @params);  # Param with Var base
}
```

KindChecker で `Param(Var(F), [Atom(Int)])` のカインド検査:
- `F: * -> *` の場合、`F[Int]` は `* -> *` に `*` を適用 → 結果 `*`

---

### C-4: 多引数型クラス

**優先度**: 低

**背景**:
現在の型クラスは単一型変数のみ。`Convertible T U` のような多引数型クラスは非対応。

**目標**:
```perl
BEGIN {
    typeclass Convertible => 'T, U', +{
        convert => Func(T, returns => U),
    };

    instance Convertible => 'Int, Str', +{
        convert => sub ($x) { "$x" },
    };
}
```

**影響ファイル**:
- `lib/Typist/TypeClass.pm` — 複数型変数の解析、instance resolution の多引数対応
- `lib/Typist/Attribute.pm` — `parse_generic_decl` の拡張
- `lib/Typist/Inference.pm` — 多引数 dispatch

---

## Phase D: ランタイム最適化

### D-1: bounded generic の bound パースキャッシュ

**優先度**: 高（runtime mode 使用時）

**背景**:
`Attribute._wrap_sub` 内で、ジェネリック関数の bound 式が毎回 `Parser->parse($g->{bound_expr})` でパースされる（`Attribute.pm:203`付近）。キャッシュされていない。

**目標**:
bound 式のパース結果を1回だけキャッシュし、以降は再利用する。

**影響ファイル**:
- `lib/Typist/Attribute.pm` — `_wrap_sub` のクロージャ生成部分

**実装指針**:

```perl
# _wrap_sub 内、ラッパークロージャ生成の前でパースをキャッシュ:
my @cached_bounds;
for my $g (@generics) {
    if ($g->{bound_expr}) {
        push @cached_bounds, {
            name  => $g->{name},
            bound => Typist::Parser->parse($g->{bound_expr}),
        };
    }
}

# ラッパー内では $cached_bounds を参照:
# 変更前: my $bound = Typist::Parser->parse($g->{bound_expr});
# 変更後: my $bound = $cached_bounds[$i]{bound};
```

**テスト計画**:
- `t/11_bounded.t` が既存テストとして通ることを確認
- パフォーマンステスト: bounded generic 関数を1000回呼出し、キャッシュ有無で比較

---

### D-2: ラッパーのコンテキスト修正

**優先度**: 高（runtime mode 使用時）— 機能バグ

**背景**:
`Attribute.pm:245` で `my @result = $original->(@args)` と常にリストコンテキストで呼出す。コンテキスト依存の関数で挙動が変わる。

**目標**:
呼出し元のコンテキストを正しく伝播する。

**影響ファイル**:
- `lib/Typist/Attribute.pm` — `_wrap_sub` のラッパークロージャ

**実装指針**:

```perl
# 変更前:
my @result = $original->(@args);

# 変更後:
my @result;
if (wantarray) {
    @result = $original->(@args);
} elsif (defined wantarray) {
    $result[0] = $original->(@args);
} else {
    $original->(@args);
    return;
}
```

**テスト計画**:
- `t/03_attribute.t` に追加:
  - スカラーコンテキストでの呼出し
  - リストコンテキストでの呼出し
  - void コンテキストでの呼出し
  - `wantarray` に依存する関数のラップ

---

### D-3: Registry variables リーク修正

**優先度**: 中

**背景**:
`Registry.variables` は `"$ref"` (アドレスの文字列化) をキーとする。スコープ外になった変数のエントリが永続する。

**目標**:
スコープ外の変数エントリを自動クリーンアップする。

**影響ファイル**:
- `lib/Typist/Registry.pm`

**実装指針**:

選択肢:
1. **WeakRef**: `Scalar::Util::weaken` で参照を弱参照化し、GC 後に undef になったエントリを定期削除
2. **Explicit delete**: `Tie::Scalar::DESTROY` で Registry からエントリ削除
3. **Scope guard**: 変数の tie 時に scope guard を設定し、スコープ終了時に削除

最も堅実なのはオプション 2:

```perl
# Tie::Scalar に DESTROY を追加:
sub DESTROY ($self) {
    Typist::Registry->_unregister_variable($self->{ref_key});
}

# Registry に _unregister_variable を追加:
sub _unregister_variable ($invocant, $key) {
    my $self = ref $invocant ? $invocant : $invocant->_default;
    delete $self->{variables}{$key};
}
```

**テスト計画**:
- `t/06_instance.t` に追加: スコープ外後の Registry 状態確認

---

### D-4: unwrap 正規表現の事前コンパイル

**優先度**: 低（マイクロ最適化）

**背景**:
`Typist.pm:77` で `ref($value) =~ /\ATypist::Newtype::/` が毎回コンパイルされる。

**目標**:
```perl
# 変更前:
ref($value) =~ /\ATypist::Newtype::/

# 変更後:
my $NEWTYPE_RE = qr/\ATypist::Newtype::/;
# ...
ref($value) =~ $NEWTYPE_RE
```

**影響ファイル**:
- `lib/Typist.pm` — `_unwrap` 関数

---

## Phase E: アーキテクチャ整理

### E-1: Inference.pm の静的パスへの統合

**優先度**: 中

**背景**:
`Typist::Inference` は runtime mode 用の値ベース型推論。`Static::Infer` は PPI ベースの静的型推論。両者は異なるアプローチだが、`common_super`（LUB）や unification の概念は共通。

**目標**:
- `Inference.pm` の `instantiate` + `_unify` ロジックを `Static::Unify` として静的パスに移植
- ランタイム用の `Inference.pm` はそのまま維持（値ベース推論は静的パスでは使えない）
- `Subtype.pm` の `common_super` を両パスで共用（既にそうなっている）

**実装指針**:

```
新規: lib/Typist/Static/Unify.pm
  |
  +-> unify($formal_type, $actual_type) → { VarName => Type } | undef
  +-> instantiate_call($sig, @arg_types) → { bindings, concrete_params, concrete_return }
  |
  参考: Inference.pm の _unify ロジックを型ベースに書き換え
  - 値の infer_value → 型オブジェクトの直接比較
  - common_super → Subtype.common_super（既存）
```

B-1（ジェネリック静的チェック）の前提となるため、B-1 と一緒に実装するのが効率的。

---

### E-2: ビルトイン関数のプレリュード化

**優先度**: 中

**背景**:
Perl ビルトイン関数（say, print, die, length, push, etc.）はデフォルトで unannotated 扱い。`declare` で個別に注釈する必要がある。

**目標**:
よく使うビルトインの型注釈をプレリュードとして標準提供する。

**影響ファイル**:
- 新規: `lib/Typist/Prelude.pm` — ビルトイン関数の型定義集
- `lib/Typist.pm` — import 時にプレリュードを自動ロード

**実装指針**:

```perl
package Typist::Prelude;
use v5.40;

my %BUILTINS = (
    # IO effects
    say     => '(Any) -> Bool !Eff(IO)',
    print   => '(Any) -> Bool !Eff(IO)',
    warn    => '(Any) -> Bool !Eff(IO)',
    die     => '(Any) -> Never !Eff(Exn)',

    # Pure string operations
    length  => '(Str) -> Int',
    substr  => '(Str, Int, Int) -> Str',
    uc      => '(Str) -> Str',
    lc      => '(Str) -> Str',
    index   => '(Str, Str) -> Int',

    # Pure numeric operations
    abs     => '(Num) -> Num',
    int     => '(Num) -> Int',
    sqrt    => '(Num) -> Num',

    # Pure list operations
    scalar  => '(Any) -> Int',
    reverse => '(Any) -> Any',
    sort    => '(Any) -> Any',

    # IO operations
    open    => '(Any, Any) -> Bool !Eff(IO)',
    close   => '(Any) -> Bool !Eff(IO)',
    read    => '(Any, Any, Int) -> Int !Eff(IO)',
    chomp   => '(Any) -> Int',
    chop    => '(Any) -> Str',
);

sub install ($class, $registry) {
    for my $name (keys %BUILTINS) {
        my $ann = Typist::Parser->parse_annotation($BUILTINS{$name});
        my $type = $ann->{type};
        my (@params, $returns, $effects);
        if ($type->is_func) {
            @params = $type->params;
            $returns = $type->returns;
            $effects = $type->effects
                ? Typist::Type::Eff->new($type->effects) : undef;
        }
        $registry->register_function('CORE', $name, +{
            params  => \@params,
            returns => $returns,
            effects => $effects,
        });
    }
}

1;
```

**テスト計画**:
- `t/static/04_effects.t` に追加: プレリュード適用後、`say` 呼出しが `Eff(IO)` として正しく検出される

**注意**:
- ユーザが `declare` で上書きした場合はユーザ定義を優先
- `Eff(IO)` や `Eff(Exn)` などの標準エフェクトも定義する必要がある
- オプトアウト: `use Typist -no_prelude` で無効化

---

### E-3: 診断のソースマップ精度向上

**優先度**: 中

**背景**:
`Analyzer._to_diagnostics` は正規表現マッチングでエラーメッセージからシンボル名を抽出し、行番号を逆引きする。一部の診断は正確な位置を持たない。

**目標**:
全ての診断が正確な行番号・列番号を持つようにする。

**影響ファイル**:
- `lib/Typist/Static/TypeChecker.pm` — `collect` 呼出し時に PPI ノードから直接 `line_number` を取得（既に大部分で実施済み）
- `lib/Typist/Static/EffectChecker.pm` — 同上
- `lib/Typist/Static/Checker.pm` — 構造チェックの診断に行番号追加
- `lib/Typist/Static/Analyzer.pm` — `_to_diagnostics` の正規表現フォールバック削減

**実装指針**:
- Checker の `_check_functions` で、各関数の行番号を `extracted.functions{name}.line` から引いて collect に渡す
- Checker の `_check_aliases` で、typedef 行番号を `extracted.typedefs{name}.line` から引く
- 最終的に `_to_diagnostics` の正規表現マッチングを最小限に減らす

---

## 実装順序の推奨

```
Phase 1 (基盤 — 即座に着手):
  D-1: bound パースキャッシュ        (小規模、即効果)
  D-2: コンテキスト修正              (バグ修正、小規模)
  D-4: unwrap 正規表現               (1行変更)
  A-1: アリティ検査                   (小規模、高効果)

Phase 2 (検出力 — 基盤の上に構築):
  A-2a: 算術演算の推論               (中規模)
  A-3: 変数再代入追跡                (中規模)
  A-4: メソッド型チェック Phase 1    (設計書あり)

Phase 3 (深化 — 推論基盤を前提):
  A-2b: 添字アクセスの推論           (中規模)
  A-2c: 三項演算子の推論             (小規模)
  E-1: Static::Unify 新設            (B-1 の前提)
  B-1: ジェネリック静的チェック      (大規模)
  A-4: メソッド型チェック Phase 2-3  (中規模)

Phase 4 (表現力 — 独立して着手可能):
  E-2: ビルトインプレリュード        (中規模、効果テスト容易)
  B-3: 分岐戻り値解析               (中規模)
  D-3: Registry リーク修正          (小規模)
  E-3: ソースマップ精度             (中規模)

Phase 5 (高度な拡張 — 長期目標):
  B-2: Type Narrowing                (大規模)
  C-1: ADT / Tagged Union            (大規模)
  C-3: HKT 完全化                   (中規模)
  C-4: 多引数型クラス               (中規模)
  C-2: エフェクトハンドラ            (最大規模)
```

---

## エージェントへの指示テンプレート

各タスクを別のエージェントに渡す場合、以下のテンプレートを使用:

```
## タスク: [タスクID] [タスク名]

### コンテキスト
- プロジェクト: Typist — Perl 5.40+ 用の純 Perl 型システム
- アーキテクチャ: docs/architecture.md を参照
- 型システム: docs/type-system.md を参照
- 静的解析: docs/static-analysis.md を参照
- コーディング規約: CLAUDE.md を参照

### 目標
[このセクションの「目標」をコピー]

### 影響ファイル
[このセクションの「影響ファイル」をコピー]

### 実装指針
[このセクションの「実装指針」をコピー]

### テスト計画
[このセクションの「テスト計画」をコピー]

### テスト実行
carton exec -- prove -l t/ t/static/ t/lsp/
全テスト（42ファイル）が通ることを確認してからコミットすること。

### 制約
- use v5.40 とサブルーチンシグネチャを使用
- 型ノードは不変オブジェクト（substitute は新ノードを返す）
- hashref リテラルは +{} で記述
- gradual typing: Any ガードを忘れずに
- source filter や外部プリプロセッサは使用禁止
```
