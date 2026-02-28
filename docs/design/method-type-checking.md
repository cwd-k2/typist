# メソッド呼び出しの型付け — 設計指示書

## 背景

現在 Typist の静的解析は `func()` と `Pkg::func()` の型チェックに対応しているが、
`$obj->method()` や `Class->method()` 形式のメソッド呼び出しは型チェックされない。

- **EffectChecker**: `->` を検出して明示的にスキップ (EffectChecker.pm:110-112)
- **TypeChecker**: ガードなし。ローカル関数と名前衝突すれば誤検出の可能性
- **Infer**: `Word + List` パターンでマッチするが、`_infer_call` はメソッドを解決できない

## ゴール

`->` によるメソッド呼び出しに対して、以下を実現する:

1. **receiver の型推論** — `$obj` の型を環境から解決する
2. **メソッドシグネチャの解決** — receiver の型に基づきメソッドの引数型・戻り値型を取得する
3. **引数の型チェック** — 既存の関数呼び出しチェックと同等の検証
4. **戻り値の型推論** — メソッド呼び出し式の型をチェーンやネストで利用可能にする
5. **エフェクトチェック** — メソッドのエフェクト宣言を含めた検証

## 設計方針

### 段階的に導入する

```
Phase 1: 防御的修正 + メソッド抽出基盤
Phase 2: 同一パッケージ内のメソッド型チェック
Phase 3: クロスパッケージ・メソッドチェーン対応
Phase 4: エフェクトチェック統合
```

---

## Phase 1: 防御的修正 + メソッド抽出基盤

### 1-A. TypeChecker に `->` ガードを追加

**ファイル**: `lib/Typist/Static/TypeChecker.pm`

`_check_call_sites` で `->` の後ろの Word をスキップする。
EffectChecker と同じパターン:

```perl
# _check_call_sites 内、line 63 の直後
my $prev = $word->sprevious_sibling;
next if $prev && ref $prev && $prev->isa('PPI::Token::Operator') && $prev->content eq '->';
```

これにより、ローカル関数名との衝突による誤検出を防ぐ。

### 1-B. Extractor でメソッドを識別・抽出する

**ファイル**: `lib/Typist/Static/Extractor.pm`

`_extract_functions` でメソッドを関数と区別する。
判定基準: **第一引数が `$self` または `$class`** であること。

```perl
# 抽出結果に is_method フラグを追加
$result->{functions}{$name} = +{
    ...existing fields...,
    is_method   => $is_method,    # $self/$class が第一引数
    method_kind => $method_kind,  # 'instance' | 'class' | undef
};
```

`params_expr` からは `$self`/`$class` に対応する型を**除外**する。
メソッドの型シグネチャは receiver を含まない (例: `(Int, Str) -> Bool`)。

**注意**: `:Type(...)` アノテーションでは `$self` の型を書かない設計とする。
ユーザは `sub greet($self, $name) :Type((Str) -> Str)` と書く — `$self` は暗黙的。

### 1-C. Registry にメソッド登録 API を追加

**ファイル**: `lib/Typist/Registry.pm`

関数とは別の名前空間でメソッドを管理する:

```perl
# 新規メソッド
sub register_method ($invocant, $pkg, $name, $sig) {
    my $self = _self($invocant);
    $self->{methods}{"${pkg}::${name}"} = $sig;
}

sub lookup_method ($invocant, $pkg, $name) {
    my $self = _self($invocant);
    $self->{methods}{"${pkg}::${name}"};
}
```

`$sig` は関数と同じ構造だが `$self` パラメータを含まない。

### 1-D. Analyzer / Workspace でメソッドを Registry に登録

**ファイル**: `lib/Typist/Static/Analyzer.pm`, `lib/Typist/LSP/Workspace.pm`

Extractor の結果から `is_method` が真のものを `register_method` で登録する。

---

## Phase 2: 同一パッケージ内のメソッド型チェック

### 2-A. Receiver の型推論

**ファイル**: `lib/Typist/Static/Infer.pm`

PPI で `$obj->method(args)` を検出した場合:

```
Symbol($obj) → Operator(->) → Word(method) → List(args)
```

