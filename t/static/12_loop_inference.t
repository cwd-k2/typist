use v5.40;
use Test::More;
use lib 'lib';

use PPI;
use Typist::Static::Infer;
use Typist::Static::Extractor;
use Typist::Static::Analyzer;
use Typist::Type::Atom;
use Typist::Type::Param;

# ── =~ / !~ → Bool ──────────────────────────────

subtest '=~ operator infers Bool' => sub {
    my $doc = PPI::Document->new(\'$y =~ /pattern/;');
    my $stmts = $doc->find('PPI::Statement') || [];
    my $stmt = $stmts->[0];
    ok $stmt, 'found statement';
    my $t = Typist::Static::Infer->infer_expr($stmt);
    ok $t, 'inferred type from =~ expression';
    is $t->to_string, 'Bool', '=~ → Bool';
};

subtest '!~ operator infers Bool' => sub {
    my $doc = PPI::Document->new(\'$y !~ /pattern/;');
    my $stmts = $doc->find('PPI::Statement') || [];
    my $stmt = $stmts->[0];
    ok $stmt, 'found statement';
    my $t = Typist::Static::Infer->infer_expr($stmt);
    ok $t, 'inferred type from !~ expression';
    is $t->to_string, 'Bool', '!~ → Bool';
};

# ── Loop Variable Extraction ────────────────────

subtest 'extractor: extracts for-loop variables' => sub {
    my $source = <<'PERL';
use v5.40;
my $items :sig(ArrayRef[Int]) = [1, 2, 3];
for my $item (@$items) {
    say $item;
}
PERL
    my $extracted = Typist::Static::Extractor->extract($source);
    my $loops = $extracted->{loop_variables};
    is scalar @$loops, 1, 'one loop variable extracted';
    is $loops->[0]{name}, '$item', 'variable name is $item';
    ok $loops->[0]{list_node}, 'list_node captured';
    ok $loops->[0]{block_node}, 'block_node captured';
};

subtest 'extractor: foreach variant' => sub {
    my $source = <<'PERL';
use v5.40;
foreach my $x (@items) {
    say $x;
}
PERL
    my $extracted = Typist::Static::Extractor->extract($source);
    my $loops = $extracted->{loop_variables};
    is scalar @$loops, 1, 'foreach loop extracted';
    is $loops->[0]{name}, '$x', 'variable name is $x';
};

subtest 'extractor: nested loops' => sub {
    my $source = <<'PERL';
use v5.40;
for my $outer (@list1) {
    for my $inner (@list2) {
        say $inner;
    }
}
PERL
    my $extracted = Typist::Static::Extractor->extract($source);
    my $loops = $extracted->{loop_variables};
    is scalar @$loops, 2, 'two loop variables extracted';
    my @names = sort map { $_->{name} } @$loops;
    is_deeply \@names, ['$inner', '$outer'], 'both loop vars captured';
};

# ── Iterable Element Type Inference ─────────────

subtest 'infer iterable: @$ref unwraps ArrayRef' => sub {
    my $env = +{
        variables => +{
            '$items' => Typist::Type::Param->new('ArrayRef', Typist::Type::Atom->new('Int')),
        },
    };

    my $doc = PPI::Document->new(\'for my $x (@$items) {}');
    my $compounds = $doc->find('PPI::Statement::Compound') || [];
    my ($list_node);
    for my $c (@$compounds) {
        for my $child ($c->schildren) {
            if ($child->isa('PPI::Structure::List')) {
                $list_node = $child;
                last;
            }
        }
    }

    ok $list_node, 'found list node';
    my $elem = Typist::Static::Infer->infer_iterable_element_type($list_node, $env);
    ok $elem, 'element type inferred';
    is $elem->to_string, 'Int', '@$items with ArrayRef[Int] → Int';
};

