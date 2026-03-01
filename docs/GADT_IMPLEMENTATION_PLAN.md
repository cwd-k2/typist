# GADT (Generalized Algebraic Data Types) 実装計画書

> **Status: Implemented** — All phases completed and merged.
> This document is retained as a historical reference.

## 概要

Typist に GADT サポートを追加する。GADT は通常の ADT を一般化したもので、各コンストラクタが異なる型引数で具体化された戻り型を持つことができる。これにより、パターンマッチ時に型変数が精緻化（refinement）され、型安全なインタープリタや式木、型付き DSL の構築が可能になる。

### 通常 ADT と GADT の違い

```perl
# 通常の ADT — 全コンストラクタが同じ型 Option[T] を返す
datatype 'Option[T]' => Some => '(T)', None => '()';

# GADT — コンストラクタごとに戻り型の型引数を制約できる
datatype 'Expr[A]' =>
    IntLit  => '(Int) -> Expr[Int]',
    BoolLit => '(Bool) -> Expr[Bool]',
    Add     => '(Expr[Int], Expr[Int]) -> Expr[Int]',
    If      => '(Expr[Bool], Expr[A], Expr[A]) -> Expr[A]';
```

`match` で `IntLit` アームに入ると `A = Int` が判明し、型安全な操作が可能になる。

---

## 設計方針

### 構文

コンストラクタ仕様文字列に `->` を含めることで GADT コンストラクタを区別する:

```
通常 ADT:  Tag => '(Type, ...)'            # 引数型のみ
GADT:      Tag => '(Type, ...) -> ADT[X]'  # 引数型 + 戻り型
```

`->` の有無で自動判定する。一つの datatype 宣言内で通常コンストラクタと GADT コンストラクタを混在可能とする。`->` を持たないコンストラクタは暗黙的に最も一般的な戻り型（宣言の型パラメータをそのまま使う）を持つものとして扱う。

例:
```perl
datatype 'Expr[A]' =>
    IntLit  => '(Int) -> Expr[Int]',         # A=Int に制約
    BoolLit => '(Bool) -> Expr[Bool]',       # A=Bool に制約
    Add     => '(Expr[Int], Expr[Int]) -> Expr[Int]',
    If      => '(Expr[Bool], Expr[A], Expr[A]) -> Expr[A]',  # A は自由
    Var     => '(Str)';                       # 暗黙的に -> Expr[A]
```

### 原則

1. **後方互換**: 既存の `datatype`/`enum`/`match` コードは一切変更不要
2. **Static-first**: GADT 制約は主に静的解析（TypeChecker）で活用し、ランタイムは後回しにできる
3. **段階的実装**: 前提条件のバグ修正 → 型表現の拡張 → 静的解析 → ランタイム → LSP の順に進める
4. **最小侵襲**: 既存モジュールへの変更は最小限に抑え、新規ロジックは可能な限り独立した関数/メソッドに閉じ込める

---

## フェーズ 0: 前提条件（既存バグの修正）

GADT 実装の基盤として、既存の静的解析パイプラインにある以下の問題を先に修正する。

### 根本原因: DSL キーワードが生成する呼び出し可能エンティティの静的表現が欠落

Analyzer が関数として認識するのは `:Type(...)` アトリビュート付き `sub` と `declare` 文のみ。
以下の DSL キーワードがランタイムで名前空間にインストールする関数は、静的解析では**完全に不可視**:

| DSL キーワード | ランタイムで生成 | 静的解析での認識 |
|---------------|-----------------|-----------------|
| `datatype` | コンストラクタ関数（`Circle`, `Some` 等） | **不可視** — `Any` に推論 |
| `newtype` | コンストラクタ関数（`UserId` 等） | **不可視** — `Any` に推論 |
| `typeclass` | ディスパッチ関数（`Eq::eq` 等） | **不可視** — `Any` に推論 |
| `enum` | 定数関数（`Red`, `Green` 等） | **不可視** — `Any` に推論 |

加えて、`datatype` で宣言された型名（`Shape`, `Option` 等）自体も Analyzer の Registry に登録されないため、`:Type((Shape) -> Int)` で `UnknownType` エラーになる。

実際に検証した結果:

```
$ perl -Ilib -e '... Typist::Static::Analyzer->analyze(...)'

# 1. Shape が型として認識されない:
[UnknownType] L6: Type alias 'Shape' is not defined (in main::area)

# 2. Circle(5) の推論結果が Any（コンストラクタが関数登録されていないため）:
#    → my $c :Type(Int) = Circle(5) でも TypeMismatch が出ない

# 3. Eq::eq(Int, Str) でも TypeMismatch が出ない（typeclass メソッドが登録されていない）

# 4. UserId(42) を (Str)->Str に渡しても TypeMismatch が出ない

# 5. Analyzer の Registry に datatypes が空:
=== Registry datatypes ===
  (none)
=== Registry functions ===
  (constructors are not registered)
```

### 0-1. `Type::Fold::map_type` が `type_params` / `type_args` を喪失する

**ファイル**: `lib/Typist/Type/Fold.pm` 54-61 行目

**現状**: `map_type` で Data ノードを再構築する際に `type_params` と `type_args` を渡していない。
```perl
return $cb->(Typist::Type::Data->new($type->name, \%new_variants));
# ↑ type_params, type_args が欠落
```

**修正**:
```perl
return $cb->(Typist::Type::Data->new($type->name, \%new_variants,
    type_params => [$type->type_params],
    type_args   => [map { $class->map_type($_, $cb) } $type->type_args],
));
```

`walk` も `type_args` を走査するよう修正:
```perl
elsif ($type->is_data) {
    for my $types (values $type->variants->%*) {
        $class->walk($_, $cb) for @$types;
    }
    $class->walk($_, $cb) for $type->type_args;  # 追加
}
```

**テスト**: `t/19_fold.t` に Data ノードのパラメータ保存テストを追加。

