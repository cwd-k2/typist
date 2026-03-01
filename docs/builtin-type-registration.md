# 実装指示書: Typist 組み込み関数の型登録 + handle/match 戻り値推論

## 背景と目的

Typist は `use Typist;` 時に `handle`, `perform`, `match`, `typedef` 等の関数を caller の名前空間に export する。
しかしこれらの関数には型情報が一切登録されておらず、静的解析（TypeChecker / Infer）が型推論できない。

**主要な問題**: `my $x = handle { 42 } Eff => +{...}` で `$x` の型が `Any`（不明）になる。

**原因**:
1. Perl ビルトインは `Typist::Prelude` が `CORE::` 名前空間に型を登録するが、Typist export 関数は対象外
2. `handle { BLOCK }` は PPI 上で Word + **Block**（List ではない）→ 既存の Word + List パターンに一致しない
3. `match $val, ...` も Word + **Symbol** → 同様にスキップされる

---

## 変更対象ファイル

| ファイル | 変更内容 |
|---------|---------|
| `lib/Typist/Prelude.pm` | `%BUILTINS` に Typist 組み込み関数を追加 |
| `lib/Typist/Static/Infer.pm` | `handle`/`match` 特殊推論ロジック追加 |
| `lib/Typist/Static/EffectChecker.pm` | キーワードスキップリスト拡張 |
| `t/static/09_builtins_infer.t` | 新規テストファイル |

---

## Step 1: Prelude に Typist 組み込み関数を登録

### ファイル: `lib/Typist/Prelude.pm`

### 変更箇所: `%BUILTINS` ハッシュ（L14〜L101）の末尾、`gmtime` エントリの後に追加

### 追加内容:

```perl
    # ── Typist builtins ──────────────────────────
    typedef   => '(...Any) -> Void',
    newtype   => '(...Any) -> Void',
    effect    => '(...Any) -> Void',
    typeclass => '(...Any) -> Void',
    instance  => '(...Any) -> Void',
    declare   => '(Str, Str) -> Void',
    datatype  => '(...Any) -> Void',
    enum      => '(...Any) -> Void',
    perform   => '(...Any) -> Any',
    unwrap    => '(Any) -> Any',
```

### 補足:
- `handle` と `match` はここには含めない。Word + List パターンではないため CORE:: 登録では解決しない。Step 2 で特殊推論を行う
- `perform` は `-> Any`（戻り値はランタイムハンドラ依存で静的に決定不能）
- 宣言系（typedef, newtype 等）は `-> Void`
- `perform` はエフェクトなしで登録 → EffectChecker L159 `next unless $callee_sig->{effects}` で自然にスキップされる（現時点ではエフェクト追跡しない）

---

## Step 2: Infer.pm に handle/match 特殊推論を追加

### ファイル: `lib/Typist/Static/Infer.pm`

### 2a. `infer_expr` に handle/match 分岐を追加

**変更箇所**: L65〜L71 の `# ── Function call: Word followed by List` の **前** に挿入

**現在のコード** (L65-L71):
```perl
    # ── Function call: Word followed by List ────
    if ($element->isa('PPI::Token::Word')) {
        my $next = $element->snext_sibling;
        if ($next && $next->isa('PPI::Structure::List')) {
            return _infer_call($element->content, $env);
        }
    }
```

**挿入するコード** (L65 の前に):
```perl
    # ── handle expression: Word("handle") + Block ──
    if ($element->isa('PPI::Token::Word') && $element->content eq 'handle') {
        my $next = $element->snext_sibling;
        if ($next && $next->isa('PPI::Structure::Block')) {
            return _infer_block_return($next, $env);
        }
    }

    # ── match expression: Word("match") + value ────
    if ($element->isa('PPI::Token::Word') && $element->content eq 'match') {
        return _infer_match_return($element, $env);
    }
```

**設計判断**:
- `handle`: PPI 上で Word("handle") の次兄弟が `PPI::Structure::Block`。ブロック本体の最後の式から戻り値型を推論
- `match`: PPI 上で Word("match") の次兄弟が `PPI::Token::Symbol`（`$value`）。全アームの `sub { ... }` から戻り値型を収集して union/LUB
- 誤認防止: `handle => sub { ... }`（ハッシュキー）は次兄弟が `=>` なので Block チェックに引っかからない。`$obj->handle(...)` は前兄弟が `->` だが、`infer_expr` はそもそも Word 単体で呼ばれるため問題ない

### 2b. ヘルパー関数を追加

**追加箇所**: `_infer_call` の後（L123 の後）に追加