subtest 'infer iterable: single $ref unwraps ArrayRef' => sub {
    my $env = +{
        variables => +{
            '$items' => Typist::Type::Param->new('ArrayRef', Typist::Type::Atom->new('Str')),
        },
    };

    my $doc = PPI::Document->new(\'for my $x ($items) {}');
    my $compounds = $doc->find('PPI::Statement::Compound') || [];
    my ($list_node);
    for my $c (@$compounds) {
        for my $child ($c->schildren) {
            if ($child->isa('PPI::Structure::List')) {
                $list_node = $child;
                last;
            }
        }
    }

    ok $list_node, 'found list node';
    my $elem = Typist::Static::Infer->infer_iterable_element_type($list_node, $env);
    ok $elem, 'element type inferred';
    is $elem->to_string, 'Str', '$items with ArrayRef[Str] → Str';
};

# ── Full Analyzer: Loop Variable in Symbol Index ─

subtest 'analyzer: loop variable appears in symbol index' => sub {
    my $source = <<'PERL';
use v5.40;
my $items :sig(ArrayRef[Int]) = [1, 2, 3];
for my $item (@$items) {
    say $item;
}
PERL
    my $result = Typist::Static::Analyzer->analyze($source);
    my @loop_syms = grep { $_->{name} eq '$item' && $_->{kind} eq 'variable' && $_->{inferred} }
                    $result->{symbols}->@*;
    ok @loop_syms >= 1, 'loop variable $item in symbol index';
    is $loop_syms[0]{type}, 'Int', 'loop var type is Int';
    ok defined $loop_syms[0]{scope_start}, 'scope_start present';
    ok defined $loop_syms[0]{scope_end}, 'scope_end present';
};

subtest 'analyzer: loop variable type from struct ArrayRef' => sub {
    my $source = <<'PERL';
use v5.40;
struct Product => (name => Str, price => Int);
my $products :sig(ArrayRef[Product]) = [];
for my $p (@$products) {
    say $p;
}
PERL
    my $result = Typist::Static::Analyzer->analyze($source);
    my @loop_syms = grep { $_->{name} eq '$p' && $_->{kind} eq 'variable' && $_->{inferred} }
                    $result->{symbols}->@*;
    ok @loop_syms >= 1, 'loop var $p in symbol index';
    like $loop_syms[0]{type}, qr/Product/, 'loop var type references Product';
};

# ── Loop Variable Type Checking ─────────────────

subtest 'type check inside for loop: no false positive' => sub {
    my $source = <<'PERL';
use v5.40;
sub process_items :sig((ArrayRef[Int]) -> Void) ($items) {
    for my $item (@$items) {
        my $result :sig(Int) = $item;
    }
}
PERL
    my $result = Typist::Static::Analyzer->analyze($source);
    my @errors = grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@*;
    is scalar @errors, 0, 'no type mismatch: $item is Int inside loop';
};

subtest 'type check inside for loop: detect mismatch' => sub {
    my $source = <<'PERL';
use v5.40;
sub process_items :sig((ArrayRef[Int]) -> Void) ($items) {
    for my $item (@$items) {
        my $result :sig(Str) = $item;
    }
}
PERL
    my $result = Typist::Static::Analyzer->analyze($source);
    my @errors = grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@*;
    is scalar @errors, 1, 'type mismatch detected: Int assigned to Str';
};

# ── Map/Grep/Sort Inference ─────────────────────

subtest 'map infers ArrayRef of block return type' => sub {
    my $env = +{
        variables => +{
            '$items' => Typist::Type::Param->new('ArrayRef', Typist::Type::Atom->new('Int')),
        },
    };

    my $source = 'my $x = map { 1 } @$items;';
    my $doc = PPI::Document->new(\$source);
    my $stmts = $doc->find('PPI::Statement::Variable') || [];
    my $stmt = $stmts->[0];
    my @children = $stmt->schildren;

    # Find the 'map' word
    my $map_word;
    for my $child (@children) {
        if ($child->isa('PPI::Token::Word') && $child->content eq 'map') {
            $map_word = $child;
            last;
        }
    }

    ok $map_word, 'found map word';
    my $t = Typist::Static::Infer->infer_expr($map_word, $env);
    ok $t, 'map type inferred';
    is $t->to_string, 'Array[Bool]', 'map { 1 } @$items → Array[Bool]';
};