### 0-2. Analyzer が現在ファイルの datatype を Registry に登録しない

**ファイル**: `lib/Typist/Static/Analyzer.pm` 41-258 行目

**現状**: `analyze()` はエイリアス、newtype、effect、typeclass、declare、function を Registry に登録するが、`extracted->{datatypes}` を登録するコードがない。Workspace 経由で他ファイルからマージされた datatype のみが見える。

**影響**:
- `Shape` が `:Type((Shape) -> Int)` の引数型として使えない（`UnknownType` エラー）
- `Registry->lookup_type('Shape')` が `undef` を返すため、TypeChecker の `_resolve_type` でも解決できない
- `Registry->has_alias('Shape')` も `false`（`has_alias` は `datatypes` をチェックするが、`datatypes` ハッシュが空なため）

**修正**: 2e（declares 登録）と 3（functions 登録）の間に以下を挿入:
```perl
# 2f. Register this file's datatypes
for my $name (sort keys(($extracted->{datatypes} // +{})->%*)) {
    my $info = $extracted->{datatypes}{$name};
    my %parsed_variants;
    for my $tag (keys $info->{variants}->%*) {
        my $spec = $info->{variants}{$tag};
        my @types;
        if (defined $spec && $spec =~ /\S/) {
            my $inner = $spec;
            $inner =~ s/\A\(\s*//;
            $inner =~ s/\s*\)\z//;
            @types = map { eval { Typist::Parser->parse($_) } }
                     split /\s*,\s*/, $inner;
            # Promote aliases matching type param names to Var objects
            my %vn = map { $_ => 1 } $info->{type_params}->@*;
            @types = map {
                $_->is_alias && $vn{$_->alias_name}
                    ? Typist::Type::Var->new($_->alias_name) : $_
            } @types if $info->{type_params}->@*;
        }
        $parsed_variants{$tag} = \@types;
    }
    my $dt = Typist::Type::Data->new($name, \%parsed_variants,
        type_params => $info->{type_params},
    );
    $registry->register_datatype($name, $dt);
}
```

**テスト**: 以下を検証:
- `Shape` が `:Type((Shape) -> Int)` で `UnknownType` にならない
- `Registry->lookup_type('Shape')` が `Data` オブジェクトを返す
- `Registry->has_alias('Shape')` が `true` を返す

### 0-3. Workspace が parameterized ADT の alias-to-Var promotion を行っていない

**ファイル**: `lib/Typist/LSP/Workspace.pm` 117-135 行目

**現状**: Workspace の `_register_file_types` は `Parser->parse` を呼ぶだけで、`Typist.pm` の `_datatype` にある alias→Var 昇格をしていない。結果、`Option[T]` の `Some` バリアントに `Alias('T')` が入り、`substitute` や subtype チェックが壊れる。

**修正**: Analyzer (0-2) と同じ alias→Var promotion ロジックを追加。`type_params` も `Data->new` に渡す:
```perl
my $info = $extracted->{datatypes}{$name};
my @tp = ($info->{type_params} // [])->@*;
my %vn = map { $_ => 1 } @tp;
# ... (variant パースループ内)
@types = map {
    $_->is_alias && $vn{$_->alias_name}
        ? Typist::Type::Var->new($_->alias_name) : $_
} @types if @tp;
# ...
my $type = Typist::Type::Data->new($name, \%parsed_variants,
    type_params => \@tp,
);
```

**テスト**: `t/lsp/06_workspace_crossfile.t` に parameterized ADT の cross-file テストを追加。

### 0-4. ADT コンストラクタが関数として Registry に登録されない【新規・最重要】

**ファイル**: `lib/Typist/Static/Analyzer.pm`

**現状**: `datatype Shape => Circle => '(Int)', Rect => '(Int, Int)'` を宣言しても、`Circle` や `Rect` は Analyzer の Registry に**関数として登録されない**。結果:

1. **`_infer_call('Circle', $env)`** → `env->{functions}` にない → `env->{known}` にない → `CORE` にもない → **`Any` を返す**（Infer.pm:122）
2. **`_check_call_sites`** → `extracted->{functions}` にない → Registry にもない → **スキップ**（TypeChecker.pm:156）
3. **`_check_variable_initializers`** → `Circle(5)` の推論が `Any` → **`Any` ガードでスキップ**（TypeChecker.pm:43）

つまり `my $c :Type(Int) = Circle(5)` でも **TypeMismatch が出ない**。

**修正**: フェーズ 0-2 の datatype 登録に続けて、各コンストラクタを関数として登録する:

```perl
# 0-2 の datatype 登録直後に追加:
# 2g. Register datatype constructors as functions
for my $name (sort keys(($extracted->{datatypes} // +{})->%*)) {
    my $info = $extracted->{datatypes}{$name};
    my @tp = ($info->{type_params} // [])->@*;

    for my $tag (keys $info->{variants}->%*) {
        my $spec = $info->{variants}{$tag};
        # コンストラクタの引数型を取得（0-2 で parsed した $parsed_variants を再利用）
        my $param_types = $parsed_variants{$tag};  # from 0-2 loop

        # 戻り型: Data 型名（非パラメトリックなら Alias、パラメトリックなら Param）
        my $return_type;
        if (@tp) {
            my @vars = map { Typist::Type::Var->new($_) } @tp;
            $return_type = Typist::Type::Param->new($name, @vars);
        } else {
            $return_type = Typist::Type::Atom->new($name);
            # ※ Atom ではなく Alias のほうが正しいかもしれない。
            # lookup_type で Data オブジェクトに解決されるため Alias が適切:
            $return_type = Typist::Type::Alias->new($name);
        }

        # ジェネリック宣言（パラメトリック ADT のみ）
        my @generics = map { +{ name => $_, bound_expr => undef } } @tp;

        $registry->register_function($extracted->{package}, $tag, +{
            params      => $param_types,
            returns     => $return_type,
            generics    => \@generics,
            params_expr => [map { $_->to_string } @$param_types],
            returns_expr => $return_type->to_string,
        });
    }
}
```