```perl
# ── Block Return Type Inference ─────────────────
#
# Infers the return type of a PPI::Structure::Block by examining
# its last statement.  Used by handle inference.

sub _infer_block_return ($block, $env) {
    my @stmts = $block->schildren;
    # Filter to statements only
    @stmts = grep { $_->isa('PPI::Statement') } @stmts;
    return Typist::Type::Atom->new('Void') unless @stmts;

    my $last = $stmts[-1];

    # Explicit return: infer the expression after 'return'
    my $first = $last->schild(0);
    if ($first && $first->isa('PPI::Token::Word') && $first->content eq 'return') {
        my $val = $first->snext_sibling;
        return Typist::Type::Atom->new('Void')
            unless $val && !($val->isa('PPI::Token::Structure') && $val->content eq ';');
        return __PACKAGE__->infer_expr($val, $env);
    }

    # Implicit return: try to infer from the last statement
    # If it's a bare expression statement, infer from its first child
    __PACKAGE__->infer_expr($first, $env) // __PACKAGE__->infer_expr($last, $env);
}

# ── Match Return Type Inference ──────────────────
#
# Walks siblings after `match` to find all handler blocks
# (sub { ... }), infers each handler's return type, then
# computes the union/LUB.

sub _infer_match_return ($match_word, $env) {
    my @arm_types;
    my $sib = $match_word->snext_sibling;

    while ($sib) {
        last if $sib->isa('PPI::Token::Structure') && $sib->content eq ';';

        # Look for Word("sub") followed by optional Prototype then Block
        if ($sib->isa('PPI::Token::Word') && $sib->content eq 'sub') {
            my $after = $sib->snext_sibling;
            # Skip prototype: sub ($a, $b) { ... }
            if ($after && $after->isa('PPI::Token::Prototype')) {
                $after = $after->snext_sibling;
            }
            if ($after && $after->isa('PPI::Structure::Block')) {
                my $arm_type = _infer_block_return($after, $env);
                push @arm_types, $arm_type if defined $arm_type;
            }
        }

        $sib = $sib->snext_sibling;
    }

    return undef unless @arm_types;
    return $arm_types[0] if @arm_types == 1;

    # Widen literals to base atoms (consistent with _infer_ternary)
    my @widened = map {
        $_->is_literal ? Typist::Type::Atom->new($_->base_type) : $_
    } @arm_types;

    # LUB
    my $result = $widened[0];
    for my $i (1 .. $#widened) {
        $result = Typist::Subtype->common_super($result, $widened[$i]);
    }

    # If LUB is too coarse (Any), try Union instead
    if ($result->is_atom && $result->name eq 'Any' && @widened <= 4) {
        my %seen;
        my @unique = grep { !$seen{$_->to_string}++ } @widened;
        return @unique == 1 ? $unique[0] : Typist::Type::Union->new(@unique);
    }

    $result;
}
```

**パターン参考**: `_infer_ternary`（L259-L277）と同じリテラル→Atom ワイドニング + LUB/Union 戦略を使用

---

## Step 3: EffectChecker キーワードスキップリスト拡張

### ファイル: `lib/Typist/Static/EffectChecker.pm`

### 変更箇所: L104 のキーワード正規表現

### 現在のコード:
```perl
        next if $callee_name =~ /\A(?:my|our|local|return|if|unless|for|foreach|while|until|do|eval|sub|use|no)\z/;
```

### 変更後:
```perl
        next if $callee_name =~ /\A(?:my|our|local|return|if|unless|for|foreach|while|until|do|eval|sub|use|no|handle|match|enum)\z/;
```

### 理由:
- `handle`: 次兄弟が Block であり L148 `next unless List` で既にスキップされるが、明示的にキーワード化してエフェクト追跡対象外であることを表明。`handle` はエフェクトの**消費者**（ハンドラ）であり生産者ではない
- `match`: 次兄弟が Symbol であり同様にスキップされるが、明示的にキーワード化
- `enum`: `enum Color => qw(Red Green Blue)` で `qw(...)` が `PPI::Token::QuoteLike::Words` → `PPI::Structure::List` として解析される可能性がある。キーワード化で安全にスキップ
- `perform` は含めない: CORE:: 登録（Step 1）でエフェクトなし → L159 で自然にスキップ

---

## Step 4: テスト

### ファイル: `t/static/09_builtins_infer.t`（新規作成）

### テストパターン: `t/static/08_prelude.t` に準拠