1. `$obj` の型を `$env->{variables}` から引く
2. 型がパッケージ名に対応するか判定する

**Receiver 型の解決ルール**:

| receiver の型 | 解決先パッケージ |
|---|---|
| `Alias` (typedef Name => ...) | Registry で `Name` のパッケージを検索 |
| `Newtype` (newtype UserId => ...) | `UserId` の定義パッケージ |
| `Atom` (パッケージ名と同名) | そのパッケージ名 |
| `Struct`, リテラル型 | メソッド解決不可 (skip) |
| 推論不能 / `Any` | skip (gradual typing) |

新しい関数を `Infer.pm` に追加:

```perl
sub infer_method_call ($class, $operator_node, $env) {
    # $operator_node は PPI::Token::Operator '->'
    my $receiver_node = $operator_node->sprevious_sibling // return undef;
    my $method_word   = $operator_node->snext_sibling     // return undef;

    return undef unless $method_word->isa('PPI::Token::Word');

    # receiver 型の推論
    my $receiver_type = $class->infer_expr($receiver_node, $env);
    return undef unless defined $receiver_type;
    return undef if $receiver_type->is_atom && $receiver_type->name eq 'Any';

    # パッケージ名の解決
    my $pkg = _resolve_receiver_package($receiver_type, $env);
    return undef unless $pkg;

    # メソッドシグネチャの検索
    my $method_name = $method_word->content;
    my $sig = $env->{registry}->lookup_method($pkg, $method_name);
    return undef unless $sig;

    # 戻り値型を返す
    $sig->{returns};
}
```

### 2-B. TypeChecker にメソッド呼び出しチェックを追加

**ファイル**: `lib/Typist/Static/TypeChecker.pm`

`analyze()` に `_check_method_calls` を追加:

```perl
sub analyze ($self) {
    $self->{env} = $self->_build_env;
    $self->_check_variable_initializers;
    $self->_check_call_sites;
    $self->_check_method_calls;      # NEW
    $self->_check_return_types;
}
```

`_check_method_calls` の処理:

```perl
sub _check_method_calls ($self) {
    my $ppi_doc = $self->{ppi_doc} // return;
    my $arrows = $ppi_doc->find('PPI::Token::Operator') || [];

    for my $arrow (@$arrows) {
        next unless $arrow->content eq '->';

        my $receiver_node = $arrow->sprevious_sibling // next;
        my $method_word   = $arrow->snext_sibling     // next;
        next unless $method_word->isa('PPI::Token::Word');

        # メソッドの次が List であること (呼び出し形式)
        my $arg_list = $method_word->snext_sibling // next;
        next unless $arg_list->isa('PPI::Structure::List');

        # receiver の型を推論
        my $env = $self->_env_for_node($arrow);
        my $receiver_type = Typist::Static::Infer->infer_expr($receiver_node, $env);
        next unless defined $receiver_type;
        next if $receiver_type->is_atom && $receiver_type->name eq 'Any';

        # パッケージ解決
        my $pkg = $self->_resolve_receiver_package($receiver_type);
        next unless $pkg;

        # メソッドシグネチャ検索
        my $method_name = $method_word->content;
        my $sig = $self->{registry}->lookup_method($pkg, $method_name);
        next unless $sig;

        # 引数チェック (既存の関数チェックと同等のロジック)
        next if $sig->{generics} && $sig->{generics}->@*;

        my @param_exprs = ($sig->{params} // [])->@*;
        next unless @param_exprs;

        my @args = $self->_extract_args($arg_list);
        my $n = @param_exprs < @args ? @param_exprs : @args;

        for my $i (0 .. $n - 1) {
            my $inferred = Typist::Static::Infer->infer_expr($args[$i], $env);
            next unless defined $inferred;
            next if $inferred->is_atom && $inferred->name eq 'Any';

            my $declared = $self->_resolve_type($param_exprs[$i]->to_string);
            next unless defined $declared;
            next if $self->_has_type_var($declared);

            unless (Typist::Subtype->is_subtype($inferred, $declared)) {
                my $fqn = "${pkg}->${method_name}";
                $self->{errors}->collect(
                    kind    => 'TypeMismatch',
                    message => "Argument " . ($i + 1) . " of ${fqn}(): expected ${\$declared->to_string}, got ${\$inferred->to_string}",
                    file    => $self->{file},
                    line    => $method_word->line_number,
                );
            }
        }
    }
}
```