**これにより**:
- `_infer_call('Circle', $env)` → Registry から `Circle` の署名を取得 → 戻り型 `Shape` を返す
- `_check_call_sites` → `Circle(5)` の引数型チェックが有効になる（`Int` 期待に対して `Int` が渡されるか）
- `_check_variable_initializers` → `my $c :Type(Int) = Circle(5)` で `Shape <: Int` が偽 → **TypeMismatch 検出**
- parameterized ADT: `Some(42)` → Unify で `T=Int` → 戻り型 `Option[Int]`

**テスト**: `t/static/03_typecheck.t` に追加:
```perl
subtest 'datatype: constructor return type inferred as Data type' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
use Typist;
datatype Shape => Circle => '(Int)', Rect => '(Int, Int)';
sub take_int :Type((Int) -> Int) ($x) { $x }
my $r = take_int(Circle(5));
PERL
    my @errs = grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@*;
    ok @errs > 0, 'Shape is not subtype of Int';
    like $errs[0]{message}, qr/Shape/, 'mentions Shape in error';
};

subtest 'datatype: constructor arg type checked' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
use Typist;
datatype Shape => Circle => '(Int)', Rect => '(Int, Int)';
my $c = Circle("hello");
PERL
    my @errs = grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@*;
    ok @errs > 0, 'Str arg to Circle(Int) detected';
};

subtest 'datatype: Shape accepted where Shape expected' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
use Typist;
datatype Shape => Circle => '(Int)', Rect => '(Int, Int)';
sub area :Type((Shape) -> Int) ($s) { 42 }
my $r = area(Circle(5));
PERL
    my @errs = grep { $_->{kind} =~ /Mismatch/ } $result->{diagnostics}->@*;
    is scalar @errs, 0, 'no mismatch when Shape matches Shape';
};
```

**注意**: `_infer_call` のフロー（Infer.pm:90-123）でコンストラクタの戻り型を取得するためには、Registry の `lookup_function` が呼ばれる経路を確認する必要がある。現在の `_infer_call` は:
1. `env->{functions}{name}` → 戻り型（ローカル関数）
2. `env->{known}{name}` → `undef`（部分注釈）
3. `Pkg::func` → Registry
4. `CORE::name` → Registry
5. フォールバック → `Any`

コンストラクタは `main::Circle` として登録されるが、`_infer_call` は `Circle` （パッケージなし）で検索する。**ステップ 1 で見つけるには、`_build_env` で Registry のローカルパッケージ関数を `env->{functions}` に含める必要がある**。または、ステップ 4 の後に現在パッケージの Registry 検索を追加する:

```perl
# Infer.pm: _infer_call に追加（CORE fallback の後）
# Current-package function (e.g., ADT constructor registered by Analyzer)
if (my $registry = $env->{registry}) {
    my $pkg = $env->{package} // 'main';
    my $pkg_sig = $registry->lookup_function($pkg, $name);
    if ($pkg_sig && $pkg_sig->{returns}) {
        return $pkg_sig->{returns};
    }
}
```

**TypeChecker の `_check_call_sites` にも同様の修正が必要**（TypeChecker.pm:127-157）。現在は `extracted->{functions}` → cross-package → CORE の順で検索するが、コンストラクタは `extracted->{functions}` にも `CORE` にもない。現在パッケージの Registry を検索する分岐を追加:

```perl
# TypeChecker.pm: _check_call_sites に追加（CORE fallback の後）
unless ($cross_pkg) {
    my $pkg = $self->{extracted}{package} // 'main';
    my $pkg_sig = $self->{registry}->lookup_function($pkg, $name);
    if ($pkg_sig) {
        $cross_pkg = +{
            params_expr => $pkg_sig->{params_expr}
                // [map { $_->to_string } ($pkg_sig->{params} // [])->@*],
            generics    => $pkg_sig->{generics},
        };
    }
}
```

### 0-5. Typeclass メソッドが関数として Registry に登録されない

**ファイル**: `lib/Typist/Static/Analyzer.pm`, `lib/Typist/Static/Extractor.pm`

**現状**: `typeclass Eq => T => ( eq => '(T, T) -> Bool' )` を宣言しても:

1. **Extractor**: `()` 構文を使うと `method_names` が空配列になる（PPI が `PPI::Structure::List` を返すが、Extractor は `PPI::Structure::Constructor`（`+{}`）と `PPI::Structure::Block` しかチェックしない）
2. **Analyzer**: たとえ `method_names` が正しく抽出されても、メソッドのシグネチャを関数として Registry に登録するコードがない

結果:
- `Eq::eq(1, "hello")` で TypeMismatch が出ない
- `Eq::eq(1, 2)` の戻り型が `Any` に推論される（`Bool` ではない）

**修正**:

**Extractor** (Extractor.pm:277-293): `PPI::Structure::List` も対象に追加:
```perl
next unless $child->isa('PPI::Structure::Constructor')
         || $child->isa('PPI::Structure::Block')
         || $child->isa('PPI::Structure::List');   # 追加
```

**Extractor**: `method_names` だけでなく、メソッドのシグネチャ文字列も抽出する。Extractor の出力を拡張:
```perl
$result->{typeclasses}{$name} = +{
    var_spec     => $var_spec,
    method_names => \@method_names,
    methods      => \%method_sigs,     # 追加: { eq => '(T, T) -> Bool' }
    line         => $stmt->line_number,
    col          => $stmt->column_number,
};
```

メソッドシグネチャの抽出は、`Word => QuotedString` ペアから `Word` をキー、`QuotedString` の string を値として収集する。