subtest 'grep infers ArrayRef of element type' => sub {
    my $env = +{
        variables => +{
            '$items' => Typist::Type::Param->new('ArrayRef', Typist::Type::Atom->new('Str')),
        },
    };

    my $source = 'my $x = grep { 1 } @$items;';
    my $doc = PPI::Document->new(\$source);
    my $stmts = $doc->find('PPI::Statement::Variable') || [];
    my $stmt = $stmts->[0];

    my $grep_word;
    for my $child ($stmt->schildren) {
        if ($child->isa('PPI::Token::Word') && $child->content eq 'grep') {
            $grep_word = $child;
            last;
        }
    }

    ok $grep_word, 'found grep word';
    my $t = Typist::Static::Infer->infer_expr($grep_word, $env);
    ok $t, 'grep type inferred';
    is $t->to_string, 'Array[Str]', 'grep { ... } @$items → Array[Str]';
};

subtest 'sort infers ArrayRef of element type' => sub {
    my $env = +{
        variables => +{
            '$items' => Typist::Type::Param->new('ArrayRef', Typist::Type::Atom->new('Int')),
        },
    };

    my $source = 'my $x = sort { $a <=> $b } @$items;';
    my $doc = PPI::Document->new(\$source);
    my $stmts = $doc->find('PPI::Statement::Variable') || [];
    my $stmt = $stmts->[0];

    my $sort_word;
    for my $child ($stmt->schildren) {
        if ($child->isa('PPI::Token::Word') && $child->content eq 'sort') {
            $sort_word = $child;
            last;
        }
    }

    ok $sort_word, 'found sort word';
    my $t = Typist::Static::Infer->infer_expr($sort_word, $env);
    ok $t, 'sort type inferred';
    is $t->to_string, 'Array[Int]', 'sort { ... } @$items → Array[Int]';
};

# ── Regex Operators via Infer ─────────────────────

subtest 'infer: =~ with env-lookup yields Bool' => sub {
    my $env = +{
        variables => +{
            '$s' => Typist::Type::Atom->new('Str'),
        },
    };

    my $doc = PPI::Document->new(\'$s =~ /hello/;');
    my $stmts = $doc->find('PPI::Statement') || [];
    my $stmt = $stmts->[0];
    ok $stmt, 'found statement';
    my $t = Typist::Static::Infer->infer_expr($stmt, $env);
    ok $t, 'type inferred';
    is $t->to_string, 'Bool', '=~ with env yields Bool';
};

# ── Block Dereference @{$expr} ───────────────────

subtest 'infer iterable: @{$ref} block deref unwraps ArrayRef' => sub {
    my $env = +{
        variables => +{
            '$items' => Typist::Type::Param->new('ArrayRef', Typist::Type::Atom->new('Int')),
        },
    };

    my $doc = PPI::Document->new(\'for my $x (@{$items}) {}');
    my $compounds = $doc->find('PPI::Statement::Compound') || [];
    my ($list_node);
    for my $c (@$compounds) {
        for my $child ($c->schildren) {
            if ($child->isa('PPI::Structure::List')) {
                $list_node = $child;
                last;
            }
        }
    }

    ok $list_node, 'found list node';
    my $elem = Typist::Static::Infer->infer_iterable_element_type($list_node, $env);
    ok $elem, 'element type inferred from @{$items}';
    is $elem->to_string, 'Int', '@{$items} with ArrayRef[Int] → Int';
};

subtest 'analyzer: loop with @{$ref} block deref' => sub {
    my $source = <<'PERL';
use v5.40;
sub process :sig((ArrayRef[Str]) -> Void) ($items) {
    for my $item (@{$items}) {
        my $s :sig(Str) = $item;
    }
}
PERL
    my $result = Typist::Static::Analyzer->analyze($source);
    my @errors = grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@*;
    is scalar @errors, 0, 'block deref @{$items} loop body type checks correctly';
};

done_testing;
