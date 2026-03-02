use v5.40;
use Test::More;
use lib 'lib';

use Typist::Static::Analyzer;
use Typist::Registry;
use Typist::Parser;
use Typist::Type::Newtype;
use Typist::Effect;

# ── Cross-file typedef resolution ────────────────

subtest 'analyzer resolves workspace typedefs' => sub {
    my $ws_reg = Typist::Registry->new;
    $ws_reg->define_alias('UserId', 'Int');
    $ws_reg->define_alias('Email',  'Str');

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package Consumer;
use v5.40;

sub get_user :sig((UserId) -> Email) ($id) {
    return "user\@example.com";
}
PERL

    my @diags = $result->{diagnostics}->@*;
    # No errors expected — UserId and Email resolve via workspace registry
    my @errors = grep { $_->{severity} <= 2 } @diags;
    is scalar @errors, 0, 'no type errors with workspace typedefs';
};

# ── Cross-file newtype resolution ────────────────

subtest 'analyzer resolves workspace newtypes' => sub {
    my $ws_reg = Typist::Registry->new;
    my $inner = Typist::Parser->parse('Str');
    my $nt = Typist::Type::Newtype->new('ProductId', $inner);
    $ws_reg->register_newtype('ProductId', $nt);

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package Shop;
use v5.40;

typedef Product => '{ id => ProductId, name => Str }';
PERL

    my @diags = $result->{diagnostics}->@*;
    my @resolve_errs = grep { $_->{kind} eq 'ResolveError' } @diags;
    is scalar @resolve_errs, 0, 'no resolve errors — ProductId via workspace';
};

# ── Cross-package function call type checking ────

subtest 'analyzer checks cross-package function calls' => sub {
    my $ws_reg = Typist::Registry->new;
    $ws_reg->register_function('Helper', 'add', +{
        params  => [Typist::Parser->parse('Int'), Typist::Parser->parse('Int')],
        returns => Typist::Parser->parse('Int'),
    });

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package Consumer;
use v5.40;

sub caller_ok :sig((Int) -> Int) ($x) {
    return Helper::add($x, 1);
}
PERL

    my @diags = $result->{diagnostics}->@*;
    my @type_errs = grep { $_->{kind} eq 'TypeMismatch' } @diags;
    is scalar @type_errs, 0, 'no type mismatch for correct cross-package call';
};

subtest 'analyzer detects cross-package type mismatch' => sub {
    my $ws_reg = Typist::Registry->new;
    $ws_reg->register_function('Helper', 'add', +{
        params  => [Typist::Parser->parse('Int'), Typist::Parser->parse('Int')],
        returns => Typist::Parser->parse('Int'),
    });

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package Consumer;
use v5.40;

sub caller_bad :sig((Str) -> Int) ($x) {
    return Helper::add("hello", "world");
}
PERL

    my @diags = $result->{diagnostics}->@*;
    my @type_errs = grep { $_->{kind} eq 'TypeMismatch' } @diags;
    ok scalar @type_errs > 0, 'detects type mismatch in cross-package call';
};

# ── Cross-package effect checking ────────────────

subtest 'analyzer checks cross-package effect requirements' => sub {
    my $ws_reg = Typist::Registry->new;

    # Register an effectful function in another package
    my $eff = eval {
        my $row = Typist::Parser->parse_row('Console');
        Typist::Type::Eff->new($row);
    };

    # Register Console as a known effect
    $ws_reg->register_effect('Console', Typist::Effect->new(name => 'Console', operations => +{}));

    $ws_reg->register_function('IO', 'print_line', +{
        params  => [Typist::Parser->parse('Str')],
        returns => Typist::Parser->parse('Void'),
        effects => $eff,
    });

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package App;
use v5.40;

sub safe :sig((Str) -> Void ![Console]) ($msg) {
    IO::print_line($msg);
}
PERL

    my @diags = $result->{diagnostics}->@*;
    my @eff_errs = grep { $_->{kind} eq 'EffectMismatch' } @diags;
    is scalar @eff_errs, 0, 'no effect mismatch when caller declares required effects';
};

# ── Cross-module alias resolution in subtype ─────

subtest 'alias argument matches concrete param via workspace registry' => sub {
    my $ws_reg = Typist::Registry->new;
    $ws_reg->define_alias('Price', 'Int');
    $ws_reg->register_function('Pricing', 'subtotal', +{
        params  => [Typist::Parser->parse('Int')],
        returns => Typist::Parser->parse('Price'),
    });
    $ws_reg->register_function('Pricing', 'apply_discount', +{
        params  => [Typist::Parser->parse('Int'), Typist::Parser->parse('Int')],
        returns => Typist::Parser->parse('Int'),
    });

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package Order;
use v5.40;

sub create :sig((Int) -> Int) ($qty) {
    my $sub = Pricing::subtotal($qty);
    return Pricing::apply_discount($sub, 10);
}
PERL

    my @type_errs = grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@*;
    is scalar @type_errs, 0, 'Price (alias for Int) accepted where Int expected';
};

subtest 'alias argument satisfies bound in generic call via workspace registry' => sub {
    my $ws_reg = Typist::Registry->new;
    $ws_reg->define_alias('Price', 'Int');
    $ws_reg->register_function('Pricing', 'subtotal', +{
        params  => [Typist::Parser->parse('Int')],
        returns => Typist::Parser->parse('Price'),
    });
    $ws_reg->register_function('Pricing', 'apply_discount', +{
        params      => [Typist::Parser->parse('T'), Typist::Parser->parse('Int')],
        returns     => Typist::Parser->parse('T'),
        generics    => [+{ name => 'T', bound_expr => 'Num' }],
        params_expr => ['T', 'Int'],
        returns_expr => 'T',
    });

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package Order;
use v5.40;

sub create :sig((Int) -> Int) ($qty) {
    my $sub = Pricing::subtotal($qty);
    return Pricing::apply_discount($sub, 10);
}
PERL

    my @type_errs = grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@*;
    is scalar @type_errs, 0, 'Price satisfies bound Num via alias resolution (Price -> Int <: Num)';
};

done_testing;