**Analyzer**: typeclass 登録（2d）の後に、メソッドを関数として登録:
```perl
# 2d-b. Register typeclass methods as functions
for my $tc_name (sort keys $extracted->{typeclasses}->%*) {
    my $tc_info = $extracted->{typeclasses}{$tc_name};
    my $methods = $tc_info->{methods} // +{};
    my $var_spec = $tc_info->{var_spec} // 'T';
    # var_spec からジェネリック宣言を生成
    my @generics = ({ name => $var_spec, bound_expr => undef });

    for my $method_name (keys %$methods) {
        my $sig_str = $methods->{$method_name};
        my $ann = eval { Typist::Parser->parse_annotation($sig_str) };
        next unless $ann;
        my $type = $ann->{type};
        my (@params, $returns);
        if ($type->is_func) {
            @params  = $type->params;
            $returns = $type->returns;
        } else {
            $returns = $type;
        }
        $registry->register_function($tc_name, $method_name, +{
            params      => \@params,
            returns     => $returns,
            generics    => \@generics,
            params_expr => [map { $_->to_string } @params],
            returns_expr => $returns->to_string,
        });
    }
}
```

これにより `Eq::eq(1, "hello")` は cross-package パス（`Eq::eq` → `$registry->lookup_function('Eq', 'eq')`）で型チェックされる。

**テスト**: `t/static/03_typecheck.t` に追加:
```perl
subtest 'typeclass: method arg type checked' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
use Typist;
typeclass Eq => T => (
    eq => '(T, T) -> Bool',
);
sub check :Type(() -> Bool) () {
    Eq::eq(1, "hello");
}
PERL
    my @errs = grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@*;
    ok @errs > 0, 'type mismatch: Int vs Str for Eq::eq';
};
```

### 0-6. Newtype コンストラクタが関数として Registry に登録されない

**ファイル**: `lib/Typist/Static/Analyzer.pm`

**現状**: `newtype UserId => 'Int'` を宣言すると `UserId` は型として登録されるが、コンストラクタ関数 `UserId(42)` は登録されない。

結果:
- `UserId(42)` の推論が `Any`
- `my $id :Type(Str) = UserId(42)` で TypeMismatch が出ない

**修正**: 2b（newtypes 登録）の後に、newtype コンストラクタを関数として登録:
```perl
# 2b-b. Register newtype constructors as functions
for my $name (sort keys $extracted->{newtypes}->%*) {
    my $info = $extracted->{newtypes}{$name};
    my $inner = eval { Typist::Parser->parse($info->{inner_expr}) };
    next unless $inner;
    $registry->register_function($extracted->{package}, $name, +{
        params      => [$inner],
        returns     => Typist::Type::Newtype->new($name, $inner),
        generics    => [],
        params_expr => [$inner->to_string],
        returns_expr => $name,
    });
}
```

**テスト**:
```perl
subtest 'newtype: constructor return type is nominal' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
use Typist;
newtype UserId => 'Int';
sub take_str :Type((Str) -> Str) ($x) { $x }
my $r = take_str(UserId(42));
PERL
    my @errs = grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@*;
    ok @errs > 0, 'UserId is not Str';
};
```

---

## フェーズ 1: GADT 型表現の拡張

### 1-1. `Type::Data` にコンストラクタ別戻り型を格納する

**ファイル**: `lib/Typist/Type/Data.pm`

**変更**: `return_types` フィールドを追加。これはコンストラクタタグから戻り型（Data ノード）へのマッピング。

```perl
sub new ($class, $name, $variants, %opts) {
    bless +{
        name         => $name,
        variants     => $variants,
        type_params  => $opts{type_params} // [],
        type_args    => $opts{type_args}   // [],
        return_types => $opts{return_types} // +{},  # 追加: { Tag => Data[...] }
    }, $class;
}

sub return_types ($self) { $self->{return_types} }
sub is_gadt      ($self) { scalar keys $self->{return_types}->%* > 0 }

# コンストラクタ Tag の戻り型を取得。
# GADT 制約がなければ、宣言のジェネリックな Data 型を返す。
sub constructor_return_type ($self, $tag) {
    return $self->{return_types}{$tag} if exists $self->{return_types}{$tag};
    # デフォルト: Data[Var(P1), Var(P2), ...]
    my @params = map { Typist::Type::Var->new($_) } $self->{type_params}->@*;
    return __PACKAGE__->new($self->{name}, $self->{variants},
        type_params => [$self->{type_params}->@*],
        type_args   => \@params,
    );
}
```

`equals`, `substitute`, `to_string`, `free_vars` を `return_types` に対応させる:

- **`substitute`**: `return_types` の各値にも `substitute` を適用
- **`free_vars`**: `return_types` の値からも自由変数を収集
- **`equals`**: `return_types` の等価性も比較（深い比較）
- **`to_string_full`**: GADT バリアントは `Tag(Args) -> Data[X]` 形式で表示

`instantiate` にも `return_types` を引き継ぐ。

**テスト**: `t/21_datatype.t` に GADT 型表現の構築・アクセスのユニットテストを追加。

### 1-2. `Type::Fold` を GADT 対応にする

**ファイル**: `lib/Typist/Type/Fold.pm`

`map_type` の Data 分岐で `return_types` も走査・再構築する:
```perl
if ($type->is_data) {
    my %new_variants;
    for my $tag (keys $type->variants->%*) {
        $new_variants{$tag} = [
            map { $class->map_type($_, $cb) } $type->variants->{$tag}->@*
        ];
    }
    my %new_rt;
    for my $tag (keys $type->return_types->%*) {
        $new_rt{$tag} = $class->map_type($type->return_types->{$tag}, $cb);
    }
    return $cb->(Typist::Type::Data->new($type->name, \%new_variants,
        type_params  => [$type->type_params],
        type_args    => [map { $class->map_type($_, $cb) } $type->type_args],
        return_types => \%new_rt,
    ));
}
```

`walk` でも `return_types` を走査する。

### 1-3. Parser でコンストラクタ仕様の `->` 戻り型を解析する