### 2-C. `_resolve_receiver_package` ヘルパー

TypeChecker と Infer の共通ロジック。置き場所は要検討だが、
最初は TypeChecker の private メソッドとして実装し、必要に応じて切り出す。

```perl
sub _resolve_receiver_package ($self, $type) {
    # Newtype → 定義パッケージ
    if ($type->is_newtype) {
        return $type->name;  # e.g. "UserId"
    }

    # Alias → resolve してから再帰
    if ($type->is_alias) {
        my $resolved = $self->{registry}->lookup_type($type->alias_name);
        return $self->_resolve_receiver_package($resolved) if $resolved;
    }

    # Atom で登録済みパッケージ → そのパッケージ
    if ($type->is_atom) {
        my $name = $type->name;
        return $name if $self->{registry}->has_package($name);
    }

    undef;
}
```

**Registry に `has_package` を追加**:
```perl
sub has_package ($invocant, $pkg) {
    my $self = _self($invocant);
    exists $self->{packages}{$pkg};
}
```

---

## Phase 3: クロスパッケージ・メソッドチェーン対応

### 3-A. Workspace でのメソッド登録

**ファイル**: `lib/Typist/LSP/Workspace.pm`

`_register_extracted` でメソッドを Registry に登録する。
Extractor が `is_method` フラグを付けた関数を `register_method` に回す:

```perl
for my $name (keys %{$extracted->{functions}}) {
    my $fn = $extracted->{functions}{$name};
    if ($fn->{is_method}) {
        $reg->register_method($pkg, $name, { ... });
    } else {
        $reg->register_function($pkg, $name, { ... });
    }
}
```

### 3-B. `Class->method()` 形式のサポート

receiver がリテラルのパッケージ名 (PPI::Token::Word) の場合:

```
Word(Class) → Operator(->) → Word(method) → List(...)
```

`_check_method_calls` で receiver が Word の場合も対応する:

```perl
if ($receiver_node->isa('PPI::Token::Word')) {
    # パッケージ名として直接解決
    my $pkg = $receiver_node->content;
    # class method として lookup
    $sig = $self->{registry}->lookup_method($pkg, $method_name);
}
```

### 3-C. メソッドチェーンの型推論

`$obj->method1()->method2()` の場合、`method1()` の戻り値型から
`method2` の receiver パッケージを解決する必要がある。

PPI 上は:

```
Symbol($obj) → ->  → Word(method1) → List() → -> → Word(method2) → List()
```

`_check_method_calls` で `->` を走査する際、receiver が単純な Symbol でない場合
(前に別の `->` チェーンがある場合)、再帰的に推論する:

```perl
# receiver が Word + List (関数呼び出し結果) の場合は infer_expr で推論
# receiver が -> チェーンの一部なら infer_method_call を再帰呼び出し
```

**実装の複雑さ**: PPI のツリー構造上、チェーンのネスト解析は非自明。
最初はチェーン深さ 1 のみ対応し、段階的に拡張する方針で良い。

### 3-D. Hover / Completion への統合

**ファイル**: `lib/Typist/LSP/Hover.pm`, `lib/Typist/LSP/Completion.pm`

- **Hover**: `$obj->method` 上でホバーしたとき、メソッドのシグネチャを表示
- **Completion**: `$obj->` の後に、receiver 型に基づくメソッド候補を提示

これらは Phase 3 以降の拡張とする。

---

## Phase 4: エフェクトチェック統合

### 4-A. EffectChecker のメソッド対応

**ファイル**: `lib/Typist/Static/EffectChecker.pm`

現在のスキップガード (line 110-112) を条件付きに変更する:

```perl
# メソッド呼び出し: ->name
my $prev = $word->sprevious_sibling;
if ($prev && ref $prev && $prev->isa('PPI::Token::Operator') && $prev->content eq '->') {
    # receiver の型推論 → パッケージ解決 → メソッドエフェクト取得
    my $receiver_node = $prev->sprevious_sibling // next;
    my $receiver_type = Typist::Static::Infer->infer_expr($receiver_node, ...);
    # ... エフェクトチェック ...
    next;  # 通常の関数チェックはスキップ
}
```