```perl
use v5.40;
use Test::More;
use lib 'lib';

use Typist::Static::Analyzer;

# Helper: analyze source, return diagnostics of a given kind
sub diags_of ($source, $kind) {
    my $result = Typist::Static::Analyzer->analyze($source);
    [ grep { $_->{kind} eq $kind } $result->{diagnostics}->@* ];
}

# ── handle return type inference ─────────────────

subtest 'handle: infer Int from block body' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
use v5.40;
my $x :Type(Int) = handle { 42 } Console => +{ log => sub ($msg) {} };
PERL

    is scalar @$errs, 0, 'handle block returns Int, assigned to Int — no error';
};

subtest 'handle: type mismatch (block returns Int, var expects Str)' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
use v5.40;
my $x :Type(Str) = handle { 42 } Console => +{ log => sub ($msg) {} };
PERL

    is scalar @$errs, 1, 'one type error';
    like $errs->[0]{message}, qr/\$x.*Str.*Int/i, 'expected Str, got Int';
};

subtest 'handle: infer Str from string expression' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
use v5.40;
my $x :Type(Str) = handle { "hello" } Console => +{ log => sub ($msg) {} };
PERL

    is scalar @$errs, 0, 'handle block returns Str — no error';
};

# ── match return type inference ──────────────────

subtest 'match: infer Int from same-type arms' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
use v5.40;
my $val = bless +{ _tag => 'A', _values => [] }, 'Typist::Data::TestADT';
my $x :Type(Int) = match $val,
    A => sub { 1 },
    B => sub { 2 };
PERL

    is scalar @$errs, 0, 'all arms return Int — no error';
};

subtest 'match: type mismatch (arms return Int, var expects Str)' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
use v5.40;
my $val = bless +{ _tag => 'A', _values => [] }, 'Typist::Data::TestADT';
my $x :Type(Str) = match $val,
    A => sub { 1 },
    B => sub { 2 };
PERL

    is scalar @$errs, 1, 'one type error';
    like $errs->[0]{message}, qr/\$x.*Str.*Int/i, 'expected Str, got Int';
};

subtest 'match: mixed types produce union (Int | Str)' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
use v5.40;
my $val = bless +{ _tag => 'A', _values => [] }, 'Typist::Data::TestADT';
my $x :Type(Int | Str) = match $val,
    A => sub { 42 },
    B => sub { "hello" };
PERL

    is scalar @$errs, 0, 'mixed arms (Int | Str) assigned to Int | Str — no error';
};

# ── perform/unwrap CORE registration ─────────────

subtest 'perform: registered as CORE builtin (returns Any)' => sub {
    # perform returns Any — assigning to any annotated type should be gradual-skipped
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
use v5.40;
my $x :Type(Int) = perform(Console => 'read');
PERL

    is scalar @$errs, 0, 'perform returns Any — gradual skip, no error';
};

subtest 'unwrap: registered as CORE builtin (returns Any)' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
use v5.40;
my $x :Type(Int) = unwrap(42);
PERL

    is scalar @$errs, 0, 'unwrap returns Any — gradual skip, no error';
};

# ── declaration functions return Void ────────────

subtest 'typedef: registered as CORE builtin' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
use v5.40;
my $x :Type(Void) = typedef(Name => 'Int');
PERL

    is scalar @$errs, 0, 'typedef returns Void — no error';
};

done_testing;
```

### テスト方針:
- `handle` の戻り値推論（正常ケース + 型不一致）
- `match` の戻り値推論（同一型アーム + 型不一致 + 混合型 Union）
- `perform` / `unwrap` の CORE 登録確認（`Any` でグラデュアルスキップ）
- 宣言関数の `Void` 戻り値確認

---

## 実装順序と依存関係

```
Step 1 (Prelude.pm)           ─┐
Step 3 (EffectChecker.pm)     ─┤─ 相互独立・並行可
Step 2a (Infer.pm ヘルパー)   ─┘
Step 2b (handle/match 分岐)   ── Step 2a に依存
Step 4 (テスト)               ── 全 Step に依存
```

## 検証手順

```sh
# 新規テストの実行
carton exec -- prove -lv t/static/09_builtins_infer.t

# 既存の静的解析テストに影響がないこと
carton exec -- prove -l t/static/

# コアテスト全体に影響がないこと
carton exec -- prove -l t/
```

## 注意事項

- `use v5.40` と subroutine signatures を使用すること（プロジェクト規約）
- `_infer_block_return` / `_infer_match_return` はプライベートヘルパー（`_` prefix、package-private）
- Infer.pm では `__PACKAGE__->infer_expr()` で再帰呼び出し（クラスメソッド形式）
- Literal 型のワイドニングは `_infer_ternary` のパターンに従う（`is_literal` → `Atom->new(base_type)`）
- `common_super` は `Typist::Subtype` のクラスメソッド
- テスト内ではパッケージ名をユニークにする（Perl のパッケージは名前空間が共有される）