**注意**: Parser.pm 本体は変更しない。コンストラクタ仕様の解析は `_datatype` 内のスペック文字列処理で行う。

`_datatype`（`Typist.pm`）と Extractor/Analyzer/Workspace のスペック解析ロジックに共通ヘルパーを用意する。

**新規ヘルパー**: `Typist::Type::Data` にクラスメソッドとして追加:

```perl
# コンストラクタ仕様文字列を解析して (param_types, return_type_expr) を返す。
# 通常 ADT: '(Int, Str)' => ([Int, Str], undef)
# GADT:     '(Int) -> Expr[Int]' => ([Int], 'Expr[Int]')
sub parse_constructor_spec ($class, $spec, %opts) {
    return ([], undef) unless defined $spec && $spec =~ /\S/;

    my $inner = $spec;
    $inner =~ s/\A\(\s*//;

    # GADT: check for -> before stripping closing paren
    my ($params_str, $return_expr);
    if ($inner =~ /\)\s*->\s*(.+)\z/) {
        $return_expr = $1;
        $inner =~ s/\)\s*->.*\z//;
        $params_str = $inner;
    } else {
        $inner =~ s/\s*\)\z//;
        $params_str = $inner;
    }

    my @types;
    if ($params_str =~ /\S/) {
        @types = map { Typist::Parser->parse($_) } split /\s*,\s*/, $params_str;
    }

    # Alias→Var promotion
    if ($opts{type_params} && $opts{type_params}->@*) {
        my %vn = map { $_ => 1 } $opts{type_params}->@*;
        @types = map {
            $_->is_alias && $vn{$_->alias_name}
                ? Typist::Type::Var->new($_->alias_name) : $_
        } @types;
    }

    return (\@types, $return_expr);
}
```

このヘルパーを `Typist.pm::_datatype`, `Analyzer.pm`, `Workspace.pm` の3箇所で共有する。

---

## フェーズ 2: ランタイムでの GADT コンストラクタ

### 2-1. `_datatype` の GADT 対応

**ファイル**: `lib/Typist.pm` 293-393 行目

**変更点**:

1. スペック文字列のパースを `parse_constructor_spec` に委譲する
2. GADT コンストラクタ（`$return_expr` が存在する場合）:
   - 戻り型をパースして `Type::Data` オブジェクトを取得
   - 戻り型の `type_args` から **型等式制約**（例: `A = Int`）を抽出
   - コンストラクタクロージャ内で、制約に従った `_type_args` をセットする
3. `%parsed_variants` に加えて `%return_types` を構築し、`Data->new` に渡す

```perl
my (%parsed_variants, %return_types);

for my $tag (keys %variants) {
    my ($types, $ret_expr) = Typist::Type::Data->parse_constructor_spec(
        $variants{$tag}, type_params => \@type_params,
    );
    $parsed_variants{$tag} = $types;

    if (defined $ret_expr) {
        my $ret_type = Typist::Parser->parse($ret_expr);
        # 戻り型は Data[ConcreteArgs] であるはず。検証する:
        die "GADT constructor $tag: return type must be $name\[...]\n"
            unless $ret_type->is_param && $ret_type->base eq $name
                || $ret_type->is_alias && $ret_type->alias_name eq $name;
        $return_types{$tag} = $ret_type;
    }

    # Install constructor ...
}

my $data_type = Typist::Type::Data->new($name, \%parsed_variants,
    type_params  => \@type_params,
    return_types => \%return_types,
);
```

コンストラクタクロージャの変更（GADT のケース）:
- 引数の型推論は通常通り行う
- 加えて、戻り型から **強制される型引数** を適用する
  - 例: `IntLit => '(Int) -> Expr[Int]'` の場合、`_type_args` は `[Atom('Int')]` に固定
  - `If => '(Expr[Bool], Expr[A], Expr[A]) -> Expr[A]'` の場合、`A` は引数から推論

```perl
if (defined $ret_expr) {
    # GADT: 戻り型から型引数を決定
    my $ret = $return_types{$tag_copy};
    my @forced_args;
    if ($ret->is_param) {
        @forced_args = $ret->params;
    }
    # forced_args 中の Var はまだ未束縛 → 通常の推論で埋める
    my @final_args;
    for my $i (0 .. $#type_params) {
        my $fa = $forced_args[$i];
        if ($fa && !$fa->is_var) {
            push @final_args, $fa;  # 制約により固定
        } else {
            push @final_args, $bindings{$type_params[$i]}
                // Typist::Type::Atom->new('Any');
        }
    }
    bless +{
        _tag       => $tag_copy,
        _values    => \@args,
        _type_args => \@final_args,
    }, $data_class;
}
```

**テスト**: `t/21_datatype.t` に GADT コンストラクタの基本テストを追加:
```perl
subtest 'GADT: constructor produces correct type_args' => sub {
    datatype 'Expr[A]' =>
        IntLit  => '(Int) -> Expr[Int]',
        BoolLit => '(Bool) -> Expr[Bool]';

    my $e = IntLit(42);
    is $e->{_tag}, 'IntLit';
    ok $e->{_type_args}[0]->equals(Typist::Type::Atom->new('Int'));
};
```

### 2-2. `match` のランタイム GADT 型引数伝播

**ファイル**: `lib/Typist.pm` 195-218 行目

現状では `match` は値の `_tag` でディスパッチし `_values` をスプラットするだけ。GADT ではこれに加えて、マッチしたコンストラクタの型制約情報を活用する必要がある。

ただし、ランタイムでの型精緻化は Perl の動的性質上限界がある。**主要な GADT の恩恵は静的解析（フェーズ 3）で得る**。ランタイムは以下のみ:

- 既存の機能をそのまま維持する（後方互換）
- GADT の `_type_args` は構築時に正しくセットされているので、`contains` チェックは動作する

**変更不要**（ランタイム `match` は現状のまま）。