---

## テスト計画

### Phase 1 テスト

- `t/static/03_typecheck.t`: `->` ガード追加後、メソッド名とローカル関数名が衝突しても誤検出しないことを検証
- `t/static/00_extractor.t` (または新規): `is_method` フラグの抽出を検証

### Phase 2 テスト

新規: `t/static/07_method_typecheck.t`

```perl
# メソッド引数の型チェック
my $source = <<'PERL';
package Greeter;
use v5.40;
use Typist;

sub greet($self, $name) :Type((Str) -> Str) {
    return "Hello, $name";
}

package main;
use v5.40;
use Typist;

my $g :Type(Greeter) = Greeter->new;
$g->greet(42);  # TypeMismatch: expected Str, got 42
PERL
```

テストケース:
1. メソッド引数の型不一致 → TypeMismatch
2. メソッド引数の型一致 → エラーなし
3. 存在しないメソッド → skip (gradual typing)
4. receiver 型不明 → skip
5. `Class->method()` 形式
6. ジェネリックメソッド → skip (Phase 2 では対応しない)

### Phase 3 テスト

- クロスパッケージのメソッド呼び出し型チェック
- メソッドチェーン (`$obj->a()->b()`) の戻り値推論
- LSP ホバー・補完のメソッド対応

---

## 影響範囲

| モジュール | 変更内容 |
|---|---|
| `Static/TypeChecker.pm` | `->` ガード追加、`_check_method_calls` 新設 |
| `Static/Infer.pm` | `infer_method_call` 新設 |
| `Static/Extractor.pm` | `is_method`, `method_kind` 追加 |
| `Static/EffectChecker.pm` | メソッドスキップを条件付きに変更 |
| `Static/Analyzer.pm` | メソッド登録処理追加 |
| `Registry.pm` | `register_method`, `lookup_method`, `has_package` 追加 |
| `LSP/Workspace.pm` | メソッド登録処理追加 |
| `LSP/Hover.pm` | メソッドホバー対応 (Phase 3) |
| `LSP/Completion.pm` | メソッド補完対応 (Phase 3) |

## 設計上の判断ポイント

### 1. `$self` の暗黙除外

`:Type(...)` アノテーションのシグネチャには `$self` を含めない。
メソッドの型は「呼び出し側から見た型」として定義する。

```perl
# ユーザが書くコード
sub greet($self, $name) :Type((Str) -> Str) { ... }
# (Str) -> Str は $name: Str, 戻り値: Str を意味する
# $self は暗黙的に除外される
```

**理由**: receiver の型はパッケージから自明であり、冗長な記述を避ける。

### 2. メソッド vs 関数の判定基準

第一引数名 `$self` または `$class` の有無で判定する。
Perl には言語レベルのメソッド/関数区分がないため、慣習ベースの判定とする。

**限界**: `$self` を使わない非メソッドな関数も存在するが、
`:Type(...)` アノテーションがあれば `$self` 分のパラメータ数の不一致で検出可能。

### 3. Receiver 型の解決範囲

Phase 2 では以下に限定:
- 変数に `:Type(...)` で明示された型
- `my $x = ClassName->new(...)` パターンからの推論 (将来)

型推論できない receiver はスキップする (gradual typing の原則に従う)。

### 4. 既存の `register_function` との関係

メソッドと関数は **別の名前空間** で管理する。
同じパッケージに `sub foo` (関数) と `sub bar($self)` (メソッド) がある場合、
`foo` は `register_function`、`bar` は `register_method` に登録される。

`Pkg::foo()` は関数として、`$obj->bar()` はメソッドとして解決される。

### 5. constructor (`new`) の扱い

`Class->new(...)` は class method として扱う。
戻り値型が明示されていれば (`-> ClassName`)、それを使う。
なければ `Any` (gradual typing)。

将来的に `new` の戻り値型をパッケージ名から暗黙推論する拡張も可能。