---

## フェーズ 3: 静的解析での GADT サポート

これが GADT の本体。match 式での型精緻化と、コンストラクタ呼び出しの型推論を実現する。

### 3-1. Extractor で GADT コンストラクタ情報を抽出する

**ファイル**: `lib/Typist/Static/Extractor.pm` 106-178 行目

**変更**: `_extract_datatypes` で、バリアントの `spec` 文字列に `->` が含まれるかどうかを記録する。

Extractor は型の解析まではせず、生の文字列を保存する既存のスタイルを維持する:
```perl
$result->{datatypes}{$base_name} = +{
    variants    => \%variants,       # { Tag => '(Int) -> Expr[Int]' }
    type_params => \@type_params,
    line        => $stmt->line_number,
    col         => $stmt->column_number,
};
```

`spec` 文字列自体が GADT 情報を含むため、Extractor への変更は不要。Analyzer/Workspace 側のパースロジックが `parse_constructor_spec` を使うことで対応する。

### 3-2. Analyzer で GADT コンストラクタを Registry に登録する

**ファイル**: `lib/Typist/Static/Analyzer.pm`

フェーズ 0-2 で追加した datatype 登録ロジックを拡張:

1. `parse_constructor_spec` で戻り型を取得
2. 各コンストラクタを **関数として** Registry に登録する
3. 戻り型は GADT 制約付きの Data 型

```perl
# datatype 登録後、コンストラクタを関数として登録
for my $tag (keys $info->{variants}->%*) {
    my ($param_types, $ret_expr) = Typist::Type::Data->parse_constructor_spec(
        $info->{variants}{$tag}, type_params => $info->{type_params},
    );

    my $return_type;
    if (defined $ret_expr) {
        $return_type = eval { Typist::Parser->parse($ret_expr) };
        # ret_expr が 'Expr[Int]' なら → Param('Expr', Atom('Int'))
        # alias→var promotion は不要（具体型のため）
    } else {
        # 通常 ADT: 戻り型 = Data[T, U, ...]
        my @vars = map { Typist::Type::Var->new($_) } $info->{type_params}->@*;
        $return_type = @vars
            ? Typist::Type::Param->new($name, @vars)
            : Typist::Type::Alias->new($name);
    }

    # ジェネリック宣言
    my @generics = map { +{ name => $_, bound_expr => undef } }
                       $info->{type_params}->@*;

    $registry->register_function($extracted->{package}, $tag, +{
        params     => $param_types,
        returns    => $return_type,
        generics   => \@generics,
        params_expr => [map { $_->to_string } @$param_types],
        returns_expr => $return_type->to_string,
    });
}
```

これにより、TypeChecker が `IntLit(42)` を見たとき、Registry から `IntLit` の署名 `<A>(Int) -> Expr[Int]` を取得でき、通常の関数型チェックフローに乗せられる。

### 3-3. TypeChecker の `match` 式型推論

**ファイル**: `lib/Typist/Static/TypeChecker.pm`

現在 `match` は通常の関数呼び出しとして処理されるのみで、特別なハンドリングがない。以下を追加する:

#### 3-3a. match 式の検出

`_check_call_sites` 内で `match` 呼び出しを特別に検出:

```perl
# match 呼び出しのパターン:
#   match $value, Tag1 => sub { ... }, Tag2 => sub { ... }
if ($name eq 'match') {
    $self->_check_match_expr($word, $args, $env);
    next;
}
```

#### 3-3b. `_check_match_expr` メソッド

新規メソッドを追加:

```perl
sub _check_match_expr ($self, $word, $args, $env) {
    # 1. 第一引数（matchされる値）の型を推論
    my $scrutinee_type = Typist::Static::Infer->infer_expr($args->[0], $env);
    return unless $scrutinee_type;

    # 2. scrutinee が Data 型かどうかを判定
    #    （Registry で Data 型名を解決）
    my $data_type = $self->_resolve_data_type($scrutinee_type);
    return unless $data_type;

    # 3. 各アームについて:
    #    - タグの存在チェック（存在しないタグへのマッチは警告）
    #    - GADT の場合: タグから型等式制約を抽出し、
    #      アーム内の環境に型変数バインディングを追加
    #    - ハンドラの引数型をバリアントのフィールド型と照合

    # 4. 網羅性チェック（静的版）
    #    - 全バリアントがカバーされているか
    #    - `_` フォールバックの有無
}
```

#### 3-3c. GADT パターンマッチでの型精緻化

`match` の各アームで、GADT コンストラクタに基づく型変数のバインディングを環境に注入する。

例: `Expr[A]` に対して `IntLit` アームに入ったとき:
1. `IntLit` の戻り型は `Expr[Int]`
2. `scrutinee` の型は `Expr[A]`
3. `Expr[A]` と `Expr[Int]` を単一化 → `A = Int`
4. アーム内の環境に `A => Int` のバインディングを追加
5. アーム内で `A` を使う式は `Int` として型チェックされる

```perl
# GADT 型精緻化
if ($data_type->is_gadt) {
    my $con_ret = $data_type->constructor_return_type($tag);
    # scrutinee_type と con_ret を単一化して型変数バインディングを得る
    my $bindings = Typist::Static::Unify->unify($con_ret, $scrutinee_type);
    if ($bindings) {
        # アーム内の環境を拡張
        $arm_env = { %$env, gadt_bindings => $bindings };
    }
}
```

**注意**: これは TypeChecker の最も複雑な部分。静的解析で PPI を介してサブルーチンブロック内の式を解析する必要がある。初期実装では、match アームの戻り型推論は行わず、GADT バインディングの伝播のみに集中する。

### 3-4. Infer の GADT コンストラクタ対応

**ファイル**: `lib/Typist/Static/Infer.pm`

`_infer_call` でコンストラクタ呼び出しの戻り型を正しく推論する。フェーズ 3-2 で Registry にコンストラクタを関数として登録済みなので、大部分は既存の関数呼び出し推論フローで処理される。

ただし、GADT コンストラクタの場合は戻り型が引数の型に依存するため、Unify を使って具体的な戻り型を計算する必要がある:

```perl
# _infer_call 内
if (my $fn = $env->{functions}{$name}) {
    my $ret = $fn->{returns};
    # Generic 関数の場合: 引数から型変数を推論して戻り型を具体化
    if ($fn->{generics} && @{$fn->{generics}}) {
        my $bindings = _unify_args($fn, $args, $env);
        $ret = Typist::Static::Unify->substitute($ret, $bindings) if $bindings;
    }
    return $ret;
}
```

### 3-5. Subtype の GADT Data 型対応

**ファイル**: `lib/Typist/Subtype.pm`

現状のロジックは GADT でもそのまま動作する。Data 型の subtype チェックは名前ベース + 共変型引数なので、`Expr[Int] <: Expr[Any]` は正しく判定される。

追加の変更は不要。ただし、GADT の `return_types` フィールドは subtype 判定に影響しない（サブタイプ関係は Data 型の名前と type_args のみで決まる）ことを確認するテストを追加する。

---

## フェーズ 4: LSP サポート

### 4-1. Hover で datatype 情報を表示

**ファイル**: `lib/Typist/LSP/Hover.pm`

`_format` メソッドに `datatype` kind のケースを追加:

```perl
when ($kind eq 'datatype') {
    # Data 型の全情報（バリアント含む）を表示
    my $dt = ...; # Registry から取得
    return $dt->to_string_full;
}
```

### 4-2. DocumentSymbol に datatype を含める

**ファイル**: `lib/Typist/Static/Analyzer.pm` の `_build_symbol_index`

`%SYMBOL_KIND` に `datatype` エントリを追加。`_build_symbol_index` で extracted datatypes を symbols に含める:

```perl
for my $name (sort keys(($extracted->{datatypes} // +{})->%*)) {
    my $info = $extracted->{datatypes}{$name};
    push @symbols, +{
        name => $name,
        kind => 'datatype',
        type => ...,  # to_string_full 相当
        line => $info->{line},
        col  => $info->{col},
    };
}
```

### 4-3. Completion でコンストラクタを提案

**ファイル**: `lib/Typist/LSP/Completion.pm`

Registry に登録されたコンストラクタ関数を補完候補に含める。GADT の場合は戻り型情報も detail に表示。

---

## フェーズ 5: テストとドキュメント

### 5-1. 新規テストファイル

**`t/23_gadt.t`** — GADT コア機能のテスト:

```perl
use Test2::V0;
use Typist -runtime;

subtest 'GADT: basic construction' => sub {
    datatype 'Expr[A]' =>
        IntLit  => '(Int) -> Expr[Int]',
        BoolLit => '(Bool) -> Expr[Bool]',
        Add     => '(Expr[Int], Expr[Int]) -> Expr[Int]',
        If      => '(Expr[Bool], Expr[A], Expr[A]) -> Expr[A]';

    my $e = IntLit(42);
    is $e->{_tag}, 'IntLit';
    # _type_args should be [Int]
    ok $e->{_type_args}[0]->equals(Typist::Type::Atom->new('Int'));

    my $b = BoolLit(1);
    ok $b->{_type_args}[0]->equals(Typist::Type::Atom->new('Bool'));

    my $sum = Add(IntLit(1), IntLit(2));
    ok $sum->{_type_args}[0]->equals(Typist::Type::Atom->new('Int'));
};

subtest 'GADT: contains checks with refined types' => sub {
    my $int_expr = Typist::Type::Data->new('Expr', {...},
        type_params => ['A'],
        type_args   => [Typist::Type::Atom->new('Int')],
    );
    ok $int_expr->contains(IntLit(42));
};

subtest 'GADT: match dispatch preserves behavior' => sub {
    my $e = IntLit(42);
    my $result = match $e,
        IntLit  => sub ($n)    { $n + 1 },
        BoolLit => sub ($b)    { !$b },
        Add     => sub ($l, $r) { 0 },
        If      => sub ($c, $t, $f) { 0 };
    is $result, 43;
};

subtest 'GADT: is_gadt predicate' => sub {
    # 通常の ADT
    datatype Shape => Circle => '(Int)', Rect => '(Int, Int)';
    my $shape_dt = Typist::Registry->lookup_datatype('Shape');
    ok !$shape_dt->is_gadt;

    # GADT
    my $expr_dt = Typist::Registry->lookup_datatype('Expr');
    ok $expr_dt->is_gadt;
};
```

**`t/static/09_gadt_typecheck.t`** — 静的型チェックのテスト:

```perl
subtest 'GADT: constructor return type inferred correctly' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
use Typist;

datatype 'Expr[A]' =>
    IntLit  => '(Int) -> Expr[Int]',
    BoolLit => '(Bool) -> Expr[Bool]';

sub eval_int :Type((Expr[Int]) -> Int) ($e) {
    match $e,
        IntLit => sub ($n) { $n };
}
PERL
    my @errs = grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@*;
    is scalar @errs, 0, 'no type mismatch for well-typed GADT usage';
};

subtest 'GADT: type mismatch when constructor constraint violated' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
use Typist;

datatype 'Expr[A]' =>
    IntLit  => '(Int) -> Expr[Int]',
    BoolLit => '(Bool) -> Expr[Bool]';

sub bad :Type((Expr[Str]) -> Str) ($e) {
    match $e,
        IntLit => sub ($n) { $n };  # IntLit produces Expr[Int], not Expr[Str]
}
PERL
    # This should ideally detect the inconsistency
};
```

### 5-2. 既存テストの変更確認

以下のテストが引き続きパスすることを確認:
- `t/21_datatype.t` — 通常 ADT の全テスト（後方互換）
- `t/19_fold.t` — Fold のテスト（type_params/type_args 保存の修正後）
- `t/static/03_typecheck.t` — 静的型チェック
- `t/lsp/` 全テスト

### 5-3. CLAUDE.md の更新

`CLAUDE.md` に以下を追記:
- GADT の構文説明
- `is_gadt`, `constructor_return_type`, `return_types` の説明
- テストファイルの追加エントリ

### 5-4. Example の追加

`examples/` に GADT の使用例を追加:
```perl
# examples/gadt.pl — 型安全な式評価器
datatype 'Expr[A]' =>
    IntLit  => '(Int) -> Expr[Int]',
    BoolLit => '(Bool) -> Expr[Bool]',
    Add     => '(Expr[Int], Expr[Int]) -> Expr[Int]',
    If      => '(Expr[Bool], Expr[A], Expr[A]) -> Expr[A]';

sub eval_expr :Type(<A>(Expr[A]) -> A) ($expr) {
    match $expr,
        IntLit  => sub ($n)       { $n },
        BoolLit => sub ($b)       { $b },
        Add     => sub ($l, $r)   { eval_expr($l) + eval_expr($r) },
        If      => sub ($c, $t, $f) {
            eval_expr($c) ? eval_expr($t) : eval_expr($f)
        };
}
```

---

## 実装順序と依存関係

```
Phase 0-1 (Fold 修正)
Phase 0-2 (Analyzer datatype 登録)  ──┐
Phase 0-3 (Workspace Var promotion) ──┤
Phase 0-4 (ADT コンストラクタ登録)  ──┤  ← Infer.pm, TypeChecker.pm の検索パス修正含む
Phase 0-5 (Typeclass メソッド登録)  ──┤  ← Extractor の List 対応 + Analyzer のメソッド登録
Phase 0-6 (Newtype コンストラクタ登録)┤
                                      ├─→ Phase 1-1 (Data.pm 拡張)
                                      │       │
                                      │       ├─→ Phase 1-2 (Fold GADT 対応)
                                      │       │
                                      │       └─→ Phase 1-3 (parse_constructor_spec)
                                      │                │
                                      │                ├─→ Phase 2-1 (_datatype GADT)
                                      │                │
                                      │                ├─→ Phase 3-1 (Extractor — 変更不要の確認)
                                      │                │
                                      │                └─→ Phase 3-2 (Analyzer GADT コンストラクタ登録)
                                      │                         │
                                      │                         ├─→ Phase 3-3 (TypeChecker match)
                                      │                         │
                                      │                         └─→ Phase 3-4 (Infer GADT)
                                      │
                                      └─→ Phase 4 (LSP)
                                              │
                                              └─→ Phase 5 (Tests & Docs)
```

### 推奨実装単位

| 単位 | フェーズ | 概要 | 主な変更ファイル |
|------|----------|------|------------------|
| PR 1 | 0-1, 0-2, 0-3, 0-4 | DSL 型・ADT コンストラクタの静的解析修正 | `Fold.pm`, `Analyzer.pm`, `Workspace.pm`, `Infer.pm`, `TypeChecker.pm` |
| PR 2 | 0-5 | Typeclass メソッドの静的解析修正 | `Extractor.pm`, `Analyzer.pm` |
| PR 3 | 0-6 | Newtype コンストラクタの静的解析修正 | `Analyzer.pm` |
| PR 4 | 1-1, 1-2, 1-3 | GADT 型表現 | `Data.pm`, `Fold.pm` |
| PR 5 | 2-1 | ランタイム GADT コンストラクタ | `Typist.pm` |
| PR 6 | 3-2, 3-4 | 静的解析: GADT コンストラクタ型推論 | `Analyzer.pm`, `Infer.pm` |
| PR 7 | 3-3 | 静的解析: match 型精緻化 | `TypeChecker.pm` |
| PR 8 | 4-1, 4-2, 4-3 | LSP サポート | `Hover.pm`, `Document.pm`, `Completion.pm` |
| PR 9 | 5 | テスト・ドキュメント整備 | `t/23_gadt.t`, `t/static/09_gadt_typecheck.t`, `CLAUDE.md` |

---

## リスクと制約

### 技術的リスク

1. **PPI の限界**: `match` のアーム内のサブルーチン本体を静的解析するには PPI でブロック内を走査する必要がある。TypeChecker の既存コードは関数レベルでの解析に最適化されており、ネストされた無名サブ内の型チェックは追加のエンジニアリングが必要。

2. **型等式の伝播**: GADT の型精緻化はアーム内のスコープに限定されるべきだが、現在の TypeChecker は環境をスコープ単位で管理していないため、バインディングの漏洩に注意が必要。

3. **再帰的 GADT**: `Expr[A]` のコンストラクタ引数に `Expr[Int]` があるケース。再帰的な型のコンストラクタの型チェックは、Registry に登録される前にコンストラクタの型が必要になる鶏卵問題がある。Analyzer の登録順序に注意。

### スコープ外（将来的な拡張）

- **existential types**: `∃T. Constructor(T)` — GADT の自然な拡張だが、型消去の仕組みが必要
- **ネストされたパターンマッチ**: `match` の引数位置での構造的分解
- **GADT の型クラス制約**: `IntLit :: Num a => a -> Expr a` のような制約付きコンストラクタ
- **ランタイムでの型精緻化の活用**: 現状はランタイムでの GADT 利益は限定的

---

## 用語集

| 用語 | 説明 |
|------|------|
| GADT | Generalized Algebraic Data Type。コンストラクタごとに異なる戻り型を持てる ADT |
| 型精緻化 (type refinement) | パターンマッチで特定コンストラクタにマッチしたとき、型変数の具体型が判明すること |
| 型等式制約 | `A = Int` のような、型変数が特定の型に等しいという制約 |
| scrutinee | `match` に渡される被検査値 |
| 単一化 (unification) | 二つの型式を一致させる型変数の代入を求める操作 |
